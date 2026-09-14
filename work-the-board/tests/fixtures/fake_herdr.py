#!/usr/bin/env python3
"""Deterministic Herdr model for watcher integration tests.

The module is importable and exposes a small CLI-shaped surface. It models
identity and remote state without starting terminals, agents, or processes.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
from typing import Any, Callable, NoReturn


AGENT_STATUSES = {"working", "blocked", "idle", "done", "failed", "dead", "unknown"}


class HerdrFixtureError(RuntimeError):
    pass


class NotFound(HerdrFixtureError):
    pass


class IdentityMismatch(HerdrFixtureError):
    pass


class ProtectedResource(HerdrFixtureError):
    pass


class APIError(HerdrFixtureError):
    def __init__(self, message: str, *, committed: bool = False, code: str = "fixture_error") -> None:
        super().__init__(message)
        self.committed = committed
        self.code = code


class MalformedResponse(HerdrFixtureError):
    def __init__(self, payload: str = "{malformed", *, committed: bool = False) -> None:
        super().__init__("fixture returned a malformed response")
        self.payload = payload
        self.committed = committed


class TimeoutAfterSuccess(APIError):
    def __init__(self, message: str = "response timed out after remote success") -> None:
        super().__init__(message, committed=True, code="timeout")


def _initial_state(path: Path) -> dict[str, Any]:
    namespace = hashlib.sha256(str(path.absolute()).encode()).hexdigest()[:12]
    return {
        "version": 1,
        "namespace": namespace,
        "time": 0.0,
        "next_sequence": 1,
        "counters": {"workspace": 1, "tab": 1, "pane": 1, "terminal": 1, "session": 1},
        "workspaces": {},
        "tabs": {},
        "panes": {},
        "agents": {},
        "failures": {},
        "log": [],
    }


class FakeHerdr:
    """Durable in-process model of herdr workspaces, tabs, panes and agents."""

    def __init__(self, state_path: str | os.PathLike[str], now: Callable[[], float] | None = None) -> None:
        self.path = Path(state_path)
        self._external_now = now
        self.state = self._load()

    def _load(self) -> dict[str, Any]:
        if not self.path.exists():
            return _initial_state(self.path)
        value = json.loads(self.path.read_text(encoding="utf-8"))
        if value.get("version") != 1:
            raise ValueError("unsupported fake herdr state version")
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

    def _now(self) -> float:
        return float(self._external_now()) if self._external_now else float(self.state["time"])

    def set_time(self, value: float) -> float:
        value = float(value)
        if value < self.state["time"]:
            raise ValueError("fixture time cannot move backwards")
        self.state["time"] = value
        self._save()
        return value

    def advance(self, seconds: float) -> float:
        seconds = float(seconds)
        if seconds < 0:
            raise ValueError("advance must be non-negative")
        return self.set_time(self.state["time"] + seconds)

    def _id(self, kind: str) -> str:
        number = self.state["counters"][kind]
        self.state["counters"][kind] = number + 1
        prefix = {"workspace": "ws", "tab": "tab", "pane": "pane", "terminal": "term", "session": "session"}[kind]
        return f"{prefix}_{number}"

    def _record(
        self,
        operation: str,
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
                "time": self._now(),
                "service": "herdr",
                "operation": operation,
                "inputs": copy.deepcopy(inputs),
                "outcome": outcome,
                "committed": committed,
            }
        )

    def queue_failure(
        self,
        operation: str,
        kind: str = "api",
        *,
        times: int = 1,
        after_commit: bool = False,
        message: str = "injected herdr API failure",
        code: str = "fixture_error",
        payload: str = "{malformed",
    ) -> None:
        if kind not in {"api", "malformed", "timeout_after_success"}:
            raise ValueError("failure kind must be api, malformed, or timeout_after_success")
        if times < 1:
            raise ValueError("times must be positive")
        if kind == "timeout_after_success":
            after_commit = True
        self.state["failures"].setdefault(operation, []).extend(
            {
                "kind": kind,
                "after_commit": bool(after_commit),
                "message": message,
                "code": code,
                "payload": payload,
            }
            for _ in range(times)
        )
        self._save()

    def _take_failure(self, operation: str, after_commit: bool) -> dict[str, Any] | None:
        queue = self.state["failures"].get(operation, [])
        if queue and bool(queue[0]["after_commit"]) == after_commit:
            failure = queue.pop(0)
            if not queue:
                self.state["failures"].pop(operation, None)
            return failure
        return None

    def _raise_failure(self, failure: dict[str, Any], committed: bool) -> NoReturn:
        self._save()
        if failure["kind"] == "malformed":
            raise MalformedResponse(failure["payload"], committed=committed)
        if failure["kind"] == "timeout_after_success":
            raise TimeoutAfterSuccess(failure["message"])
        raise APIError(failure["message"], committed=committed, code=failure["code"])

    def _before(self, operation: str, inputs: dict[str, Any]) -> None:
        failure = self._take_failure(operation, False)
        if failure:
            self._record(operation, inputs, failure["kind"], committed=False)
            self._raise_failure(failure, False)

    def _after(self, operation: str, inputs: dict[str, Any]) -> None:
        failure = self._take_failure(operation, True)
        if failure:
            self._record(f"{operation}.response", inputs, failure["kind"], committed=True)
            self._raise_failure(failure, True)

    def create_workspace(
        self,
        checkout_path: str,
        *,
        workspace_id: str | None = None,
        linked_worktree: bool = False,
        anchor: bool = False,
        anchor_label: str = "workspace anchor - do not close",
    ) -> dict[str, Any]:
        operation = "workspace.create"
        inputs = {
            "checkout_path": checkout_path,
            "workspace_id": workspace_id,
            "linked_worktree": linked_worktree,
            "anchor": anchor,
        }
        self._before(operation, inputs)
        workspace_id = workspace_id or self._id("workspace")
        if workspace_id in self.state["workspaces"]:
            raise IdentityMismatch(f"workspace already exists: {workspace_id}")
        workspace = {
            "workspace_id": workspace_id,
            "worktree": {"checkout_path": checkout_path, "is_linked_worktree": bool(linked_worktree)},
            "tab_ids": [],
        }
        self.state["workspaces"][workspace_id] = workspace
        if anchor:
            self._create_tab(workspace_id, checkout_path, anchor_label, protected=True)
        self._record(operation, inputs, "created", committed=True)
        self._save()
        self._after(operation, inputs)
        return self.get_workspace(workspace_id)

    def _workspace(self, workspace_id: str) -> dict[str, Any]:
        try:
            return self.state["workspaces"][workspace_id]
        except KeyError as error:
            raise NotFound(f"workspace not found: {workspace_id}") from error

    def get_workspace(self, workspace_id: str) -> dict[str, Any]:
        workspace = copy.deepcopy(self._workspace(workspace_id))
        workspace["tab_count"] = len(workspace.pop("tab_ids"))
        return workspace

    def list_workspaces(self) -> list[dict[str, Any]]:
        return [self.get_workspace(key) for key in sorted(self.state["workspaces"])]

    def create_tab(
        self,
        workspace_id: str,
        cwd: str,
        *,
        label: str = "",
        protected: bool = False,
    ) -> dict[str, Any]:
        operation = "tab.create"
        inputs = {"workspace_id": workspace_id, "cwd": cwd, "label": label, "protected": protected}
        self._before(operation, inputs)
        tab, pane = self._create_tab(workspace_id, cwd, label, protected=protected)
        self._record(operation, inputs, "created", committed=True)
        self._save()
        self._after(operation, inputs)
        return {"tab": copy.deepcopy(tab), "root_pane": copy.deepcopy(pane)}

    def _create_tab(
        self, workspace_id: str, cwd: str, label: str, *, protected: bool
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        workspace = self._workspace(workspace_id)
        tab_id = self._id("tab")
        pane_id = self._id("pane")
        terminal_id = self._id("terminal")
        tab = {
            "tab_id": tab_id,
            "workspace_id": workspace_id,
            "label": label,
            "pane_ids": [pane_id],
            "active_pane_id": pane_id,
            "protected": bool(protected),
        }
        pane = {
            "pane_id": pane_id,
            "tab_id": tab_id,
            "workspace_id": workspace_id,
            "cwd": cwd,
            "terminal_id": terminal_id,
            "terminal_state": "open",
            "session_id": None,
            "agent_name": None,
            "agent_status": "unknown",
        }
        self.state["tabs"][tab_id] = tab
        self.state["panes"][pane_id] = pane
        workspace["tab_ids"].append(tab_id)
        return tab, pane

    def _tab(self, tab_id: str) -> dict[str, Any]:
        try:
            return self.state["tabs"][tab_id]
        except KeyError as error:
            raise NotFound(f"tab not found: {tab_id}") from error

    def _pane(self, pane_id: str) -> dict[str, Any]:
        try:
            return self.state["panes"][pane_id]
        except KeyError as error:
            raise NotFound(f"pane not found: {pane_id}") from error

    def get_tab(self, tab_id: str) -> dict[str, Any]:
        return copy.deepcopy(self._tab(tab_id))

    def list_tabs(self, workspace_id: str | None = None) -> list[dict[str, Any]]:
        tabs = self.state["tabs"].values()
        if workspace_id is not None:
            self._workspace(workspace_id)
            tabs = (tab for tab in tabs if tab["workspace_id"] == workspace_id)
        return [copy.deepcopy(tab) for tab in sorted(tabs, key=lambda item: item["tab_id"])]

    def rename_tab(self, tab_id: str, label: str) -> dict[str, Any]:
        operation = "tab.rename"
        inputs = {"tab_id": tab_id, "label": label}
        self._before(operation, inputs)
        tab = self._tab(tab_id)
        tab["label"] = label
        self._record(operation, inputs, "renamed", committed=True)
        self._save()
        self._after(operation, inputs)
        return copy.deepcopy(tab)

    def get_pane(self, pane_id: str) -> dict[str, Any]:
        return copy.deepcopy(self._pane(pane_id))

    def list_panes(self, workspace_id: str | None = None, tab_id: str | None = None) -> list[dict[str, Any]]:
        if workspace_id is not None:
            self._workspace(workspace_id)
        if tab_id is not None:
            self._tab(tab_id)
        panes = self.state["panes"].values()
        return [
            copy.deepcopy(pane)
            for pane in sorted(panes, key=lambda item: item["pane_id"])
            if (workspace_id is None or pane["workspace_id"] == workspace_id)
            and (tab_id is None or pane["tab_id"] == tab_id)
        ]

    def start_agent(
        self,
        name: str,
        pane_id: str,
        *,
        kind: str = "omp",
        omp_args: list[str] | None = None,
    ) -> dict[str, Any]:
        operation = "agent.start"
        inputs = {"name": name, "pane_id": pane_id, "kind": kind, "omp_args": list(omp_args or ())}
        self._before(operation, inputs)
        if not name:
            raise IdentityMismatch("agent name is required")
        if name in self.state["agents"]:
            raise IdentityMismatch(f"agent name already exists: {name}")
        pane = self._pane(pane_id)
        if pane["session_id"] is not None:
            raise IdentityMismatch(f"pane already owns session {pane['session_id']}")
        session_id = self._id("session")
        agent = {
            "name": name,
            "kind": kind,
            "pane_id": pane_id,
            "tab_id": pane["tab_id"],
            "workspace_id": pane["workspace_id"],
            "session_id": session_id,
            "cwd": pane["cwd"],
            "agent_status": "idle",
        }
        self.state["agents"][name] = agent
        pane.update(session_id=session_id, agent_name=name, agent_status="idle")
        self._record(operation, inputs, "started", committed=True)
        self._save()
        self._after(operation, inputs)
        return copy.deepcopy(agent)

    def _agent(self, name: str) -> dict[str, Any]:
        try:
            return self.state["agents"][name]
        except KeyError as error:
            raise NotFound(f"agent not found: {name}") from error

    def list_agents(self) -> list[dict[str, Any]]:
        return [copy.deepcopy(self.state["agents"][name]) for name in sorted(self.state["agents"])]

    def rename_agent(self, pane_id: str, new_name: str) -> dict[str, Any]:
        operation = "agent.rename"
        inputs = {"pane_id": pane_id, "new_name": new_name}
        self._before(operation, inputs)
        pane = self._pane(pane_id)
        old_name = pane["agent_name"]
        if old_name is None:
            raise NotFound(f"pane has no agent: {pane_id}")
        if new_name in self.state["agents"] and new_name != old_name:
            raise IdentityMismatch(f"agent name already exists: {new_name}")
        agent = self.state["agents"].pop(old_name)
        agent["name"] = new_name
        self.state["agents"][new_name] = agent
        pane["agent_name"] = new_name
        self._record(operation, inputs, "renamed", committed=True)
        self._save()
        self._after(operation, inputs)
        return copy.deepcopy(agent)

    def prompt_agent(self, name: str, prompt: str) -> dict[str, Any]:
        operation = "agent.prompt"
        inputs = {"name": name, "prompt": prompt}
        self._before(operation, inputs)
        agent = self._agent(name)
        pane = self._pane(agent["pane_id"])
        agent["agent_status"] = pane["agent_status"] = "working"
        self._record(operation, inputs, "accepted", committed=True)
        self._save()
        self._after(operation, inputs)
        return copy.deepcopy(agent)

    def set_status(self, pane_id: str, *, agent_status: str) -> dict[str, Any]:
        operation = "fixture.set_status"
        inputs = {"pane_id": pane_id, "agent_status": agent_status}
        if agent_status not in AGENT_STATUSES:
            raise ValueError(f"unknown agent status: {agent_status}")
        pane = self._pane(pane_id)
        pane["agent_status"] = agent_status
        agent = self.state["agents"].get(pane["agent_name"])
        if agent:
            agent["agent_status"] = agent_status
        self._record(operation, inputs, "updated", committed=True)
        self._save()
        return copy.deepcopy(pane)




    def close_tab(
        self,
        tab_id: str,
        *,
        expected_workspace_id: str | None = None,
        expected_pane_id: str | None = None,
        expected_session_id: str | None = None,
        expected_agent_name: str | None = None,
        require_guard: bool = False,
        allow_protected: bool = False,
    ) -> dict[str, Any]:
        operation = "tab.close"
        inputs = {
            "tab_id": tab_id,
            "expected_workspace_id": expected_workspace_id,
            "expected_pane_id": expected_pane_id,
            "expected_session_id": expected_session_id,
            "expected_agent_name": expected_agent_name,
            "require_guard": require_guard,
            "allow_protected": allow_protected,
        }
        self._before(operation, inputs)
        try:
            tab = self._tab(tab_id)
            if require_guard and not any(
                (expected_workspace_id, expected_pane_id, expected_session_id, expected_agent_name)
            ):
                raise IdentityMismatch("close requires an expected identity guard")
            if tab["protected"] and not allow_protected:
                raise ProtectedResource(f"tab is protected: {tab_id}")
            if expected_workspace_id is not None and tab["workspace_id"] != expected_workspace_id:
                raise IdentityMismatch("workspace identity changed before close")
            if expected_pane_id is not None and expected_pane_id not in tab["pane_ids"]:
                raise IdentityMismatch("pane identity changed before close")
            panes = [self._pane(pane_id) for pane_id in tab["pane_ids"]]
            if expected_session_id is not None and not any(
                pane["session_id"] == expected_session_id for pane in panes
            ):
                raise IdentityMismatch("session identity changed before close")
            if expected_agent_name is not None and not any(
                pane["agent_name"] == expected_agent_name for pane in panes
            ):
                raise IdentityMismatch("agent identity changed before close")
        except HerdrFixtureError as error:
            self._record(operation, inputs, f"rejected: {error}", committed=False)
            self._save()
            raise
        workspace_id = tab["workspace_id"]
        workspace = self._workspace(workspace_id)
        pane_ids = list(tab["pane_ids"])
        session_ids: list[str] = []
        agent_names: list[str] = []
        for pane_id in pane_ids:
            pane = self.state["panes"].pop(pane_id)
            if pane["session_id"]:
                session_ids.append(pane["session_id"])
            if pane["agent_name"]:
                agent_names.append(pane["agent_name"])
                self.state["agents"].pop(pane["agent_name"], None)
        workspace["tab_ids"].remove(tab_id)
        self.state["tabs"].pop(tab_id)
        workspace_destroyed = not workspace["tab_ids"]
        if workspace_destroyed:
            self.state["workspaces"].pop(workspace_id)
        result = {
            "tab_id": tab_id,
            "workspace_id": workspace_id,
            "workspace_destroyed": workspace_destroyed,
            "pane_ids": pane_ids,
            "session_ids": session_ids,
            "agent_names": agent_names,
        }
        self._record(operation, inputs, "closed", committed=True)
        self._save()
        self._after(operation, inputs)
        return result

    def close_workspace(self, workspace_id: str, *, force: bool = False) -> dict[str, Any]:
        operation = "workspace.close"
        inputs = {"workspace_id": workspace_id, "force": force}
        self._before(operation, inputs)
        workspace = self._workspace(workspace_id)
        if workspace["tab_ids"] and not force:
            raise ProtectedResource("workspace still contains tabs")
        if force:
            for tab_id in list(workspace["tab_ids"]):
                self.close_tab(tab_id, allow_protected=True)
        else:
            self.state["workspaces"].pop(workspace_id)
        self._record(operation, inputs, "closed", committed=True)
        self._save()
        self._after(operation, inputs)
        return {"workspace_id": workspace_id}

    @property
    def log(self) -> list[dict[str, Any]]:
        return copy.deepcopy(self.state["log"])

    def snapshot(self) -> dict[str, Any]:
        return copy.deepcopy(self.state)


def _state_path(value: str | None) -> str:
    path = value or os.environ.get("FAKE_HERDR_STATE")
    if not path:
        raise SystemExit("--state or FAKE_HERDR_STATE is required")
    return path


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state")
    groups = parser.add_subparsers(dest="group", required=True)

    workspace = groups.add_parser("workspace")
    workspace_commands = workspace.add_subparsers(dest="command", required=True)
    workspace_commands.add_parser("list")
    get_workspace = workspace_commands.add_parser("get")
    get_workspace.add_argument("workspace_id")
    close_workspace = workspace_commands.add_parser("close")
    close_workspace.add_argument("workspace_id")
    close_workspace.add_argument("--force", action="store_true")

    tab = groups.add_parser("tab")
    tab_commands = tab.add_subparsers(dest="command", required=True)
    list_tabs = tab_commands.add_parser("list")
    list_tabs.add_argument("--workspace")
    create_tab = tab_commands.add_parser("create")
    create_tab.add_argument("--workspace", required=True)
    create_tab.add_argument("--cwd", required=True)
    create_tab.add_argument("--label", default="")
    create_tab.add_argument("--protected", action="store_true")
    create_tab.add_argument("--no-focus", action="store_true")
    get_tab = tab_commands.add_parser("get")
    get_tab.add_argument("tab_id")
    rename_tab = tab_commands.add_parser("rename")
    rename_tab.add_argument("tab_id")
    rename_tab.add_argument("label")
    close_tab = tab_commands.add_parser("close")
    close_tab.add_argument("tab_id")
    close_tab.add_argument("--expected-workspace")
    close_tab.add_argument("--expected-pane")
    close_tab.add_argument("--expected-session")
    close_tab.add_argument("--expected-agent")
    close_tab.add_argument("--require-guard", action="store_true")
    close_tab.add_argument("--allow-protected", action="store_true")

    pane = groups.add_parser("pane")
    pane_commands = pane.add_subparsers(dest="command", required=True)
    get_pane = pane_commands.add_parser("get")
    get_pane.add_argument("pane_id")
    list_panes = pane_commands.add_parser("list")
    list_panes.add_argument("--workspace")
    list_panes.add_argument("--tab")

    agent = groups.add_parser("agent")
    agent_commands = agent.add_subparsers(dest="command", required=True)
    agent_commands.add_parser("list")
    start_agent = agent_commands.add_parser("start")
    start_agent.add_argument("name")
    start_agent.add_argument("--kind", default="omp")
    start_agent.add_argument("--pane", required=True)
    prompt_agent = agent_commands.add_parser("prompt")
    prompt_agent.add_argument("name")
    prompt_agent.add_argument("prompt")
    prompt_agent.add_argument("--wait", action="store_true")
    prompt_agent.add_argument("--until", action="append")
    prompt_agent.add_argument("--timeout")
    rename_agent = agent_commands.add_parser("rename")
    rename_agent.add_argument("pane_id")
    rename_agent.add_argument("name")

    fixture = groups.add_parser("fixture")
    fixture_commands = fixture.add_subparsers(dest="command", required=True)
    seed = fixture_commands.add_parser("seed-workspace")
    seed.add_argument("checkout_path")
    seed.add_argument("--workspace-id")
    seed.add_argument("--linked-worktree", action="store_true")
    seed.add_argument("--anchor", action="store_true")
    status = fixture_commands.add_parser("set-status")
    status.add_argument("pane_id")
    status.add_argument("--agent-status", choices=sorted(AGENT_STATUSES))
    failure = fixture_commands.add_parser("queue-failure")
    failure.add_argument("operation")
    failure.add_argument("--kind", choices=("api", "malformed", "timeout_after_success"), default="api")
    failure.add_argument("--times", type=int, default=1)
    failure.add_argument("--after-commit", action="store_true")
    failure.add_argument("--message", default="injected herdr API failure")
    fixture_commands.add_parser("log")
    fixture_commands.add_parser("state")
    advance = fixture_commands.add_parser("advance")
    advance.add_argument("seconds", type=float)
    return parser


def main(argv: list[str] | None = None) -> int:
    values = list(argv if argv is not None else os.sys.argv[1:])
    omp_args: list[str] = []
    if "--" in values:
        command = values.index("agent") if "agent" in values else -1
        if command >= 0 and values[command:command + 2] == ["agent", "start"]:
            split = values.index("--")
            omp_args = values[split + 1:]
            values = values[:split]
    args = _build_parser().parse_args(values)
    herdr = FakeHerdr(_state_path(args.state))
    try:
        if args.group == "workspace":
            if args.command == "list":
                result = {"workspaces": herdr.list_workspaces()}
            elif args.command == "get":
                result = {"workspace": herdr.get_workspace(args.workspace_id)}
            else:
                result = herdr.close_workspace(args.workspace_id, force=args.force)
        elif args.group == "tab":
            if args.command == "list":
                result = {"tabs": herdr.list_tabs(args.workspace)}
            elif args.command == "create":
                result = herdr.create_tab(
                    args.workspace,
                    args.cwd,
                    label=args.label,
                    protected=args.protected,
                )
            elif args.command == "get":
                result = {"tab": herdr.get_tab(args.tab_id)}
            elif args.command == "rename":
                result = {"tab": herdr.rename_tab(args.tab_id, args.label)}
            else:
                result = herdr.close_tab(
                    args.tab_id,
                    expected_workspace_id=args.expected_workspace,
                    expected_pane_id=args.expected_pane,
                    expected_session_id=args.expected_session,
                    expected_agent_name=args.expected_agent,
                    require_guard=args.require_guard,
                    allow_protected=args.allow_protected,
                )
        elif args.group == "pane":
            result = (
                {"pane": herdr.get_pane(args.pane_id)}
                if args.command == "get"
                else {"panes": herdr.list_panes(args.workspace, args.tab)}
            )
        elif args.group == "agent":
            if args.command == "list":
                result = {"agents": herdr.list_agents()}
            elif args.command == "start":
                result = {
                    "agent": herdr.start_agent(
                        args.name, args.pane, kind=args.kind, omp_args=omp_args
                    )
                }
            elif args.command == "prompt":
                result = {"agent": herdr.prompt_agent(args.name, args.prompt)}
            else:
                result = {"agent": herdr.rename_agent(args.pane_id, args.name)}
        elif args.command == "seed-workspace":
            result = {
                "workspace": herdr.create_workspace(
                    args.checkout_path,
                    workspace_id=args.workspace_id,
                    linked_worktree=args.linked_worktree,
                    anchor=args.anchor,
                )
            }
        elif args.command == "set-status":
            result = {"pane": herdr.set_status(args.pane_id, agent_status=args.agent_status)}
        elif args.command == "queue-failure":
            herdr.queue_failure(
                args.operation,
                args.kind,
                times=args.times,
                after_commit=args.after_commit,
                message=args.message,
            )
            result = {"queued": args.times, "operation": args.operation}
        elif args.command == "log":
            result = {"log": herdr.log}
        elif args.command == "state":
            result = herdr.snapshot()
        else:
            result = {"time": herdr.advance(args.seconds)}
        print(json.dumps({"ok": True, "result": result}, sort_keys=True))
        return 0
    except MalformedResponse as error:
        print(error.payload)
        return 0
    except APIError as error:
        print(json.dumps({"ok": False, "error": {"code": error.code, "message": str(error), "committed": error.committed}}), file=os.sys.stderr)
        return 124 if isinstance(error, TimeoutAfterSuccess) else 1
    except (HerdrFixtureError, KeyError, ValueError) as error:
        code = "not_found" if isinstance(error, (NotFound, KeyError)) else "fixture_error"
        print(json.dumps({"ok": False, "error": {"code": code, "message": str(error), "committed": False}}), file=os.sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
