#!/usr/bin/env python3
"""Operation lifecycle controller and restart-safe maintenance CLI."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from enum import Enum
from typing import Any, Callable, Mapping, Optional, Sequence

from operation_state import (
    CloseDisposition,
    CloseIntent,
    CloseNotEligible,
    LeaseDisposition,
    LifecycleConflict,
    OperationIdentity,
    OperationRecord,
    OperationState,
    OperationStore,
    OperationStoreError,
    ReportRecord,
    ReportStatus,
)


class ControllerError(RuntimeError):
    """An operation could not be advanced safely."""


class SnapshotError(ControllerError):
    """A runtime snapshot was absent, malformed, or internally inconsistent."""


class AdapterError(ControllerError):
    def __init__(self, message: str, *, committed: bool = False) -> None:
        super().__init__(message)
        self.committed = committed


@dataclass(frozen=True)
class RuntimeSnapshot:
    workspaces: tuple[Mapping[str, Any], ...]
    tabs: tuple[Mapping[str, Any], ...]
    panes: tuple[Mapping[str, Any], ...]
    agents: tuple[Mapping[str, Any], ...]


class SafetyDisposition(str, Enum):
    SAFE = "safe"
    MISSING = "missing"
    DEFERRED = "deferred"
    REFUSED = "refused"


@dataclass(frozen=True)
class SafetyDecision:
    disposition: SafetyDisposition
    reason: str
    snapshot: Optional[RuntimeSnapshot] = None


@dataclass(frozen=True)
class TickResult:
    expired_leases: int
    submitted_reports: tuple[str, ...]
    report_errors: tuple[str, ...]
    closed_operations: tuple[str, ...]
    missing_operations: tuple[str, ...]
    deferred_operations: tuple[str, ...]
    refused_operations: tuple[str, ...]


class JsonCommand:
    """Strict JSON subprocess adapter; malformed output is never treated as absence."""

    def __init__(self, command: Sequence[str]) -> None:
        if not command:
            raise ValueError("command must not be empty")
        executable = command[0]
        if os.path.isabs(executable):
            resolved = executable
        else:
            resolved = shutil.which(executable)
            if resolved is None:
                raise ValueError(f"executable not found: {executable}")
        self.command = (resolved, *command[1:])

    def call(self, *arguments: str) -> Mapping[str, Any]:
        completed = subprocess.run(
            (*self.command, *arguments),
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        output = completed.stdout.strip()
        error_output = completed.stderr.strip()
        if completed.returncode:
            committed = False
            message = error_output or output or f"command exited {completed.returncode}"
            for candidate in (error_output, output):
                try:
                    decoded = json.loads(candidate)
                except (TypeError, json.JSONDecodeError):
                    continue
                if isinstance(decoded, Mapping):
                    error = decoded.get("error")
                    if isinstance(error, Mapping):
                        committed = error.get("committed") is True
                        message = str(error.get("message") or error.get("code") or message)
                        break
            raise AdapterError(message, committed=committed)
        try:
            decoded = json.loads(output)
        except json.JSONDecodeError as error:
            raise SnapshotError(f"command returned malformed JSON: {error}") from error
        if not isinstance(decoded, Mapping):
            raise SnapshotError("command JSON root is not an object")
        if decoded.get("ok") is False:
            error = decoded.get("error")
            committed = isinstance(error, Mapping) and error.get("committed") is True
            message = error.get("message") if isinstance(error, Mapping) else "adapter rejected request"
            raise AdapterError(str(message), committed=committed)
        result = decoded.get("result", decoded)
        if not isinstance(result, Mapping):
            raise SnapshotError("command result is not an object")
        return result


class HerdrAdapter:
    """Adapter for the installed herdr CLI or its deterministic fixture."""

    def __init__(
        self,
        command: Sequence[str] = ("herdr",),
        *,
        conditional_close: bool = False,
    ) -> None:
        self._command = JsonCommand(command)
        self.conditional_close = conditional_close

    @staticmethod
    def _items(payload: Mapping[str, Any], name: str) -> list[Mapping[str, Any]]:
        value = payload.get(name)
        if not isinstance(value, list) or any(not isinstance(item, Mapping) for item in value):
            raise SnapshotError(f"herdr {name} snapshot is malformed")
        return list(value)

    def list_workspaces(self) -> list[Mapping[str, Any]]:
        return self._items(self._command.call("workspace", "list"), "workspaces")

    def list_tabs(self, workspace_id: Optional[str] = None) -> list[Mapping[str, Any]]:
        arguments = ["tab", "list"]
        if workspace_id is not None:
            arguments.extend(("--workspace", workspace_id))
        return self._items(self._command.call(*arguments), "tabs")

    def list_panes(
        self,
        workspace_id: Optional[str] = None,
        tab_id: Optional[str] = None,
    ) -> list[Mapping[str, Any]]:
        arguments = ["pane", "list"]
        if workspace_id is not None:
            arguments.extend(("--workspace", workspace_id))
        if tab_id is not None:
            # Supported by the fixture. Production herdr is filtered locally.
            arguments.extend(("--tab", tab_id))
        return self._items(self._command.call(*arguments), "panes")

    def list_agents(self) -> list[Mapping[str, Any]]:
        return self._items(self._command.call("agent", "list"), "agents")

    def close_tab(self, tab_id: str, **expected: Any) -> Mapping[str, Any]:
        arguments = ["tab", "close", tab_id]
        if self.conditional_close:
            names = {
                "expected_workspace_id": "--expected-workspace",
                "expected_pane_id": "--expected-pane",
                "expected_session_id": "--expected-session",
                "expected_agent_name": "--expected-agent",
            }
            for key, option in names.items():
                value = expected.get(key)
                if value:
                    arguments.extend((option, str(value)))
            arguments.append("--require-guard")
        return self._command.call(*arguments)


class ReportAdapter:
    """Stable-ID report transport. Delivery acknowledgment remains explicit."""

    def __init__(self, recipient: str, command: Sequence[str] = ("herdr",)) -> None:
        if not recipient.strip():
            raise ValueError("report recipient must not be empty")
        self.recipient = recipient
        self._command = JsonCommand(command)

    def submit(self, key: str, payload: Mapping[str, Any]) -> Mapping[str, Any]:
        body = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        self._command.call("agent", "prompt", self.recipient, body)
        return {"key": key, "submitted": True, "recipient": self.recipient}


class CommandReportAdapter:
    """Adapter for a durable report relay exposing submit/get commands."""

    def __init__(self, recipient: str, command: Sequence[str]) -> None:
        if not recipient.strip():
            raise ValueError("report recipient must not be empty")
        self.recipient = recipient
        self._command = JsonCommand(command)

    def submit(self, key: str, payload: Mapping[str, Any]) -> Mapping[str, Any]:
        return self._command.call(
            "submit",
            key,
            json.dumps(payload, sort_keys=True, separators=(",", ":")),
        )

    def get(self, key: str) -> Mapping[str, Any]:
        return self._command.call("get", key)


class OperationController:
    """Authoritative operation state transitions and conservative cleanup."""

    def __init__(
        self,
        store: OperationStore,
        herdr: Any,
        *,
        reports: Optional[Any] = None,
        anchors: Optional[Mapping[str, str]] = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.store = store
        self.herdr = herdr
        self.reports = reports
        self.anchors = dict(anchors or {})
        self._clock = clock
        self._submission_owner = f"controller-{os.getpid()}-{id(self)}"

    def register(
        self,
        operation_id: str,
        generation: int,
        identity: OperationIdentity,
        *,
        evidence: Optional[str] = None,
    ) -> OperationRecord:
        return self.store.register(operation_id, generation, identity, evidence=evidence)

    def launch(
        self,
        operation_id: str,
        generation: int,
        identity: OperationIdentity,
        *,
        evidence: str,
    ) -> OperationRecord:
        """Register an already-created runtime identity before handing it business work."""
        operation = self.register(operation_id, generation, identity, evidence=evidence)
        if operation.state == OperationState.WORKING:
            return operation
        decision = self.inspect_identity(operation, require_quiescent=False, require_anchor=False)
        if decision.disposition != SafetyDisposition.SAFE:
            raise ControllerError(f"launch identity is not safely bound: {decision.reason}")
        operation = self.store.transition(
            operation_id,
            generation,
            OperationState.LAUNCHING,
            expected_state=OperationState.REGISTERED,
            evidence=evidence,
            transition_id=f"launch:{operation_id}:{generation}",
        )
        return self.store.transition(
            operation_id,
            generation,
            OperationState.WORKING,
            expected_state=OperationState.LAUNCHING,
            evidence=evidence,
            transition_id=f"working:{operation_id}:{generation}",
        )

    def transition(
        self,
        operation_id: str,
        generation: int,
        state: OperationState,
        *,
        evidence: str,
        transition_id: Optional[str] = None,
    ) -> OperationRecord:
        if state not in {OperationState.WORKING, OperationState.WAITING_USER}:
            raise ValueError("transition accepts only working or waiting_user; use complete/fail/retire")
        return self.store.transition(
            operation_id,
            generation,
            state,
            evidence=evidence,
            transition_id=transition_id,
        )

    def enqueue_report(
        self,
        operation_id: str,
        generation: int,
        report_id: str,
        body: str,
        *,
        is_final: bool = False,
        submit: bool = False,
    ) -> ReportRecord:
        operation = self.store.get(operation_id, generation)
        recipient = getattr(self.reports, "recipient", None) or operation.identity.board
        report = self.store.enqueue_report(
            operation_id,
            generation,
            report_id,
            body,
            is_final=is_final,
            board=operation.identity.board,
            recipient=recipient,
        )
        return self.submit_report(report) if submit else report

    def complete(
        self,
        operation_id: str,
        generation: int,
        report_id: str,
        body: str,
        *,
        submit: bool = True,
        evidence: Optional[str] = None,
    ) -> tuple[OperationRecord, ReportRecord]:
        operation = self.store.get(operation_id, generation)
        recipient = getattr(self.reports, "recipient", None) or operation.identity.board
        operation, report = self.store.finalize(
            operation_id,
            generation,
            OperationState.COMPLETED,
            report_id,
            body,
            board=operation.identity.board,
            recipient=recipient,
            evidence=evidence or f"final report {report_id} persisted",
            transition_id=f"complete:{report_id}",
        )
        if submit:
            report = self.submit_report(report)
        return operation, report

    def fail(
        self,
        operation_id: str,
        generation: int,
        report_id: str,
        body: str,
        *,
        submit: bool = True,
        evidence: Optional[str] = None,
    ) -> tuple[OperationRecord, ReportRecord]:
        operation = self.store.get(operation_id, generation)
        recipient = getattr(self.reports, "recipient", None) or operation.identity.board
        operation, report = self.store.finalize(
            operation_id,
            generation,
            OperationState.FAILED,
            report_id,
            body,
            board=operation.identity.board,
            recipient=recipient,
            evidence=evidence or f"failure report {report_id} persisted",
            transition_id=f"fail:{report_id}",
        )
        if submit:
            report = self.submit_report(report)
        return operation, report

    def submit_report(self, report: ReportRecord) -> ReportRecord:
        if report.status != ReportStatus.PENDING:
            return report
        if self.reports is None:
            return report
        recipient = getattr(self.reports, "recipient", None)
        if recipient is not None and recipient != report.recipient:
            raise ControllerError(
                f"report {report.report_id!r} is bound to recipient "
                f"{report.recipient!r}, not {recipient!r}"
            )
        claimed = self.store.claim_report_submission(
            report.operation_id,
            report.generation,
            report.report_id,
            self._submission_owner,
            expires_at=self._clock() + 60.0,
        )
        if claimed is None:
            return report
        payload = {
            "report_id": claimed.report_id,
            "operation_id": claimed.operation_id,
            "generation": claimed.generation,
            "board": claimed.board,
            "digest": claimed.digest,
            "recipient": claimed.recipient,
            "is_final": claimed.is_final,
            "body": claimed.body,
        }
        try:
            response = self.reports.submit(claimed.report_id, payload)
        except BaseException as error:
            if getattr(error, "committed", False):
                return self.store.mark_report_submitted(
                    claimed.operation_id,
                    claimed.generation,
                    claimed.report_id,
                    claimed.report_id,
                    claim_owner=self._submission_owner,
                )
            return self.store.record_report_failure(
                claimed.operation_id,
                claimed.generation,
                claimed.report_id,
                str(error),
                claim_owner=self._submission_owner,
            )
        submission_id = (
            response.get("key", claimed.report_id)
            if isinstance(response, Mapping)
            else claimed.report_id
        )
        if not isinstance(submission_id, str) or not submission_id:
            return self.store.record_report_failure(
                claimed.operation_id,
                claimed.generation,
                claimed.report_id,
                "report adapter returned no stable submission id",
                claim_owner=self._submission_owner,
            )
        return self.store.mark_report_submitted(
            claimed.operation_id,
            claimed.generation,
            claimed.report_id,
            submission_id,
            claim_owner=self._submission_owner,
        )

    def acknowledge(
        self,
        operation_id: str,
        generation: int,
        report_id: str,
        *,
        digest: str,
        recipient: str,
        evidence: str,
    ) -> ReportRecord:
        reports = self.store.list_reports(operation_id=operation_id, generation=generation)
        matches = [report for report in reports if report.report_id == report_id]
        if len(matches) != 1:
            raise ControllerError(f"report {report_id!r} does not belong to this operation generation")
        report = matches[0]
        if digest != report.digest:
            raise ControllerError("acknowledgment digest does not match the durable report")
        configured = getattr(self.reports, "recipient", None)
        if configured is not None and recipient != configured:
            raise ControllerError("acknowledgment recipient does not match the report adapter")
        acknowledgment = json.dumps(
            {"digest": digest, "recipient": recipient, "evidence": evidence},
            sort_keys=True,
            separators=(",", ":"),
        )
        return self.store.acknowledge_report(
            operation_id, generation, report_id, acknowledgment
        )

    def retain(
        self,
        operation_id: str,
        generation: int,
        lease_id: str,
        holder: str,
        reason: str,
        *,
        expires_at: float,
    ) -> Any:
        return self.store.acquire_retention(
            operation_id,
            generation,
            lease_id,
            holder,
            reason,
            expires_at=expires_at,
        )

    def release(
        self,
        operation_id: str,
        generation: int,
        lease_id: str,
        *,
        evidence: str,
    ) -> Any:
        return self.store.release_retention(
            operation_id, generation, lease_id, evidence
        )

    def recover(
        self,
        operation_id: str,
        generation: int,
        state: OperationState,
        *,
        evidence: str,
    ) -> OperationRecord:
        if state not in {
            OperationState.WORKING,
            OperationState.WAITING_USER,
            OperationState.COMPLETED,
            OperationState.FAILED,
        }:
            raise ValueError("recover target must be working, waiting_user, completed, or failed")
        operation = self.store.get(operation_id, generation)
        decision = self.inspect_identity(
            operation,
            require_quiescent=state in {OperationState.COMPLETED, OperationState.FAILED},
            require_anchor=False,
        )
        if decision.disposition != SafetyDisposition.SAFE:
            raise ControllerError(f"runtime identity cannot be recovered: {decision.reason}")
        return self.store.transition(
            operation_id,
            generation,
            state,
            evidence=evidence,
            transition_id=f"recover:{operation_id}:{generation}:{state.value}:{hashlib.sha256(evidence.encode()).hexdigest()[:16]}",
        )

    def retire(
        self,
        operation_id: str,
        generation: int,
        *,
        evidence: str,
    ) -> OperationRecord:
        operation = self.store.get(operation_id, generation)
        if operation.state != OperationState.FAILED:
            raise ControllerError("only a failed operation can be explicitly retired")
        finals = [
            report
            for report in self.store.list_reports(
                operation_id=operation_id, generation=generation
            )
            if report.is_final
        ]
        if not finals or any(report.status != ReportStatus.ACKNOWLEDGED for report in finals):
            raise ControllerError("failed operation retirement requires an acknowledged final report")
        return self.store.transition(
            operation_id,
            generation,
            OperationState.RETIRING,
            evidence=evidence,
            expected_state=OperationState.FAILED,
            transition_id=f"retire:{operation_id}:{generation}",
        )

    def _snapshot(self) -> RuntimeSnapshot:
        try:
            workspaces = self.herdr.list_workspaces()
            tabs = self.herdr.list_tabs()
            # Production herdr has no --tab filter, so always fetch globally.
            try:
                panes = self.herdr.list_panes()
            except TypeError:
                panes = self.herdr.list_panes(None, None)
            agents = self.herdr.list_agents()
        except SnapshotError:
            raise
        except BaseException as error:
            raise SnapshotError(f"could not obtain complete herdr snapshot: {error}") from error
        collections = (workspaces, tabs, panes, agents)
        if any(not isinstance(value, list) for value in collections):
            raise SnapshotError("herdr snapshot collection is not a list")
        if any(not isinstance(item, Mapping) for value in collections for item in value):
            raise SnapshotError("herdr snapshot contains a non-object item")
        return RuntimeSnapshot(
            tuple(workspaces), tuple(tabs), tuple(panes), tuple(agents)
        )

    @staticmethod
    def _unique(
        items: Sequence[Mapping[str, Any]], key: str, value: str, kind: str
    ) -> Optional[Mapping[str, Any]]:
        matches = [item for item in items if item.get(key) == value]
        if len(matches) > 1:
            raise SnapshotError(f"herdr returned duplicate {kind} identity {value!r}")
        return matches[0] if matches else None

    @staticmethod
    def _session(item: Mapping[str, Any]) -> Optional[str]:
        direct = item.get("session_id")
        if isinstance(direct, str) and direct:
            return direct
        session = item.get("agent_session")
        if isinstance(session, Mapping):
            value = session.get("value")
            if isinstance(value, str) and value:
                return value
        return None

    def inspect_identity(
        self,
        operation: OperationRecord,
        *,
        require_quiescent: bool,
        require_anchor: bool,
        snapshot: Optional[RuntimeSnapshot] = None,
    ) -> SafetyDecision:
        try:
            current = snapshot or self._snapshot()
            identity = operation.identity
            workspace = self._unique(
                current.workspaces, "workspace_id", identity.workspace, "workspace"
            )
            tab = self._unique(current.tabs, "tab_id", identity.tab, "tab")
            pane = self._unique(current.panes, "pane_id", identity.root_pane, "pane")
            if workspace is None or tab is None or pane is None:
                return SafetyDecision(
                    SafetyDisposition.MISSING,
                    "registered workspace, tab, or pane is absent",
                    current,
                )
            if tab.get("workspace_id") != identity.workspace:
                return SafetyDecision(SafetyDisposition.REFUSED, "registered tab moved to another workspace", current)
            if pane.get("workspace_id") != identity.workspace or pane.get("tab_id") != identity.tab:
                return SafetyDecision(SafetyDisposition.REFUSED, "registered pane moved or changed tabs", current)
            tab_panes = [item for item in current.panes if item.get("tab_id") == identity.tab]
            if len(tab_panes) != 1 or tab_panes[0].get("pane_id") != identity.root_pane:
                return SafetyDecision(SafetyDisposition.REFUSED, "operation tab is not the sole registered pane", current)
            pane_ids = tab.get("pane_ids")
            if pane_ids is not None and pane_ids != [identity.root_pane]:
                return SafetyDecision(SafetyDisposition.REFUSED, "tab pane inventory does not exactly match", current)
            pane_count = tab.get("pane_count")
            if pane_count is not None and pane_count != 1:
                return SafetyDecision(SafetyDisposition.REFUSED, "tab reports more than one pane", current)
            if pane.get("terminal_id") != identity.terminal:
                return SafetyDecision(SafetyDisposition.REFUSED, "registered terminal identity changed", current)
            if self._session(pane) != identity.session:
                return SafetyDecision(SafetyDisposition.DEFERRED, "registered agent session is absent or changed", current)
            agents = [item for item in current.agents if item.get("pane_id") == identity.root_pane]
            if len(agents) != 1:
                return SafetyDecision(SafetyDisposition.DEFERRED, "registered pane does not have exactly one live agent identity", current)
            agent = agents[0]
            if (
                agent.get("workspace_id") != identity.workspace
                or agent.get("tab_id") != identity.tab
                or self._session(agent) != identity.session
            ):
                return SafetyDecision(SafetyDisposition.REFUSED, "agent binding no longer matches registration", current)
            agent_terminal = agent.get("terminal_id")
            if agent_terminal is not None and agent_terminal != identity.terminal:
                return SafetyDecision(SafetyDisposition.REFUSED, "agent terminal no longer matches registration", current)
            if require_quiescent:
                status = agent.get("agent_status")
                if status in {"working", "blocked"}:
                    return SafetyDecision(SafetyDisposition.DEFERRED, f"agent is still {status}", current)
                if status not in {"idle", "done", "failed", "dead"}:
                    return SafetyDecision(SafetyDisposition.DEFERRED, f"agent status is not safely quiescent: {status!r}", current)
            if require_anchor:
                anchor_id = self.anchors.get(identity.workspace)
                if not anchor_id:
                    return SafetyDecision(SafetyDisposition.REFUSED, "workspace has no configured anchor tab", current)
                if anchor_id == identity.tab:
                    return SafetyDecision(SafetyDisposition.REFUSED, "operation tab is configured as the workspace anchor", current)
                anchor = self._unique(current.tabs, "tab_id", anchor_id, "anchor tab")
                if anchor is None or anchor.get("workspace_id") != identity.workspace:
                    return SafetyDecision(SafetyDisposition.REFUSED, "configured workspace anchor is absent or moved", current)
                workspace_tabs = [item for item in current.tabs if item.get("workspace_id") == identity.workspace]
                if len(workspace_tabs) <= 1:
                    return SafetyDecision(SafetyDisposition.REFUSED, "operation tab is the workspace's last tab", current)
                declared_count = workspace.get("tab_count")
                if declared_count is not None and declared_count != len(workspace_tabs):
                    return SafetyDecision(SafetyDisposition.DEFERRED, "workspace tab inventory is inconsistent", current)
            return SafetyDecision(SafetyDisposition.SAFE, "identity and cleanup guards match", current)
        except SnapshotError as error:
            return SafetyDecision(SafetyDisposition.DEFERRED, str(error), None)

    def _pending_intent(self, operation: OperationRecord) -> Optional[CloseIntent]:
        pending = [
            intent
            for intent in self.store.list_close_intents(
                operation.operation_id, operation.generation
            )
            if intent.disposition == CloseDisposition.PENDING
        ]
        if len(pending) > 1:
            raise ControllerError("store contains multiple pending close intents")
        return pending[0] if pending else None

    def _new_intent_id(self, operation: OperationRecord) -> str:
        intents = self.store.list_close_intents(
            operation.operation_id, operation.generation
        )
        return f"close:{operation.operation_id}:{operation.generation}:{len(intents) + 1}"

    def _record_preclose_decision(
        self,
        operation: OperationRecord,
        intent: CloseIntent,
        decision: SafetyDecision,
    ) -> CloseIntent:
        disposition = (
            CloseDisposition.REFUSED
            if decision.disposition == SafetyDisposition.REFUSED
            else CloseDisposition.DEFERRED
        )
        return self.store.record_close_disposition(
            operation.operation_id,
            operation.generation,
            intent.intent_id,
            disposition,
            decision.reason,
        )

    def reconcile_close(self, operation: OperationRecord) -> SafetyDecision:
        intent = self._pending_intent(operation)
        if intent is None:
            return SafetyDecision(SafetyDisposition.DEFERRED, "operation has no pending close intent")
        decision = self.inspect_identity(
            operation, require_quiescent=True, require_anchor=True
        )
        if decision.disposition == SafetyDisposition.MISSING:
            self.store.record_close_disposition(
                operation.operation_id,
                operation.generation,
                intent.intent_id,
                CloseDisposition.MISSING,
                "registered tab absent while reconciling close intent",
            )
            return decision
        if decision.disposition != SafetyDisposition.SAFE:
            self._record_preclose_decision(operation, intent, decision)
            return decision
        expected_agent = None
        if decision.snapshot is not None:
            agents = [
                item
                for item in decision.snapshot.agents
                if item.get("pane_id") == operation.identity.root_pane
            ]
            if len(agents) == 1 and isinstance(agents[0].get("name"), str):
                expected_agent = agents[0]["name"]
        try:
            self.herdr.close_tab(
                operation.identity.tab,
                expected_workspace_id=operation.identity.workspace,
                expected_pane_id=operation.identity.root_pane,
                expected_session_id=operation.identity.session,
                expected_agent_name=expected_agent,
                require_guard=True,
            )
        except BaseException as error:
            after = self.inspect_identity(
                operation, require_quiescent=True, require_anchor=True
            )
            if after.disposition == SafetyDisposition.MISSING:
                self.store.record_close_disposition(
                    operation.operation_id,
                    operation.generation,
                    intent.intent_id,
                    CloseDisposition.CLOSED,
                    f"tab absent after ambiguous close response: {error}",
                )
                return SafetyDecision(SafetyDisposition.SAFE, "close committed despite ambiguous response", after.snapshot)
            if after.snapshot is not None:
                self.store.record_close_disposition(
                    operation.operation_id,
                    operation.generation,
                    intent.intent_id,
                    CloseDisposition.DEFERRED,
                    f"close failed and registered identity remains: {error}",
                )
            return SafetyDecision(SafetyDisposition.DEFERRED, f"close outcome unresolved: {error}", after.snapshot)
        self.store.record_close_disposition(
            operation.operation_id,
            operation.generation,
            intent.intent_id,
            CloseDisposition.CLOSED,
            "herdr confirmed operation tab close",
        )
        return SafetyDecision(SafetyDisposition.SAFE, "closed", decision.snapshot)

    def maintain_operation(self, operation: OperationRecord) -> SafetyDecision:
        pending = self._pending_intent(operation)
        if pending is not None:
            return self.reconcile_close(operation)
        decision = self.inspect_identity(
            operation, require_quiescent=True, require_anchor=True
        )
        if decision.disposition == SafetyDisposition.MISSING:
            self.store.transition(
                operation.operation_id,
                operation.generation,
                OperationState.MISSING,
                evidence=decision.reason,
                transition_id=f"missing:{operation.operation_id}:{operation.generation}",
            )
            return decision
        if decision.disposition != SafetyDisposition.SAFE:
            return decision
        try:
            intent = self.store.request_close(
                operation.operation_id,
                operation.generation,
                self._new_intent_id(operation),
                operation.identity,
                reason="automatic completed-operation cleanup"
                if operation.state == OperationState.COMPLETED
                else "explicit failed-operation retirement",
            )
        except CloseNotEligible as error:
            return SafetyDecision(SafetyDisposition.DEFERRED, error.eligibility.reason, decision.snapshot)
        return self.reconcile_close(self.store.get(operation.operation_id, operation.generation))

    def tick(self) -> TickResult:
        expired = self.store.expire_retention_leases(at=self._clock())
        submitted: list[str] = []
        report_errors: list[str] = []
        try:
            snapshot = self._snapshot()
        except SnapshotError:
            snapshot = None
        if snapshot is not None:
            for operation in self.store.list_operations(
                states=[OperationState.WORKING, OperationState.WAITING_USER]
            ):
                pane_agents = [
                    item
                    for item in snapshot.agents
                    if item.get("pane_id") == operation.identity.root_pane
                ]
                if pane_agents:
                    continue
                try:
                    self.fail(
                        operation.operation_id,
                        operation.generation,
                        f"failure:{operation.operation_id}:{operation.generation}:dead",
                        "Operation agent disappeared before explicit completion; recovery required.",
                        submit=False,
                        evidence="runtime snapshot confirmed registered agent is absent",
                    )
                except BaseException as error:
                    report_errors.append(
                        f"{operation.operation_id}:{operation.generation}: {error}"
                    )
        for report in self.store.list_reports(statuses=[ReportStatus.PENDING]):
            try:
                updated = self.submit_report(report)
                if updated.status == ReportStatus.SUBMITTED:
                    submitted.append(report.report_id)
                elif updated.last_error:
                    report_errors.append(f"{report.report_id}: {updated.last_error}")
            except BaseException as error:
                report_errors.append(f"{report.report_id}: {error}")
        report_get = getattr(self.reports, "get", None)
        if callable(report_get):
            for report in self.store.list_reports(
                statuses=[ReportStatus.SUBMITTED]
            ):
                try:
                    delivery = report_get(report.report_id)
                    if not isinstance(delivery, Mapping):
                        raise SnapshotError("report adapter returned a malformed delivery")
                    if delivery.get("acknowledged") is True:
                        acknowledgment = json.dumps(
                            {
                                "digest": report.digest,
                                "recipient": report.recipient,
                                "evidence": "recipient acknowledged durable report",
                            },
                            sort_keys=True,
                            separators=(",", ":"),
                        )
                        self.store.acknowledge_report(
                            report.operation_id,
                            report.generation,
                            report.report_id,
                            acknowledgment,
                        )
                except BaseException as error:
                    report_errors.append(f"{report.report_id}: {error}")
        closed: list[str] = []
        missing: list[str] = []
        deferred: list[str] = []
        refused: list[str] = []
        operations = self.store.list_operations(
            states=[OperationState.COMPLETED, OperationState.RETIRING]
        )
        for operation in operations:
            decision = self.maintain_operation(operation)
            key = f"{operation.operation_id}:{operation.generation}"
            current = self.store.get(operation.operation_id, operation.generation)
            if current.state == OperationState.CLOSED:
                closed.append(key)
            elif current.state == OperationState.MISSING:
                missing.append(key)
            elif decision.disposition == SafetyDisposition.REFUSED:
                refused.append(f"{key}: {decision.reason}")
            else:
                deferred.append(f"{key}: {decision.reason}")
        return TickResult(
            expired,
            tuple(submitted),
            tuple(report_errors),
            tuple(closed),
            tuple(missing),
            tuple(deferred),
            tuple(refused),
        )


def _jsonable(value: Any) -> Any:
    if hasattr(value, "__dataclass_fields__"):
        return _jsonable(asdict(value))
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, Mapping):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    return value


def _identity_from_args(args: argparse.Namespace) -> OperationIdentity:
    return OperationIdentity(
        board=args.board,
        repo=args.repo,
        workspace=args.workspace,
        tab=args.tab,
        root_pane=args.pane,
        terminal=args.terminal,
        session=args.session,
    )


def _anchors(values: Sequence[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for value in values:
        workspace, separator, tab = value.partition("=")
        if not separator or not workspace or not tab:
            raise ValueError("--anchor must be WORKSPACE=TAB")
        if workspace in result and result[workspace] != tab:
            raise ValueError(f"workspace {workspace!r} has conflicting anchors")
        result[workspace] = tab
    return result


def _absolute(value: str, name: str) -> str:
    path = Path(value).expanduser()
    if not path.is_absolute():
        raise ValueError(f"{name} must be an absolute path")
    return str(path)


def _add_operation(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("operation_id")
    parser.add_argument("generation", type=int)


def _add_identity(parser: argparse.ArgumentParser) -> None:
    _add_operation(parser)
    parser.add_argument("--board", required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--tab", required=True)
    parser.add_argument("--pane", required=True)
    parser.add_argument("--terminal", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--evidence", required=True)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-db", required=True)
    parser.add_argument("--herdr-bin", default="herdr")
    parser.add_argument("--herdr-arg", action="append", default=[])
    parser.add_argument("--herdr-conditional-close", action="store_true")
    parser.add_argument("--report-bin")
    parser.add_argument("--report-arg", action="append", default=[])
    parser.add_argument("--report-recipient")
    parser.add_argument("--anchor", action="append", default=[])
    commands = parser.add_subparsers(dest="command", required=True)

    _add_identity(commands.add_parser("register"))
    _add_identity(commands.add_parser("launch"))

    status = commands.add_parser("status")
    status.add_argument("operation_id")
    status.add_argument("--generation", type=int)
    list_command = commands.add_parser("list")
    list_command.add_argument("--state", action="append", choices=[state.value for state in OperationState])
    list_command.add_argument("--all-generations", action="store_true")

    transition = commands.add_parser("transition")
    _add_operation(transition)
    transition.add_argument("state", choices=(OperationState.WORKING.value, OperationState.WAITING_USER.value))
    transition.add_argument("--evidence", required=True)
    transition.add_argument("--transition-id")

    for name in ("complete", "fail"):
        command = commands.add_parser(name)
        _add_operation(command)
        command.add_argument("report_id")
        command.add_argument("body")
        command.add_argument("--evidence")
        command.add_argument("--no-submit", action="store_true")

    report = commands.add_parser("report")
    _add_operation(report)
    report.add_argument("report_id")
    report.add_argument("body")
    report.add_argument("--final", action="store_true")
    report.add_argument("--submit", action="store_true")

    acknowledge = commands.add_parser("ack")
    _add_operation(acknowledge)
    acknowledge.add_argument("report_id")
    acknowledge.add_argument("--digest", required=True)
    acknowledge.add_argument("--recipient", required=True)
    acknowledge.add_argument("--evidence", required=True)

    retain = commands.add_parser("retain")
    _add_operation(retain)
    retain.add_argument("lease_id")
    retain.add_argument("holder")
    retain.add_argument("reason")
    expiry = retain.add_mutually_exclusive_group(required=True)
    expiry.add_argument("--expires-at", type=float)
    expiry.add_argument("--ttl", type=float)

    release = commands.add_parser("release")
    _add_operation(release)
    release.add_argument("lease_id")
    release.add_argument("--evidence", required=True)

    recover = commands.add_parser("recover")
    _add_operation(recover)
    recover.add_argument(
        "state",
        choices=[
            OperationState.WORKING.value,
            OperationState.WAITING_USER.value,
            OperationState.COMPLETED.value,
            OperationState.FAILED.value,
        ],
    )
    recover.add_argument("--evidence", required=True)

    retire = commands.add_parser("retire")
    _add_operation(retire)
    retire.add_argument("--evidence", required=True)
    commands.add_parser("tick")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parser().parse_args(argv)
    try:
        state_db = _absolute(args.state_db, "--state-db")
        herdr_command = [args.herdr_bin, *args.herdr_arg]
        herdr = HerdrAdapter(
            herdr_command, conditional_close=args.herdr_conditional_close
        )
        reports = None
        if args.report_recipient:
            if args.report_bin:
                reports = CommandReportAdapter(
                    args.report_recipient,
                    [args.report_bin, *args.report_arg],
                )
            else:
                reports = ReportAdapter(args.report_recipient, herdr_command)
        elif args.report_bin:
            raise ValueError("--report-bin requires --report-recipient")
        controller = OperationController(
            OperationStore(state_db),
            herdr,
            reports=reports,
            anchors=_anchors(args.anchor),
        )

        if args.command in {"register", "launch"}:
            function = controller.launch if args.command == "launch" else controller.register
            result = function(
                args.operation_id,
                args.generation,
                _identity_from_args(args),
                evidence=args.evidence,
            )
        elif args.command == "status":
            result = controller.store.get(args.operation_id, args.generation)
        elif args.command == "list":
            states = [OperationState(value) for value in args.state] if args.state else None
            result = controller.store.list_operations(
                states=states, current_only=not args.all_generations
            )
        elif args.command == "transition":
            result = controller.transition(
                args.operation_id,
                args.generation,
                OperationState(args.state),
                evidence=args.evidence,
                transition_id=args.transition_id,
            )
        elif args.command == "complete":
            result = controller.complete(
                args.operation_id,
                args.generation,
                args.report_id,
                args.body,
                submit=not args.no_submit,
                evidence=args.evidence,
            )
        elif args.command == "fail":
            result = controller.fail(
                args.operation_id,
                args.generation,
                args.report_id,
                args.body,
                submit=not args.no_submit,
                evidence=args.evidence,
            )
        elif args.command == "report":
            result = controller.enqueue_report(
                args.operation_id,
                args.generation,
                args.report_id,
                args.body,
                is_final=args.final,
                submit=args.submit,
            )
        elif args.command == "ack":
            result = controller.acknowledge(
                args.operation_id,
                args.generation,
                args.report_id,
                digest=args.digest,
                recipient=args.recipient,
                evidence=args.evidence,
            )
        elif args.command == "retain":
            expires_at = args.expires_at if args.expires_at is not None else time.time() + args.ttl
            result = controller.retain(
                args.operation_id,
                args.generation,
                args.lease_id,
                args.holder,
                args.reason,
                expires_at=expires_at,
            )
        elif args.command == "release":
            result = controller.release(
                args.operation_id,
                args.generation,
                args.lease_id,
                evidence=args.evidence,
            )
        elif args.command == "recover":
            result = controller.recover(
                args.operation_id,
                args.generation,
                OperationState(args.state),
                evidence=args.evidence,
            )
        elif args.command == "retire":
            result = controller.retire(
                args.operation_id, args.generation, evidence=args.evidence
            )
        else:
            result = controller.tick()
        print(json.dumps(_jsonable(result), sort_keys=True))
        return 0
    except (AdapterError, ControllerError, OperationStoreError, ValueError) as error:
        print(f"ops.py: {error}", file=sys.stderr)
        return 1


__all__ = [
    "AdapterError",
    "CommandReportAdapter",
    "ControllerError",
    "HerdrAdapter",
    "OperationController",
    "ReportAdapter",
    "RuntimeSnapshot",
    "SafetyDecision",
    "SafetyDisposition",
    "SnapshotError",
    "TickResult",
    "main",
]


if __name__ == "__main__":
    raise SystemExit(main())
