from __future__ import annotations

import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

from test_operations import OperationFixture, SCRIPTS, FIXTURES
from fake_herdr import FakeHerdr, TimeoutAfterSuccess, APIError
from operation_state import (
    OperationStore, OperationState, ReportStatus, LaunchIntentStatus,
    LifecycleConflict, StaleGeneration,
)
from ops import OperationController, ControllerError

ROOT = SCRIPTS.parent.parent


class ProductionSessions(FakeHerdr):
    @staticmethod
    def structured(item):
        item = dict(item)
        session = item.pop("session_id", None)
        if session:
            item["agent_session"] = {"kind": "path", "value": session, "agent": "omp"}
        return item

    def get_pane(self, pane_id):
        return self.structured(super().get_pane(pane_id))

    def list_agents(self):
        return [self.structured(item) for item in super().list_agents()]

    def start_agent(self, *args, **kwargs):
        return {"agent": self.structured(super().start_agent(*args, **kwargs))}


class ReviewRegressionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def launch_case(self, herdr_type=FakeHerdr):
        herdr = herdr_type(self.root / "herdr.json")
        herdr.create_workspace(str(self.root), workspace_id="workspace", anchor=True)
        store = OperationStore(str(self.root / "registry.sqlite3"))
        args = dict(board="board", repo="owner/repo", workspace="workspace",
                    cwd=str(self.root), agent_name="operation-agent", prompt="business action",
                    label="operation", evidence="launch requested")
        return OperationController(store, herdr), args

    def test_structured_session_recovery_matches_live_pane(self):
        controller, args = self.launch_case(ProductionSessions)
        controller.herdr.queue_failure("agent.start", kind="timeout_after_success")
        with self.assertRaises(TimeoutAfterSuccess):
            controller.launch_operation("op", 0, **args)
        restarted = OperationController(
            OperationStore(controller.store.path), ProductionSessions(self.root / "herdr.json")
        )
        record = restarted.launch_operation("op", 0, **args)
        self.assertEqual(record.state, OperationState.WORKING)
        self.assertEqual(record.identity.session, "session_1")
        restarted.launch_operation("op", 0, **args)
        for action in ("agent.start", "agent.prompt"):
            self.assertEqual(sum(row["operation"] == action for row in restarted.herdr.log), 1)

    def test_acknowledgment_requires_durable_recipient_with_or_without_adapter(self):
        case = OperationFixture(self.root, "recipient")
        _, report = case.controller.complete(case.operation_id, 1, "final", "result")
        for configured in (False, True):
            with self.subTest(configured=configured):
                reports = case.reports if configured else None
                if reports is not None:
                    reports.recipient = "someone-else"
                controller = OperationController(case.store, case.herdr, reports=reports)
                with self.assertRaises(ControllerError):
                    controller.acknowledge(case.operation_id, 1, report.report_id,
                                           digest=report.digest, recipient="someone-else",
                                           evidence="wrong destination")
                self.assertEqual(case.store.list_reports()[0].status, ReportStatus.SUBMITTED)
        OperationController(case.store, case.herdr).acknowledge(
            case.operation_id, 1, report.report_id, digest=report.digest,
            recipient=report.recipient, evidence="delivered to original destination")
        self.assertEqual(case.store.list_reports()[0].status, ReportStatus.ACKNOWLEDGED)

    def test_historical_report_delivery_survives_replacement_generation(self):
        for submitted in (False, True):
            with self.subTest(submitted=submitted):
                case = OperationFixture(self.root, f"historical-{submitted}")
                _, report = case.controller.complete(case.operation_id, 1, f"report-{submitted}",
                                                      "original result", submit=submitted)
                case.herdr.close_tab(case.tab_id)
                case.store.transition(case.operation_id, 1, OperationState.MISSING,
                                      evidence="original tab disappeared")
                case.store.register(case.operation_id, 2, case.identity)
                if not submitted:
                    case.reports.queue_failure("submit")
                    failed = case.controller.submit_report(report)
                    self.assertEqual(failed.status, ReportStatus.PENDING)
                    case.controller.submit_report(failed)
                case.controller.acknowledge(case.operation_id, 1, report.report_id,
                                            digest=report.digest, recipient=report.recipient,
                                            evidence="original result delivered")
                self.assertEqual(case.store.list_reports(generation=1)[0].status,
                                 ReportStatus.ACKNOWLEDGED)
                self.assertEqual(case.store.get(case.operation_id).generation, 2)
                self.assertEqual(case.store.get(case.operation_id).state, OperationState.REGISTERED)

    def test_old_launch_schema_preserves_records_and_supports_preregistration(self):
        case = OperationFixture(self.root, "migration")
        with sqlite3.connect(case.store.path) as db:
            db.executescript("""
                DROP TABLE launch_intents;
                CREATE TABLE launch_intents (
                    intent_id TEXT PRIMARY KEY, operation_id TEXT NOT NULL,
                    generation INTEGER NOT NULL,
                    kind TEXT NOT NULL CHECK (kind IN ('create','start','prompt')),
                    idempotency_key TEXT NOT NULL UNIQUE, payload TEXT NOT NULL,
                    status TEXT NOT NULL CHECK (status IN ('pending','committed','ambiguous','failed')),
                    outcome TEXT, evidence TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL,
                    FOREIGN KEY(operation_id,generation) REFERENCES operations(operation_id,generation)
                );
                PRAGMA user_version = 2;
            """)
            for status in ("pending", "committed", "ambiguous", "failed"):
                db.execute("INSERT INTO launch_intents VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                           (status, case.operation_id, 1, "start", f"key-{status}", '{"name":"saved"}',
                            status, '{"session":"saved"}', "original evidence", 10, 20))
            before = db.execute("SELECT * FROM launch_intents ORDER BY intent_id").fetchall()
        migrated = OperationStore(case.store.path)
        with sqlite3.connect(case.store.path) as db:
            self.assertEqual(db.execute("SELECT * FROM launch_intents ORDER BY intent_id").fetchall(), before)
            self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], 3)
        self.assertEqual(migrated.claim_launch_intent("pending").status, LaunchIntentStatus.EXECUTING)
        migrated.prepare_launch_intent("not-yet-registered", 0, "new", "create", "new-key", {"cwd": "/tmp"})
        self.assertEqual(OperationStore(case.store.path).get_launch_intent("committed").outcome,
                         '{"session":"saved"}')

    def test_live_executor_cannot_be_reclaimed_by_another_process(self):
        controller, args = self.launch_case()
        code = '''import json, sys
sys.path[:0] = sys.argv[1:3]
from operation_state import OperationStore
from ops import OperationController
from fake_herdr import FakeHerdr
herdr = FakeHerdr(sys.argv[4])
original = herdr.create_tab
def paused(*args, **kwargs):
    print("claimed", flush=True)
    sys.stdin.readline()
    return original(*args, **kwargs)
herdr.create_tab = paused
controller = OperationController(OperationStore(sys.argv[3]), herdr)
controller.launch_operation("op", 0, **json.loads(sys.argv[5]))
'''
        child = subprocess.Popen(
            [sys.executable, "-c", code, str(SCRIPTS), str(FIXTURES), controller.store.path,
             str(self.root / "herdr.json"), json.dumps(args)],
            cwd=str(ROOT), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            self.assertEqual(child.stdout.readline().strip(), "claimed")
            with self.assertRaises(LifecycleConflict):
                controller.launch_operation("op", 0, **args)
        finally:
            _, errors = child.communicate("continue\n", timeout=10)
        self.assertEqual(child.returncode, 0, errors)
        herdr = FakeHerdr(self.root / "herdr.json")
        self.assertEqual(sum(row["operation"] == "tab.create" for row in herdr.log), 1)
        self.assertEqual(sum(row["operation"] == "agent.prompt" for row in herdr.log), 1)

    def test_renamed_ambiguous_create_is_not_replayed_or_adopted_by_label(self):
        controller, args = self.launch_case()
        controller.herdr.queue_failure("tab.create", kind="timeout_after_success")
        with self.assertRaises(TimeoutAfterSuccess):
            controller.launch_operation("op", 0, **args)
        tab = next(tab for tab in controller.herdr.list_tabs() if not tab["protected"])
        controller.herdr.rename_tab(tab["tab_id"], "renamed by operator")
        controller.herdr.create_tab("workspace", str(self.root), label="operation [op:0]")
        restarted = OperationController(OperationStore(controller.store.path), FakeHerdr(self.root / "herdr.json"))
        with self.assertRaises(ControllerError):
            restarted.launch_operation("op", 0, **args)
        self.assertEqual(sum(row["operation"] == "tab.create" for row in restarted.herdr.log), 2)
        self.assertEqual(restarted.herdr.list_agents(), [])

    def test_known_precommit_failure_can_retry_but_invalid_generations_have_no_effects(self):
        controller, args = self.launch_case()
        controller.herdr.queue_failure("tab.create", kind="api")
        with self.assertRaises(APIError):
            controller.launch_operation("op", 1, **args)
        with self.assertRaises(LifecycleConflict):
            controller.launch_operation("op", 1, **dict(args, prompt="different business action"))
        self.assertEqual(controller.launch_operation("op", 1, **args).state, OperationState.WORKING)
        before = controller.herdr.log
        for generation, error in ((-1, ValueError), (0, StaleGeneration), (2, LifecycleConflict)):
            with self.subTest(generation=generation), self.assertRaises(error):
                controller.launch_operation("op", generation, **args)
        self.assertEqual(controller.herdr.log, before)

    def _resume_legacy_start(self, failure_kind):
        controller, args = self.launch_case(ProductionSessions)
        controller.herdr.queue_failure("agent.start", kind=failure_kind)
        with self.assertRaises(APIError):
            controller.launch_operation("op", 0, **args)
        create_id = "launch:op:0:create"
        saved = controller.store.get_launch_intent(create_id)
        legacy = {key: value for key, value in json.loads(saved.payload).items()
                  if key in {"workspace", "cwd", "label"}}
        with sqlite3.connect(controller.store.path) as db:
            db.execute("UPDATE launch_intents SET payload = ? WHERE intent_id = ?",
                       (json.dumps(legacy, sort_keys=True, separators=(",", ":")), create_id))
            db.execute("PRAGMA user_version = 2")
        restarted = OperationController(
            OperationStore(controller.store.path), ProductionSessions(self.root / "herdr.json")
        )
        with self.assertRaises(LifecycleConflict):
            restarted.launch_operation("op", 0, **dict(args, agent_name="unrelated-agent"))
        self.assertEqual(restarted.launch_operation("op", 0, **args).state, OperationState.WORKING)
        self.assertEqual(restarted.store.get_launch_intent(create_id).outcome, saved.outcome)
        self.assertEqual(sum(row["operation"] == "tab.create" for row in restarted.herdr.log), 1)
        self.assertEqual(sum(row["operation"] == "agent.start" and row["committed"]
                             for row in restarted.herdr.log), 1)
        self.assertEqual(sum(row["operation"] == "agent.prompt" for row in restarted.herdr.log), 1)
        # A fully launched legacy request also has durable owner and prompt metadata.
        with sqlite3.connect(controller.store.path) as db:
            db.execute("UPDATE launch_intents SET payload = ? WHERE intent_id = ?",
                       (json.dumps(legacy), create_id))
        for changed in (dict(args, board="wrong-board"), dict(args, prompt="different action")):
            with self.assertRaises(LifecycleConflict):
                restarted.launch_operation("op", 0, **changed)
        self.assertEqual(restarted.launch_operation("op", 0, **args).state, OperationState.WORKING)

    def test_upgrade_resumes_old_create_and_retryable_start(self):
        self._resume_legacy_start("api")

    def test_upgrade_resumes_old_create_and_ambiguous_start(self):
        self._resume_legacy_start("timeout_after_success")


if __name__ == "__main__":
    unittest.main()
