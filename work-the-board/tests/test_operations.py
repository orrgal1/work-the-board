from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

TESTS = Path(__file__).resolve().parent
SCRIPTS = TESTS.parent / "scripts"
FIXTURES = TESTS / "fixtures"
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(FIXTURES))

from fake_clock import FakeClock
from fake_herdr import FakeHerdr, TimeoutAfterSuccess
from fake_reports import FakeReports
from operation_state import (
    LaunchIntentStatus,
    LeaseDisposition,
    OperationIdentity,
    OperationState,
    ReportStatus,
)
from operation_state import OperationStore
from ops import ControllerError, OperationController, SafetyDisposition


class OperationFixture:
    def __init__(self, root: Path, name: str) -> None:
        self.root = root / name
        self.root.mkdir()
        self.clock = FakeClock(100.0)
        self.herdr_path = self.root / "herdr.json"
        self.report_path = self.root / "reports.json"
        self.store_path = self.root / "operations.sqlite3"
        self.herdr = FakeHerdr(self.herdr_path, now=self.clock)
        workspace = self.herdr.create_workspace(
            str(self.root / "checkout"), workspace_id=f"ws-{name}", anchor=True
        )
        self.workspace_id = workspace["workspace_id"]
        self.anchor_id = next(
            tab["tab_id"]
            for tab in self.herdr.list_tabs(self.workspace_id)
            if tab["protected"]
        )
        created = self.herdr.create_tab(
            self.workspace_id, str(self.root / "checkout"), label=f"op:{name}"
        )
        self.tab_id = created["tab"]["tab_id"]
        self.pane_id = created["root_pane"]["pane_id"]
        self.terminal_id = created["root_pane"]["terminal_id"]
        agent = self.herdr.start_agent(f"agent-{name}", self.pane_id)
        self.session_id = agent["session_id"]
        self.identity = OperationIdentity(
            board="board-main",
            repo="owner/repo",
            workspace=self.workspace_id,
            tab=self.tab_id,
            root_pane=self.pane_id,
            terminal=self.terminal_id,
            session=self.session_id,
        )
        self.store = OperationStore(str(self.store_path), clock=self.clock)
        self.reports = FakeReports(self.report_path, now=self.clock)
        self.reports.recipient = "board-main"
        self.controller = OperationController(
            self.store,
            self.herdr,
            reports=self.reports,
            anchors={self.workspace_id: self.anchor_id},
            clock=self.clock,
        )
        self.operation_id = f"op-{name}"
        self.controller.launch(
            self.operation_id, 1, self.identity, evidence="fixture launch"
        )

    def complete_and_acknowledge(self, report_id: str | None = None) -> str:
        report_id = report_id or f"report-{self.operation_id}"
        _, report = self.controller.complete(
            self.operation_id, 1, report_id, "final result", evidence="explicit completion"
        )
        self.reports.relay(report_id)
        self.reports.acknowledge(report_id)
        acknowledged = self.controller.acknowledge(
            self.operation_id,
            1,
            report_id,
            digest=report.digest,
            recipient="board-main",
            evidence="recipient acknowledged exact report",
        )
        assert acknowledged.status == ReportStatus.ACKNOWLEDGED
        return report_id

    def close_calls(self) -> list[dict[str, object]]:
        return [entry for entry in self.herdr.log if entry["operation"] == "tab.close"]


class OperationLifecycleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def fixture(self, name: str) -> OperationFixture:
        return OperationFixture(self.root, name)

    def test_completed_acknowledged_unretained_operation_closes_exactly_once(self) -> None:
        case = self.fixture("close-once")
        report_id = case.complete_and_acknowledge()
        case.herdr.set_status(case.pane_id, agent_status="idle", operation_status="completed")

        first = case.controller.tick()
        second = case.controller.tick()

        self.assertEqual(first.closed_operations, (f"{case.operation_id}:1",))
        self.assertEqual(second.closed_operations, ())
        self.assertEqual(case.store.get(case.operation_id, 1).state, OperationState.CLOSED)
        report = case.store.list_reports(operation_id=case.operation_id, generation=1)[0]
        self.assertEqual(report.report_id, report_id)
        self.assertEqual(report.status, ReportStatus.ACKNOWLEDGED)
        self.assertEqual(len(case.close_calls()), 1)

    def test_running_waiting_retained_and_terminal_status_alone_are_safe(self) -> None:
        case = self.fixture("vetoes")
        for status in ("idle", "done"):
            case.herdr.set_status(case.pane_id, agent_status=status)
            case.controller.tick()
            self.assertEqual(case.store.get(case.operation_id, 1).state, OperationState.WORKING)
            self.assertIsNotNone(case.herdr.get_tab(case.tab_id))

        case.controller.transition(
            case.operation_id,
            1,
            OperationState.WAITING_USER,
            evidence="awaiting operator",
        )
        case.controller.tick()
        self.assertEqual(case.store.get(case.operation_id, 1).state, OperationState.WAITING_USER)

        case.controller.complete(
            case.operation_id, 1, "report-vetoes", "final result", submit=True
        )
        report = case.store.list_reports(operation_id=case.operation_id, generation=1)[0]
        case.reports.relay(report.report_id)
        case.reports.acknowledge(report.report_id)
        case.controller.acknowledge(
            case.operation_id,
            1,
            report.report_id,
            digest=report.digest,
            recipient="board-main",
            evidence="ack",
        )
        case.controller.retain(
            case.operation_id,
            1,
            "lease-vetoes",
            "reviewer",
            "operator retained review",
            expires_at=200.0,
        )
        result = case.controller.tick()
        self.assertTrue(result.deferred_operations)
        self.assertIsNotNone(case.herdr.get_tab(case.tab_id))
        self.assertEqual(case.close_calls(), [])

    def test_report_retry_survives_controller_restart_with_same_identity(self) -> None:
        case = self.fixture("retry")
        case.reports.queue_failure("submit", times=1, message="recipient unavailable")
        _, failed = case.controller.complete(
            case.operation_id, 1, "report-stable", "durable final"
        )
        self.assertEqual(failed.status, ReportStatus.PENDING)
        self.assertEqual(failed.last_error, "recipient unavailable")

        restarted_store = OperationStore(str(case.store_path), clock=case.clock)
        restarted_herdr = FakeHerdr(case.herdr_path, now=case.clock)
        restarted_reports = FakeReports(case.report_path, now=case.clock)
        restarted_reports.recipient = "board-main"
        restarted = OperationController(
            restarted_store,
            restarted_herdr,
            reports=restarted_reports,
            anchors={case.workspace_id: case.anchor_id},
            clock=case.clock,
        )
        result = restarted.tick()

        stored = restarted_store.list_reports(
            operation_id=case.operation_id, generation=1
        )[0]
        self.assertEqual(result.submitted_reports, ("report-stable",))
        self.assertEqual(stored.report_id, "report-stable")
        self.assertEqual(stored.status, ReportStatus.SUBMITTED)
        self.assertEqual(restarted_reports.get("report-stable")["attempts"]["submit"], 1)

    def test_submitted_acknowledgment_reconciles_after_restart(self) -> None:
        case = self.fixture("ack-restart")
        operation, report = case.controller.complete(
            case.operation_id,
            1,
            "report-ack-restart",
            "durable final",
            submit=False,
        )
        self.assertEqual(operation.state, OperationState.COMPLETED)
        submitted = case.controller.submit_report(report)
        self.assertEqual(submitted.status, ReportStatus.SUBMITTED)
        case.reports.relay(report.report_id)
        case.reports.acknowledge(report.report_id)

        restarted = OperationController(
            OperationStore(str(case.store_path), clock=case.clock),
            FakeHerdr(case.herdr_path, now=case.clock),
            reports=FakeReports(case.report_path, now=case.clock),
            anchors={case.workspace_id: case.anchor_id},
            clock=case.clock,
        )
        restarted.reports.recipient = "board-main"
        restarted.tick()
        stored = restarted.store.list_reports(
            operation_id=case.operation_id, generation=1
        )[0]
        self.assertEqual(stored.status, ReportStatus.ACKNOWLEDGED)

    def test_retention_release_and_expiry_each_enable_cleanup(self) -> None:
        released = self.fixture("released")
        released.complete_and_acknowledge()
        released.herdr.set_status(released.pane_id, agent_status="idle")
        released.controller.retain(
            released.operation_id,
            1,
            "lease-release",
            "operator",
            "review",
            expires_at=200.0,
        )
        released.controller.tick()
        released.controller.release(
            released.operation_id, 1, "lease-release", evidence="review complete"
        )
        released.controller.tick()
        self.assertEqual(
            released.store.list_retention(released.operation_id, 1)[0].disposition,
            LeaseDisposition.RELEASED,
        )
        self.assertEqual(released.store.get(released.operation_id, 1).state, OperationState.CLOSED)

        expired = self.fixture("expired")
        expired.complete_and_acknowledge()
        expired.herdr.set_status(expired.pane_id, agent_status="idle")
        expired.controller.retain(
            expired.operation_id,
            1,
            "lease-expiry",
            "operator",
            "bounded review",
            expires_at=110.0,
        )
        expired.controller.tick()
        expired.clock.advance(10.0)
        result = expired.controller.tick()
        self.assertEqual(result.expired_leases, 1)
        self.assertEqual(
            expired.store.list_retention(expired.operation_id, 1)[0].disposition,
            LeaseDisposition.EXPIRED,
        )
        self.assertEqual(expired.store.get(expired.operation_id, 1).state, OperationState.CLOSED)

    def test_missing_moved_reused_and_extra_pane_identities_fail_closed(self) -> None:
        missing = self.fixture("missing")
        missing.complete_and_acknowledge()
        missing.herdr.close_tab(missing.tab_id)
        result = missing.controller.tick()
        self.assertEqual(result.missing_operations, (f"{missing.operation_id}:1",))
        self.assertEqual(missing.store.get(missing.operation_id, 1).state, OperationState.MISSING)

        moved = self.fixture("moved")
        moved.herdr.state["panes"][moved.pane_id]["tab_id"] = moved.anchor_id
        moved.herdr._save()
        decision = moved.controller.inspect_identity(
            moved.store.get(moved.operation_id, 1),
            require_quiescent=True,
            require_anchor=True,
        )
        self.assertEqual(decision.disposition, SafetyDisposition.REFUSED)
        self.assertIn("moved", decision.reason)

        reused = self.fixture("reused")
        reused.herdr.state["panes"][reused.pane_id]["terminal_id"] = "replacement-terminal"

        reused.herdr._save()
        decision = reused.controller.inspect_identity(
            reused.store.get(reused.operation_id, 1),
            require_quiescent=True,
            require_anchor=True,
        )
        self.assertEqual(decision.disposition, SafetyDisposition.REFUSED)
        self.assertIn("terminal identity changed", decision.reason)

        extra = self.fixture("extra-pane")
        spare = extra.herdr.create_tab(
            extra.workspace_id, str(extra.root / "checkout"), label="spare"
        )
        spare_tab = spare["tab"]["tab_id"]
        spare_pane = spare["root_pane"]["pane_id"]
        extra.herdr.state["tabs"][spare_tab]["pane_ids"].remove(spare_pane)
        extra.herdr.state["workspaces"][extra.workspace_id]["tab_ids"].remove(spare_tab)
        extra.herdr.state["tabs"].pop(spare_tab)
        extra.herdr.state["panes"][spare_pane]["tab_id"] = extra.tab_id
        extra.herdr.state["tabs"][extra.tab_id]["pane_ids"].append(spare_pane)
        extra.herdr._save()
        decision = extra.controller.inspect_identity(
            extra.store.get(extra.operation_id, 1),
            require_quiescent=True,
            require_anchor=True,
        )
        self.assertEqual(decision.disposition, SafetyDisposition.REFUSED)
        self.assertIn("sole registered pane", decision.reason)
    def test_missing_live_agent_becomes_reported_failure(self) -> None:
        case = self.fixture("dead-agent")
        agent_name = next(iter(case.herdr.state["agents"]))
        case.herdr.state["agents"].pop(agent_name)
        case.herdr.state["panes"][case.pane_id]["agent_name"] = None
        case.herdr.state["panes"][case.pane_id]["session_id"] = None
        case.herdr._save()

        case.controller.tick()

        self.assertEqual(
            case.store.get(case.operation_id, 1).state,
            OperationState.FAILED,
        )
        reports = case.store.list_reports(
            operation_id=case.operation_id, generation=1
        )
        self.assertTrue(any(report.is_final for report in reports))

    def test_anchor_and_last_tab_configuration_never_authorize_close(self) -> None:
        case = self.fixture("anchor")
        unsafe = OperationController(
            case.store,
            case.herdr,
            reports=case.reports,
            anchors={case.workspace_id: case.tab_id},
            clock=case.clock,
        )
        decision = unsafe.inspect_identity(
            case.store.get(case.operation_id, 1),
            require_quiescent=True,
            require_anchor=True,
        )
        self.assertEqual(decision.disposition, SafetyDisposition.REFUSED)
        self.assertIn("configured as the workspace anchor", decision.reason)
        self.assertIsNotNone(case.herdr.get_tab(case.tab_id))
        self.assertIsNotNone(case.herdr.get_tab(case.anchor_id))
        self.assertEqual(case.close_calls(), [])


    def test_launch_intent_restart_reconciles_without_duplicate_and_retries_only_absence(self) -> None:
        case = self.fixture("launch-intent")
        calls = {"count": 0}

        class CommittedAfterSideEffect(RuntimeError):
            committed = True

        def committed_effect() -> dict[str, str]:
            calls["count"] += 1
            raise CommittedAfterSideEffect("create committed before response")

        with self.assertRaises(CommittedAfterSideEffect):
            case.controller.execute_launch_intent(
                case.operation_id,
                1,
                intent_id="create-intent",
                kind="create",
                idempotency_key="create-key",
                payload={"label": "business-action"},
                effect=committed_effect,
                probe=lambda: None,
            )
        self.assertEqual(calls["count"], 1)
        self.assertEqual(
            case.store.get_launch_intent("create-intent").status,
            LaunchIntentStatus.AMBIGUOUS,
        )

        restarted = OperationController(
            OperationStore(str(case.store_path), clock=case.clock),
            case.herdr,
            reports=case.reports,
            anchors={case.workspace_id: case.anchor_id},
            clock=case.clock,
        )
        with self.assertRaises(ControllerError):
            restarted.execute_launch_intent(
                case.operation_id,
                1,
                intent_id="create-intent",
                kind="create",
                idempotency_key="create-key",
                payload={"label": "business-action"},
                effect=committed_effect,
                probe=lambda: None,
            )
        self.assertEqual(calls["count"], 1)

        outcome = {"tab_id": "tab-created"}
        reconciled = restarted.execute_launch_intent(
            case.operation_id,
            1,
            intent_id="create-intent",
            kind="create",
            idempotency_key="create-key",
            payload={"label": "business-action"},
            effect=committed_effect,
            probe=lambda: outcome,
        )
        self.assertEqual(reconciled, outcome)
        self.assertEqual(calls["count"], 1)

        case.store.prepare_launch_intent(
            case.operation_id,
            1,
            "retry-intent",
            "start",
            "retry-key",
            {"label": "business-action"},
        )
        claimed = case.store.claim_launch_intent("retry-intent")
        self.assertIsNotNone(claimed)
        self.assertEqual(claimed.status, LaunchIntentStatus.EXECUTING)
        retried = restarted.execute_launch_intent(
            case.operation_id,
            1,
            intent_id="retry-intent",
            kind="start",
            idempotency_key="retry-key",
            payload={"label": "business-action"},
            effect=lambda: {"started": "true"},
            probe=lambda: False,
        )
        self.assertEqual(retried, {"started": "true"})
        self.assertEqual(case.store.get_launch_intent("retry-intent").status, LaunchIntentStatus.COMMITTED)

    def test_launch_operation_reconciles_create_and_start_but_never_replays_ambiguous_prompt(self) -> None:
        for failed_step in ("tab.create", "agent.start", "agent.prompt"):
            root = Path(self.temporary.name) / failed_step.replace(".", "-")
            root.mkdir()
            clock = FakeClock(200.0)
            herdr_path = root / "herdr.json"
            store_path = root / "operations.sqlite3"
            herdr = FakeHerdr(herdr_path, now=clock)
            workspace = herdr.create_workspace(
                str(root), workspace_id=f"ws-{failed_step}", anchor=True
            )
            herdr.queue_failure(failed_step, kind="timeout_after_success")
            controller = OperationController(
                OperationStore(str(store_path), clock=clock), herdr, clock=clock
            )
            arguments = dict(
                board="board-main",
                repo="owner/repo",
                workspace=workspace["workspace_id"],
                cwd=str(root),
                agent_name=f"agent-{failed_step}",
                prompt="perform the business action exactly once",
                label="op: crash recovery",
                evidence="fixture launch",
            )
            with self.assertRaises(TimeoutAfterSuccess):
                controller.launch_operation("operation", 0, **arguments)

            restarted_herdr = FakeHerdr(herdr_path, now=clock)
            restarted = OperationController(
                OperationStore(str(store_path), clock=clock),
                restarted_herdr,
                clock=clock,
            )
            if failed_step == "agent.prompt":
                with self.assertRaises(ControllerError):
                    restarted.launch_operation("operation", 0, **arguments)
            else:
                operation = restarted.launch_operation("operation", 0, **arguments)
                self.assertEqual(operation.state, OperationState.WORKING)
            actions = [
                entry for entry in restarted_herdr.log
                if entry["operation"] == failed_step
            ]
            self.assertEqual(len(actions), 1, failed_step)

    def test_persistent_service_survives_controlled_operation_close(self) -> None:
        case = self.fixture("persistent-service")
        service = case.herdr.start_service(
            case.pane_id, name="deployment", persistent=True
        )
        case.complete_and_acknowledge()
        case.controller.tick()

        stored = next(
            item for item in case.herdr.list_services()
            if item["service_id"] == service["service_id"]
        )
        self.assertTrue(stored["running"])
        self.assertTrue(stored["detached"])
        self.assertEqual(
            case.store.get(case.operation_id, 1).state,
            OperationState.CLOSED,
        )

if __name__ == "__main__":
    unittest.main()
