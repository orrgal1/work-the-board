#!/usr/bin/env python3
"""Deterministic durable report-delivery fixture.

State transitions are deliberately separate so a caller can restart in every
submission/relay/acknowledgement crash window.  All storage is selected by the
caller; this module never contacts a real transport.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
from pathlib import Path
import tempfile
from typing import Any, Callable, NoReturn


CRASH_POINTS = {
    "before_submission",
    "after_submission_before_relay",
    "after_relay_before_acknowledgement",
    "after_acknowledgement",
}


class ReportFixtureError(RuntimeError):
    pass


class InjectedCrash(ReportFixtureError):
    def __init__(self, point: str) -> None:
        super().__init__(f"injected crash at {point}")
        self.point = point


class APIError(ReportFixtureError):
    def __init__(self, message: str, *, committed: bool = False) -> None:
        super().__init__(message)
        self.committed = committed


class MalformedResponse(ReportFixtureError):
    def __init__(self, payload: str = "{malformed", *, committed: bool = False) -> None:
        super().__init__("fixture returned a malformed response")
        self.payload = payload
        self.committed = committed


def _initial_state() -> dict[str, Any]:
    return {
        "version": 1,
        "next_sequence": 1,
        "reports": {},
        "failures": {},
        "crashes": {},
        "log": [],
    }


class FakeReports:
    """Persistent report state machine keyed by caller idempotency keys."""

    def __init__(self, state_path: str | os.PathLike[str], now: Callable[[], float] | None = None) -> None:
        self.path = Path(state_path)
        self._now = now or (lambda: 0.0)
        self.state = self._load()

    def _load(self) -> dict[str, Any]:
        if not self.path.exists():
            return _initial_state()
        loaded = json.loads(self.path.read_text(encoding="utf-8"))
        if loaded.get("version") != 1:
            raise ValueError("unsupported fake report state version")
        return loaded

    def _save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=f".{self.path.name}.", dir=self.path.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                json.dump(self.state, stream, sort_keys=True, separators=(",", ":"))
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def _record(
        self,
        action: str,
        inputs: dict[str, Any],
        outcome: str,
        *,
        committed: bool,
    ) -> None:
        sequence = self.state["next_sequence"]
        self.state["next_sequence"] = sequence + 1
        self.state["log"].append(
            {
                "sequence": sequence,
                "time": float(self._now()),
                "service": "reports",
                "action": action,
                "inputs": copy.deepcopy(inputs),
                "outcome": outcome,
                "committed": committed,
            }
        )

    def queue_failure(
        self,
        action: str,
        kind: str = "api",
        *,
        times: int = 1,
        after_commit: bool = False,
        message: str = "injected report transport failure",
        payload: str = "{malformed",
    ) -> None:
        if kind not in {"api", "malformed"}:
            raise ValueError("failure kind must be api or malformed")
        if times < 1:
            raise ValueError("times must be positive")
        queue = self.state["failures"].setdefault(action, [])
        queue.extend(
            {
                "kind": kind,
                "after_commit": bool(after_commit),
                "message": message,
                "payload": payload,
            }
            for _ in range(times)
        )
        self._save()

    def set_crash(self, point: str, *, times: int = 1) -> None:
        if point not in CRASH_POINTS:
            raise ValueError(f"unknown crash point: {point}")
        if times < 1:
            raise ValueError("times must be positive")
        self.state["crashes"][point] = self.state["crashes"].get(point, 0) + times
        self._save()

    def _take_failure(self, action: str, after_commit: bool) -> dict[str, Any] | None:
        queue = self.state["failures"].get(action, [])
        if queue and bool(queue[0]["after_commit"]) == after_commit:
            failure = queue.pop(0)
            if not queue:
                self.state["failures"].pop(action, None)
            return failure
        return None

    def _raise_failure(self, failure: dict[str, Any], committed: bool) -> NoReturn:
        self._save()
        if failure["kind"] == "malformed":
            raise MalformedResponse(failure["payload"], committed=committed)
        raise APIError(failure["message"], committed=committed)

    def _crash(self, point: str) -> None:
        remaining = self.state["crashes"].get(point, 0)
        if not remaining:
            return
        if remaining == 1:
            self.state["crashes"].pop(point, None)
        else:
            self.state["crashes"][point] = remaining - 1
        self._record("crash", {"point": point}, "injected", committed=False)
        self._save()
        raise InjectedCrash(point)

    def submit(self, key: str, payload: Any) -> dict[str, Any]:
        if not key:
            raise ValueError("idempotency key is required")
        self._crash("before_submission")
        inputs = {"key": key, "payload": payload}
        failure = self._take_failure("submit", False)
        if failure:
            self._record("submit", inputs, failure["kind"], committed=False)
            self._raise_failure(failure, False)
        existing = self.state["reports"].get(key)
        if existing is None:
            existing = {
                "key": key,
                "payload": copy.deepcopy(payload),
                "submitted": True,
                "relayed": False,
                "acknowledged": False,
                "attempts": {"submit": 1, "relay": 0, "acknowledge": 0},
            }
            self.state["reports"][key] = existing
            outcome = "created"
        else:
            existing["attempts"]["submit"] += 1
            if existing["payload"] != payload:
                self._record("submit", inputs, "idempotency_conflict", committed=False)
                self._save()
                raise ReportFixtureError("idempotency key reused with a different payload")
            outcome = "duplicate"
        self._record("submit", inputs, outcome, committed=True)
        self._save()
        failure = self._take_failure("submit", True)
        if failure:
            self._record("submit.response", {"key": key}, failure["kind"], committed=True)
            self._raise_failure(failure, True)
        self._crash("after_submission_before_relay")
        return copy.deepcopy(existing)

    def relay(self, key: str) -> dict[str, Any]:
        report = self._require(key)
        inputs = {"key": key}
        failure = self._take_failure("relay", False)
        if failure:
            self._record("relay", inputs, failure["kind"], committed=False)
            self._raise_failure(failure, False)
        report["attempts"]["relay"] += 1
        outcome = "duplicate" if report["relayed"] else "relayed"
        report["relayed"] = True
        self._record("relay", inputs, outcome, committed=True)
        self._save()
        failure = self._take_failure("relay", True)
        if failure:
            self._record("relay.response", inputs, failure["kind"], committed=True)
            self._raise_failure(failure, True)
        self._crash("after_relay_before_acknowledgement")
        return copy.deepcopy(report)

    def acknowledge(self, key: str) -> dict[str, Any]:
        report = self._require(key)
        if not report["relayed"]:
            raise ReportFixtureError("cannot acknowledge an unrelayed report")
        inputs = {"key": key}
        failure = self._take_failure("acknowledge", False)
        if failure:
            self._record("acknowledge", inputs, failure["kind"], committed=False)
            self._raise_failure(failure, False)
        report["attempts"]["acknowledge"] += 1
        outcome = "duplicate" if report["acknowledged"] else "acknowledged"
        report["acknowledged"] = True
        self._record("acknowledge", inputs, outcome, committed=True)
        self._save()
        failure = self._take_failure("acknowledge", True)
        if failure:
            self._record("acknowledge.response", inputs, failure["kind"], committed=True)
            self._raise_failure(failure, True)
        self._crash("after_acknowledgement")
        return copy.deepcopy(report)

    def deliver(self, key: str, payload: Any) -> dict[str, Any]:
        report = self.state["reports"].get(key)
        if report is None:
            report = self.submit(key, payload)
        elif report["payload"] != payload:
            raise ReportFixtureError("idempotency key reused with a different payload")
        if not report["relayed"]:
            report = self.relay(key)
        if not report["acknowledged"]:
            report = self.acknowledge(key)
        return report

    def _require(self, key: str) -> dict[str, Any]:
        try:
            return self.state["reports"][key]
        except KeyError as error:
            raise KeyError(f"unknown report: {key}") from error

    def get(self, key: str) -> dict[str, Any]:
        return copy.deepcopy(self._require(key))

    def list(self) -> list[dict[str, Any]]:
        return [copy.deepcopy(self.state["reports"][key]) for key in sorted(self.state["reports"])]

    @property
    def log(self) -> list[dict[str, Any]]:
        return copy.deepcopy(self.state["log"])


def _state_path(value: str | None) -> str:
    path = value or os.environ.get("FAKE_REPORTS_STATE")
    if not path:
        raise SystemExit("--state or FAKE_REPORTS_STATE is required")
    return path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state")
    sub = parser.add_subparsers(dest="command", required=True)
    submit = sub.add_parser("submit")
    submit.add_argument("key")
    submit.add_argument("payload")
    for name in ("relay", "acknowledge", "get", "deliver"):
        command = sub.add_parser(name)
        command.add_argument("key")
        if name == "deliver":
            command.add_argument("payload")
    sub.add_parser("list")
    sub.add_parser("log")
    crash = sub.add_parser("set-crash")
    crash.add_argument("point", choices=sorted(CRASH_POINTS))
    crash.add_argument("--times", type=int, default=1)
    failure = sub.add_parser("queue-failure")
    failure.add_argument("action", choices=("submit", "relay", "acknowledge"))
    failure.add_argument("--kind", choices=("api", "malformed"), default="api")
    failure.add_argument("--times", type=int, default=1)
    failure.add_argument("--after-commit", action="store_true")
    args = parser.parse_args(argv)
    fixture = FakeReports(_state_path(args.state))
    try:
        if args.command == "submit":
            result = fixture.submit(args.key, json.loads(args.payload))
        elif args.command == "relay":
            result = fixture.relay(args.key)
        elif args.command == "acknowledge":
            result = fixture.acknowledge(args.key)
        elif args.command == "deliver":
            result = fixture.deliver(args.key, json.loads(args.payload))
        elif args.command == "get":
            result = fixture.get(args.key)
        elif args.command == "list":
            result = fixture.list()
        elif args.command == "log":
            result = fixture.log
        elif args.command == "set-crash":
            fixture.set_crash(args.point, times=args.times)
            result = {"queued": args.times, "point": args.point}
        else:
            fixture.queue_failure(
                args.action,
                args.kind,
                times=args.times,
                after_commit=args.after_commit,
            )
            result = {"queued": args.times, "action": args.action}
        print(json.dumps(result, sort_keys=True))
        return 0
    except MalformedResponse as error:
        print(error.payload)
        return 0
    except InjectedCrash as error:
        print(str(error), file=os.sys.stderr)
        return 86
    except (APIError, ReportFixtureError, KeyError, ValueError) as error:
        print(str(error), file=os.sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
