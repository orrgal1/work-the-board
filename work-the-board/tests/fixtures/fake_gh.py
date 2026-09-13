#!/usr/bin/env python3
"""Deterministic, guarded fake for scoped GitHub issue interactions.

The fake accepts a small ``gh issue``-shaped CLI and exposes the same model as
an importable class.  It never invokes gh and requires a caller-owned state
path, making concurrent fixture instances completely isolated.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Any, Callable, NoReturn


_REPOSITORY = re.compile(r"^[^/\s]+/[^/\s]+$")


class GitHubFixtureError(RuntimeError):
    pass


class GuardRejected(GitHubFixtureError):
    pass


class APIError(GitHubFixtureError):
    def __init__(self, message: str, *, committed: bool = False) -> None:
        super().__init__(message)
        self.committed = committed


class MalformedResponse(GitHubFixtureError):
    def __init__(self, payload: str = "{malformed", *, committed: bool = False) -> None:
        super().__init__("fixture returned a malformed response")
        self.payload = payload
        self.committed = committed


def _initial_state() -> dict[str, Any]:
    return {
        "version": 1,
        "next_sequence": 1,
        "next_comment_id": 1,
        "repositories": {},
        "failures": {},
        "idempotency": {},
        "log": [],
    }


class FakeGitHub:
    def __init__(self, state_path: str | os.PathLike[str], now: Callable[[], float] | None = None) -> None:
        self.path = Path(state_path)
        self._now = now or (lambda: 0.0)
        self.state = self._load()

    def _load(self) -> dict[str, Any]:
        if not self.path.exists():
            return _initial_state()
        value = json.loads(self.path.read_text(encoding="utf-8"))
        if value.get("version") != 1:
            raise ValueError("unsupported fake GitHub state version")
        return value

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

    @staticmethod
    def _scope(repository: str, number: int) -> tuple[str, str]:
        if not _REPOSITORY.fullmatch(repository or ""):
            raise GuardRejected("repository must be an explicit owner/name")
        if isinstance(number, bool) or int(number) < 1:
            raise GuardRejected("issue number must be a positive integer")
        return repository, str(int(number))

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
                "service": "github",
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
        message: str = "injected GitHub API failure",
        payload: str = "{malformed",
    ) -> None:
        if kind not in {"api", "malformed"}:
            raise ValueError("failure kind must be api or malformed")
        if times < 1:
            raise ValueError("times must be positive")
        self.state["failures"].setdefault(action, []).extend(
            {
                "kind": kind,
                "after_commit": bool(after_commit),
                "message": message,
                "payload": payload,
            }
            for _ in range(times)
        )
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

    def _before(self, action: str, inputs: dict[str, Any]) -> None:
        failure = self._take_failure(action, False)
        if failure:
            self._record(action, inputs, failure["kind"], committed=False)
            self._raise_failure(failure, False)

    def _after(self, action: str, inputs: dict[str, Any]) -> None:
        failure = self._take_failure(action, True)
        if failure:
            self._record(f"{action}.response", inputs, failure["kind"], committed=True)
            self._raise_failure(failure, True)

    def seed_issue(
        self,
        repository: str,
        number: int,
        *,
        state: str = "OPEN",
        title: str = "",
        labels: list[str] | tuple[str, ...] = (),
        body: str = "",
    ) -> dict[str, Any]:
        repository, key = self._scope(repository, number)
        normalized_state = state.upper()
        if normalized_state not in {"OPEN", "CLOSED"}:
            raise ValueError("issue state must be OPEN or CLOSED")
        issue = {
            "number": int(number),
            "state": normalized_state,
            "title": title,
            "body": body,
            "labels": sorted(set(labels)),
            "comments": [],
        }
        self.state["repositories"].setdefault(repository, {"issues": {}})["issues"][key] = issue
        self._record("fixture.seed_issue", {"repository": repository, "number": int(number)}, "seeded", committed=True)
        self._save()
        return copy.deepcopy(issue)

    def _issue(self, repository: str, number: int) -> tuple[str, str, dict[str, Any]]:
        repository, key = self._scope(repository, number)
        try:
            return repository, key, self.state["repositories"][repository]["issues"][key]
        except KeyError as error:
            raise KeyError(f"unknown issue {repository}#{number}") from error

    def view_issue(self, repository: str, number: int) -> dict[str, Any]:
        repository, _, issue = self._issue(repository, number)
        inputs = {"repository": repository, "number": int(number)}
        self._before("issue.view", inputs)
        result = copy.deepcopy(issue)
        self._after("issue.view", inputs)
        return result

    @staticmethod
    def _guard(
        issue: dict[str, Any],
        *,
        expected_state: str | None,
        expected_labels: list[str] | None,
        require_labels: list[str] | None,
        forbid_labels: list[str] | None,
    ) -> None:
        actual = set(issue["labels"])
        if expected_state is not None and issue["state"] != expected_state.upper():
            raise GuardRejected(
                f"state guard failed: expected {expected_state.upper()}, found {issue['state']}"
            )
        if expected_labels is not None and actual != set(expected_labels):
            raise GuardRejected(
                f"label guard failed: expected {sorted(expected_labels)}, found {sorted(actual)}"
            )
        missing = set(require_labels or ()) - actual
        if missing:
            raise GuardRejected(f"required labels absent: {sorted(missing)}")
        forbidden = set(forbid_labels or ()) & actual
        if forbidden:
            raise GuardRejected(f"forbidden labels present: {sorted(forbidden)}")

    @staticmethod
    def _fingerprint(value: dict[str, Any]) -> str:
        encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        return hashlib.sha256(encoded).hexdigest()

    def edit_issue(
        self,
        repository: str,
        number: int,
        *,
        add_labels: list[str] | tuple[str, ...] = (),
        remove_labels: list[str] | tuple[str, ...] = (),
        state: str | None = None,
        expected_state: str | None = None,
        expected_labels: list[str] | None = None,
        require_labels: list[str] | None = None,
        forbid_labels: list[str] | None = None,
        idempotency_key: str | None = None,
    ) -> dict[str, Any]:
        repository, _, issue = self._issue(repository, number)
        if state is not None and state.upper() not in {"OPEN", "CLOSED"}:
            raise ValueError("issue state must be OPEN or CLOSED")
        inputs = {
            "repository": repository,
            "number": int(number),
            "add_labels": sorted(set(add_labels)),
            "remove_labels": sorted(set(remove_labels)),
            "state": state.upper() if state else None,
            "guards": {
                "expected_state": expected_state.upper() if expected_state else None,
                "expected_labels": sorted(expected_labels) if expected_labels is not None else None,
                "require_labels": sorted(require_labels or ()),
                "forbid_labels": sorted(forbid_labels or ()),
            },
            "idempotency_key": idempotency_key,
        }
        if not inputs["add_labels"] and not inputs["remove_labels"] and state is None:
            raise GuardRejected("refusing an empty issue mutation")
        fingerprint = self._fingerprint(inputs)
        if idempotency_key:
            prior = self.state["idempotency"].get(idempotency_key)
            if prior:
                if prior["fingerprint"] != fingerprint:
                    raise GuardRejected("idempotency key reused for a different mutation")
                self._record("issue.edit", inputs, "duplicate", committed=False)
                self._save()
                return copy.deepcopy(issue)
        try:
            self._guard(
                issue,
                expected_state=expected_state,
                expected_labels=expected_labels,
                require_labels=require_labels,
                forbid_labels=forbid_labels,
            )
        except GuardRejected as error:
            self._record("issue.edit", inputs, f"guard_rejected: {error}", committed=False)
            self._save()
            raise
        self._before("issue.edit", inputs)
        labels = set(issue["labels"])
        labels.update(add_labels)
        labels.difference_update(remove_labels)
        issue["labels"] = sorted(labels)
        if state is not None:
            issue["state"] = state.upper()
        if idempotency_key:
            self.state["idempotency"][idempotency_key] = {
                "fingerprint": fingerprint,
                "action": "issue.edit",
            }
        self._record("issue.edit", inputs, "updated", committed=True)
        self._save()
        self._after("issue.edit", inputs)
        return copy.deepcopy(issue)

    def comment_issue(
        self,
        repository: str,
        number: int,
        body: str,
        *,
        expected_state: str | None = None,
        require_labels: list[str] | None = None,
        idempotency_key: str | None = None,
    ) -> dict[str, Any]:
        repository, _, issue = self._issue(repository, number)
        if not body:
            raise GuardRejected("comment body is required")
        inputs = {
            "repository": repository,
            "number": int(number),
            "body": body,
            "guards": {
                "expected_state": expected_state.upper() if expected_state else None,
                "require_labels": sorted(require_labels or ()),
            },
            "idempotency_key": idempotency_key,
        }
        fingerprint = self._fingerprint(inputs)
        if idempotency_key:
            prior = self.state["idempotency"].get(idempotency_key)
            if prior:
                if prior["fingerprint"] != fingerprint:
                    raise GuardRejected("idempotency key reused for a different mutation")
                self._record("issue.comment", inputs, "duplicate", committed=False)
                self._save()
                comment_id = prior["comment_id"]
                return copy.deepcopy(next(c for c in issue["comments"] if c["id"] == comment_id))
        try:
            self._guard(
                issue,
                expected_state=expected_state,
                expected_labels=None,
                require_labels=require_labels,
                forbid_labels=None,
            )
        except GuardRejected as error:
            self._record("issue.comment", inputs, f"guard_rejected: {error}", committed=False)
            self._save()
            raise
        self._before("issue.comment", inputs)
        comment_id = self.state["next_comment_id"]
        self.state["next_comment_id"] = comment_id + 1
        comment = {
            "id": comment_id,
            "body": body,
            "url": f"https://fixture.invalid/{repository}/issues/{number}#issuecomment-{comment_id}",
        }
        issue["comments"].append(comment)
        if idempotency_key:
            self.state["idempotency"][idempotency_key] = {
                "fingerprint": fingerprint,
                "action": "issue.comment",
                "comment_id": comment_id,
            }
        self._record("issue.comment", inputs, "created", committed=True)
        self._save()
        self._after("issue.comment", inputs)
        return copy.deepcopy(comment)

    @property
    def log(self) -> list[dict[str, Any]]:
        return copy.deepcopy(self.state["log"])


def _state_path(value: str | None) -> str:
    path = value or os.environ.get("FAKE_GH_STATE")
    if not path:
        raise SystemExit("--state or FAKE_GH_STATE is required")
    return path


def _csv(values: list[str] | None) -> list[str]:
    return [item for value in values or () for item in value.split(",") if item]


def _issue_parser(sub: argparse._SubParsersAction[argparse.ArgumentParser]) -> None:
    issue = sub.add_parser("issue")
    actions = issue.add_subparsers(dest="issue_command", required=True)
    view = actions.add_parser("view")
    view.add_argument("number", type=int)
    view.add_argument("-R", "--repo", required=True)
    view.add_argument("--json")
    view.add_argument("--jq")
    edit = actions.add_parser("edit")
    edit.add_argument("number", type=int)
    edit.add_argument("-R", "--repo", required=True)
    edit.add_argument("--add-label", action="append")
    edit.add_argument("--remove-label", action="append")
    edit.add_argument("--set-state", choices=("OPEN", "CLOSED"))
    edit.add_argument("--expected-state")
    edit.add_argument("--expected-label", action="append")
    edit.add_argument("--require-label", action="append")
    edit.add_argument("--forbid-label", action="append")
    edit.add_argument("--idempotency-key")
    comment = actions.add_parser("comment")
    comment.add_argument("number", type=int)
    comment.add_argument("-R", "--repo", required=True)
    comment.add_argument("--body", required=True)
    comment.add_argument("--expected-state")
    comment.add_argument("--require-label", action="append")
    comment.add_argument("--idempotency-key")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state")
    sub = parser.add_subparsers(dest="command", required=True)
    _issue_parser(sub)
    fixture = sub.add_parser("fixture")
    fixture_actions = fixture.add_subparsers(dest="fixture_command", required=True)
    seed = fixture_actions.add_parser("seed-issue")
    seed.add_argument("number", type=int)
    seed.add_argument("-R", "--repo", required=True)
    seed.add_argument("--issue-state", choices=("OPEN", "CLOSED"), default="OPEN")
    seed.add_argument("--title", default="")
    seed.add_argument("--body", default="")
    seed.add_argument("--label", action="append")
    failure = fixture_actions.add_parser("queue-failure")
    failure.add_argument("action", choices=("issue.view", "issue.edit", "issue.comment"))
    failure.add_argument("--kind", choices=("api", "malformed"), default="api")
    failure.add_argument("--times", type=int, default=1)
    failure.add_argument("--after-commit", action="store_true")
    fixture_actions.add_parser("log")
    args = parser.parse_args(argv)
    github = FakeGitHub(_state_path(args.state))
    try:
        if args.command == "fixture":
            if args.fixture_command == "seed-issue":
                result = github.seed_issue(
                    args.repo,
                    args.number,
                    state=args.issue_state,
                    title=args.title,
                    body=args.body,
                    labels=_csv(args.label),
                )
            elif args.fixture_command == "queue-failure":
                github.queue_failure(
                    args.action,
                    args.kind,
                    times=args.times,
                    after_commit=args.after_commit,
                )
                result = {"queued": args.times, "action": args.action}
            else:
                result = github.log
        elif args.issue_command == "view":
            result = github.view_issue(args.repo, args.number)
            if args.json:
                fields = [field for field in args.json.split(",") if field]
                result = {field: result.get(field) for field in fields}
        elif args.issue_command == "edit":
            result = github.edit_issue(
                args.repo,
                args.number,
                add_labels=_csv(args.add_label),
                remove_labels=_csv(args.remove_label),
                state=args.set_state,
                expected_state=args.expected_state,
                expected_labels=_csv(args.expected_label) if args.expected_label is not None else None,
                require_labels=_csv(args.require_label),
                forbid_labels=_csv(args.forbid_label),
                idempotency_key=args.idempotency_key,
            )
        else:
            result = github.comment_issue(
                args.repo,
                args.number,
                args.body,
                expected_state=args.expected_state,
                require_labels=_csv(args.require_label),
                idempotency_key=args.idempotency_key,
            )
        print(json.dumps(result, sort_keys=True))
        return 0
    except MalformedResponse as error:
        print(error.payload)
        return 0
    except (APIError, GitHubFixtureError, KeyError, ValueError) as error:
        print(str(error), file=os.sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
