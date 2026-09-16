from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import textwrap
import unittest

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parents[1]
sys.path.insert(0, str(TESTS))

from fixtures.fake_herdr import FakeHerdr

WATCHER = ROOT / "work-the-board" / "scripts" / "watch.sh"
FAKE_HERDR = TESTS / "fixtures" / "fake_herdr.py"
REPO = "orrgal1/work-the-board"


GH_PROGRAM = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path

path = Path(os.environ["FAKE_GH_STATE"])
state = json.loads(path.read_text())
args = sys.argv[1:]
state.setdefault("log", []).append(args)

def save():
    path.write_text(json.dumps(state, sort_keys=True))

def issue(number):
    return next(row for row in state["issues"] if row["number"] == int(number))

def labels(row):
    return [{"name": value} for value in row.get("labels", [])]

if args[:2] == ["repo", "view"]:
    print(state["repo"])
elif args[:2] == ["issue", "list"]:
    rows = [row for row in state["issues"] if row["state"] == "OPEN"]
    limit = int(args[args.index("--limit") + 1]) if "--limit" in args else 30
    rows = rows[:limit]
    if "--label" in args:
        wanted = args[args.index("--label") + 1]
        rows = [row for row in rows if wanted in row.get("labels", [])]
        for row in rows:
            print(f"{state['repo']}\t{row['number']}\t{row['title']}")
    else:
        print(json.dumps([{
            "number": row["number"], "title": row["title"],
            "body": row.get("body", ""), "labels": labels(row)
        } for row in rows]))
elif args[:2] == ["issue", "edit"]:
    row = issue(args[2])
    if "--add-label" in args:
        value = args[args.index("--add-label") + 1]
        row.setdefault("labels", [])
        if value not in row["labels"]: row["labels"].append(value)
    if "--remove-label" in args:
        value = args[args.index("--remove-label") + 1]
        row["labels"] = [item for item in row.get("labels", []) if item != value]
    print(json.dumps({"ok": True}))
elif args[:2] == ["issue", "view"]:
    row = issue(args[2])
    fields = args[args.index("--json") + 1] if "--json" in args else ""
    if fields == "state": print(row["state"])
    elif fields == "labels":
        if "mgr:in-flight" in row.get("labels", []): print("0")
    elif fields == "title": print(row["title"])
    else: print(json.dumps({"state": row["state"], "labels": labels(row), "title": row["title"]}))
elif args[:2] == ["pr", "list"]:
    print("[]")
elif args and args[0] == "api":
    if "--method" in args and args[args.index("--method") + 1] == "POST":
        print(json.dumps({"id": 1}))
    else:
        print("[]")
else:
    print(json.dumps({"error": "unsupported", "args": args}), file=sys.stderr)
    save(); sys.exit(2)
save()
'''


class WatcherIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.remote = self.root / "orrgal1" / "work-the-board.git"
        self.remote.parent.mkdir()
        subprocess.run(["git", "init", "--bare", "-q", str(self.remote)], check=True)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        subprocess.run(
            ["git", "remote", "add", "origin", str(self.remote)],
            cwd=self.repo,
            check=True,
        )
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.gh_state = self.root / "gh.json"
        self.herdr_state = self.root / "herdr.json"
        self.agent_config = self.root / "agent-config.yaml"
        self.agent_config.write_text(
            "task:\n"
            "  agentModelOverrides:\n"
            "    plan-tier3: openai-codex/gpt-6-astra:high\n"
            "    review-tier3: openai-codex/gpt-6-astra:high\n"
        )
        (self.bin / "gh").write_text(GH_PROGRAM)
        (self.bin / "gh").chmod(0o755)
        (self.bin / "herdr").write_text(textwrap.dedent(f"""\
            #!/bin/sh
            exec python3 {FAKE_HERDR} --state "$FAKE_HERDR_STATE" "$@"
        """))
        (self.bin / "herdr").chmod(0o755)
        herdr = FakeHerdr(self.herdr_state)
        herdr.create_workspace(str(self.repo), workspace_id="ws_main", anchor=True)
        anchor_pane = herdr.list_tabs()[0]["active_pane_id"]
        herdr.start_agent("board-test", anchor_pane)
        self.config = self.root / "board.json"
        self.config.write_text(json.dumps({
            "poll_seconds": 30,
            "agent_config": str(self.agent_config),
            "boards": [{
                "name": "fixture", "kind": "repo", "repo": REPO,
                "path": str(self.repo), "workspace": "ws_main",
                "concurrency": 1, "mode": "auto"
            }]
        }))
        self.board_pane = anchor_pane

    def tearDown(self) -> None:
        self.temp.cleanup()

    def watcher_env(self) -> dict[str, str]:
        env = os.environ.copy()
        env.update({
            "PATH": f"{self.bin}:{env['PATH']}",
            "FAKE_GH_STATE": str(self.gh_state),
            "FAKE_HERDR_STATE": str(self.herdr_state),
            "WORK_THE_BOARD_ONCE": "1",
        })
        return env

    def set_issues(self, issues: list[dict[str, object]]) -> None:
        prior = json.loads(self.gh_state.read_text()) if self.gh_state.exists() else {}
        self.gh_state.write_text(json.dumps({
            "repo": REPO,
            "issues": issues,
            "log": prior.get("log", []),
        }))

    def run_watcher(
        self,
        args: list[str],
        *,
        issues: list[dict[str, object]] | None = None,
        extra_env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        if issues is not None:
            self.set_issues(issues)
        env = self.watcher_env()
        env.update(extra_env or {})
        return subprocess.run(
            ["bash", str(WATCHER), *args],
            cwd=self.repo, env=env, text=True, capture_output=True, timeout=20,
        )

    def run_cycle(self, issues: list[dict[str, object]]) -> subprocess.CompletedProcess[str]:
        return self.run_watcher(["--config", str(self.config)], issues=issues)

    def input_mutations(self) -> list[list[str]]:
        return [
            argv
            for argv in FakeHerdr(self.herdr_state).argv_audit
            if any(
                value == "prompt"
                or value.startswith("composer")
                or value.replace("_", "-").startswith("send-key")
                for value in argv
            )
        ]

    def prompts_for(self, name: str) -> list[list[str]]:
        return [
            argv
            for argv in self.input_mutations()
            if any(
                argv[index:index + 3] == ["agent", "prompt", name]
                for index in range(len(argv) - 2)
            )
        ]

    def assert_only_fresh_handoff(self, name: str) -> None:
        mutations = self.input_mutations()
        self.assertEqual(mutations, self.prompts_for(name))
        self.assertEqual(len(mutations), 1)

    def seed_issue_owner(
        self,
        number: int,
        *,
        status: str,
        draft: str,
    ) -> dict[str, object]:
        herdr = FakeHerdr(self.herdr_state)
        created = herdr.create_tab(
            "ws_main",
            str(self.repo),
            label=f"fixture/issue-{number}: existing",
        )
        pane_id = created["root_pane"]["pane_id"]
        herdr.start_agent(f"fixture-issue-{number}", pane_id)
        herdr.set_status(pane_id, agent_status=status)
        herdr.set_draft(pane_id, draft)
        return next(
            row
            for row in herdr.list_agents()
            if row["name"] == f"fixture-issue-{number}"
        )

    def test_fake_herdr_audits_unsupported_input_mutation_before_parsing(self) -> None:
        argv = [
            "--state",
            str(self.herdr_state),
            "agent",
            "send-keys",
            "board-test",
            "unsafe input",
        ]
        result = subprocess.run(
            [sys.executable, str(FAKE_HERDR), *argv],
            text=True,
            capture_output=True,
            timeout=20,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(FakeHerdr(self.herdr_state).argv_audit, [argv])
        self.assertEqual(self.input_mutations(), [argv])

    def test_real_entrypoint_dispatches_only_ready_issue_and_preserves_gates(self) -> None:
        herdr = FakeHerdr(self.herdr_state)
        herdr.set_draft(self.board_pane, "BOARD DRAFT: dispatch")
        issues = [
            {"number": 1, "title": "held", "body": "", "labels": ["mgr:hold"], "state": "OPEN"},
            {"number": 2, "title": "research", "body": "", "labels": ["research"], "state": "OPEN"},
            {"number": 3, "title": "blocked", "body": "Blocked by: #1", "labels": [], "state": "OPEN"},
            {"number": 4, "title": "manual approval", "body": "", "labels": ["priority:high", "mgr:manual-approve"], "state": "OPEN"},
            {"number": 6, "title": "second ready", "body": "", "labels": [], "state": "OPEN"},
        ]
        result = self.run_cycle(issues)
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(self.gh_state.read_text())
        claimed = [row["number"] for row in state["issues"] if "mgr:in-flight" in row["labels"]]
        self.assertEqual(claimed, [4], result.stdout + result.stderr)
        herdr = FakeHerdr(self.herdr_state)
        issue_agents = [row for row in herdr.list_agents() if row["name"].startswith("fixture-issue-")]
        self.assertEqual([row["name"] for row in issue_agents], ["fixture-issue-4"])
        starts = [
            row for row in herdr.log
            if row["operation"] == "agent.start" and row["inputs"]["name"] == "fixture-issue-4"
        ]
        self.assertEqual(len(starts), 1)
        self.assertEqual(starts[0]["inputs"]["omp_args"][-2:], ["--config", str(self.agent_config)])
        prompts = [row for row in herdr.log if row["operation"] == "agent.prompt"]
        issue_prompts = [row for row in prompts if row["inputs"]["name"] == "fixture-issue-4"]
        self.assertEqual(len(issue_prompts), 1)
        self.assertIn("mgr:manual-approve", issue_prompts[0]["inputs"]["prompt"])
        self.assert_only_fresh_handoff("fixture-issue-4")
        self.assertEqual(herdr.get_pane(self.board_pane)["draft"], "BOARD DRAFT: dispatch")
        self.assertIn("in-flight=0 free=1 ready=2 launching=1", result.stdout)

    def test_restart_recovers_owner_and_closes_only_after_owner_finishes(self) -> None:
        herdr = FakeHerdr(self.herdr_state)
        herdr.set_draft(self.board_pane, "BOARD DRAFT: recovery")
        active = [{"number": 5, "title": "recover", "body": "", "labels": ["mgr:in-flight"], "state": "OPEN"}]
        first = self.run_cycle(active)
        self.assertEqual(first.returncode, 0, first.stderr)
        herdr = FakeHerdr(self.herdr_state)
        issue_agents = [row for row in herdr.list_agents() if row["name"] == "fixture-issue-5"]
        self.assertEqual(len(issue_agents), 1, first.stdout + first.stderr)
        issue_agent = issue_agents[0]
        herdr.set_draft(issue_agent["pane_id"], "ISSUE 5 DRAFT")

        second = self.run_cycle(active)
        self.assertEqual(second.returncode, 0, second.stderr)
        herdr = FakeHerdr(self.herdr_state)
        starts = [
            row for row in herdr.log
            if row["operation"] == "agent.start" and row["inputs"]["name"] == "fixture-issue-5"
        ]
        self.assertEqual(len(starts), 1)
        self.assert_only_fresh_handoff("fixture-issue-5")
        self.assertEqual(herdr.get_pane(issue_agent["pane_id"])["draft"], "ISSUE 5 DRAFT")
        self.assertEqual(herdr.get_pane(self.board_pane)["draft"], "BOARD DRAFT: recovery")

        finished = [{"number": 5, "title": "recover", "body": "", "labels": ["mgr:in-flight"], "state": "CLOSED"}]
        while_working = self.run_cycle(finished)
        self.assertEqual(while_working.returncode, 0, while_working.stderr)
        herdr = FakeHerdr(self.herdr_state)
        self.assertEqual(
            next(row for row in herdr.list_agents() if row["name"] == "fixture-issue-5")["agent_status"],
            "working",
        )
        self.assertFalse(any(row["operation"] == "tab.close" for row in herdr.log))

        malformed = json.loads(self.herdr_state.read_text())
        malformed["agents"]["fixture-issue-5"]["tab_id"] = ""
        self.herdr_state.write_text(json.dumps(malformed))
        incomplete_identity = self.run_cycle(finished)
        self.assertEqual(incomplete_identity.returncode, 0, incomplete_identity.stderr)
        self.assertFalse(any(
            row["operation"] == "tab.close"
            for row in FakeHerdr(self.herdr_state).log
        ))
        restored = json.loads(self.herdr_state.read_text())
        restored["agents"]["fixture-issue-5"]["tab_id"] = issue_agent["tab_id"]
        self.herdr_state.write_text(json.dumps(restored))

        herdr = FakeHerdr(self.herdr_state)
        herdr.set_status(issue_agent["pane_id"], agent_status="done")
        after_done = self.run_cycle(finished)
        self.assertEqual(after_done.returncode, 0, after_done.stderr)
        herdr = FakeHerdr(self.herdr_state)
        self.assertFalse(any(row["name"] == "fixture-issue-5" for row in herdr.list_agents()))
        closes = [row for row in herdr.log if row["operation"] == "tab.close"]
        self.assertEqual(len(closes), 1)
        self.assert_only_fresh_handoff("fixture-issue-5")
        self.assertEqual(herdr.get_pane(self.board_pane)["draft"], "BOARD DRAFT: recovery")
        self.assertIn("closed finished tab", after_done.stdout)

    def test_auto_mode_requires_loaded_config_and_timeout_never_reprompts_owner(self) -> None:
        config = json.loads(self.config.read_text())
        config.pop("agent_config")
        self.config.write_text(json.dumps(config))
        issue = [{"number": 7, "title": "route safely", "body": "", "labels": [], "state": "OPEN"}]
        rejected = self.run_cycle(issue)
        self.assertEqual(rejected.returncode, 2)
        self.assertIn("agent_config: required when any board uses auto mode", rejected.stderr)
        self.assertNotIn("mgr:in-flight", json.loads(self.gh_state.read_text())["issues"][0]["labels"])
        self.assertEqual(FakeHerdr(self.herdr_state).argv_audit, [])

        config["agent_config"] = str(self.agent_config)
        self.config.write_text(json.dumps(config))
        herdr = FakeHerdr(self.herdr_state)
        herdr.set_draft(self.board_pane, "BOARD DRAFT: timeout")
        herdr.queue_failure("agent.prompt", "timeout_after_success", times=1, after_commit=True)
        uncertain = self.run_cycle(issue)
        self.assertEqual(uncertain.returncode, 0, uncertain.stderr)
        state = json.loads(self.gh_state.read_text())
        self.assertIn("mgr:in-flight", state["issues"][0]["labels"])
        herdr = FakeHerdr(self.herdr_state)
        owner = next(row for row in herdr.list_agents() if row["name"] == "fixture-issue-7")
        self.assertEqual(owner["agent_status"], "working")
        self.assertFalse(any(
            row["operation"] == "tab.close" and row["inputs"]["tab_id"] == owner["tab_id"]
            for row in herdr.log
        ))
        self.assert_only_fresh_handoff("fixture-issue-7")

        herdr.set_status(owner["pane_id"], agent_status="idle")
        herdr.set_draft(owner["pane_id"], "ISSUE 7 DRAFT AFTER TIMEOUT")
        restarted = self.run_cycle(state["issues"])
        self.assertEqual(restarted.returncode, 0, restarted.stderr)
        herdr = FakeHerdr(self.herdr_state)
        retained = next(row for row in herdr.list_agents() if row["name"] == "fixture-issue-7")
        self.assertEqual(retained["tab_id"], owner["tab_id"])
        self.assertEqual(retained["agent_status"], "idle")
        self.assertEqual(
            herdr.get_pane(owner["pane_id"])["draft"],
            "ISSUE 7 DRAFT AFTER TIMEOUT",
        )
        self.assertEqual(herdr.get_pane(self.board_pane)["draft"], "BOARD DRAFT: timeout")
        self.assert_only_fresh_handoff("fixture-issue-7")

    def test_json_report_agent_is_rejected_before_external_calls(self) -> None:
        base = json.loads(self.config.read_text())
        for value in ("board-test", "", None):
            with self.subTest(report_agent=value):
                config = dict(base)
                config["report_agent"] = value
                self.config.write_text(json.dumps(config))
                result = self.run_cycle([])
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("report_agent", result.stderr)
                self.assertEqual(json.loads(self.gh_state.read_text())["log"], [])
                self.assertEqual(FakeHerdr(self.herdr_state).argv_audit, [])

    def test_positional_cli_requires_explicit_mode_and_rejects_old_report_forms(self) -> None:
        self.set_issues([])
        omitted_modes = [
            ["ws_main", "1"],
            ["ws_main", "1", "30"],
        ]
        for args in omitted_modes:
            with self.subTest(omitted_mode_args=args):
                result = self.run_watcher(args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("--mode supervised|auto", result.stderr)
                self.assertEqual(json.loads(self.gh_state.read_text())["log"], [])
                self.assertEqual(FakeHerdr(self.herdr_state).argv_audit, [])
                self.assertEqual(self.input_mutations(), [])

        old_forms = [
            ["ws_main", "1", "30", "board-test"],
            ["ws_main", "1", "30", "board-test", "auto"],
            ["ws_main", "1", "30", "auto"],
            ["ws_main", "1", "30", "supervised"],
            ["ws_main", "1", "30", "auto", "supervised"],
        ]
        for args in old_forms:
            with self.subTest(args=args):
                result = self.run_watcher(args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual(json.loads(self.gh_state.read_text())["log"], [])
                self.assertEqual(FakeHerdr(self.herdr_state).argv_audit, [])

        for mode in ("supervised", "auto"):
            with self.subTest(explicit_mode=mode):
                result = self.run_watcher(
                    ["ws_main", "1", "30", "--mode", mode],
                    extra_env={"WORK_THE_BOARD_AGENT_CONFIG": str(self.agent_config)},
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.input_mutations(), [])

    def test_collaborative_idle_owner_and_board_are_never_mutated_across_restarts(self) -> None:
        config = json.loads(self.config.read_text())
        config["boards"][0]["concurrency"] = 2
        self.config.write_text(json.dumps(config))
        herdr = FakeHerdr(self.herdr_state)
        herdr.set_draft(self.board_pane, "BOARD COLLABORATION DRAFT")
        existing = self.seed_issue_owner(
            10,
            status="idle",
            draft="ISSUE 10 COLLABORATION DRAFT",
        )
        issues = [
            {"number": 10, "title": "collaborative", "body": "", "labels": ["mgr:in-flight"], "state": "OPEN"},
            {"number": 11, "title": "fresh", "body": "", "labels": [], "state": "OPEN"},
            {"number": 12, "title": "held", "body": "", "labels": ["mgr:hold"], "state": "OPEN"},
            {"number": 13, "title": "research", "body": "", "labels": ["research"], "state": "OPEN"},
            {"number": 14, "title": "dependent", "body": "Blocked by: #10", "labels": [], "state": "OPEN"},
        ]

        first = self.run_cycle(issues)
        self.assertEqual(first.returncode, 0, first.stderr)
        state = json.loads(self.gh_state.read_text())
        self.assertEqual(
            [row["number"] for row in state["issues"] if "mgr:in-flight" in row["labels"]],
            [10, 11],
        )
        herdr = FakeHerdr(self.herdr_state)
        fresh = next(row for row in herdr.list_agents() if row["name"] == "fixture-issue-11")
        herdr.set_draft(fresh["pane_id"], "ISSUE 11 DRAFT AFTER HANDOFF")
        herdr.set_status(existing["pane_id"], agent_status="working")

        second = self.run_cycle(state["issues"])
        self.assertEqual(second.returncode, 0, second.stderr)
        state = json.loads(self.gh_state.read_text())
        herdr = FakeHerdr(self.herdr_state)
        herdr.set_status(existing["pane_id"], agent_status="idle")
        third = self.run_cycle(state["issues"])
        self.assertEqual(third.returncode, 0, third.stderr)

        herdr = FakeHerdr(self.herdr_state)
        retained = next(row for row in herdr.list_agents() if row["name"] == "fixture-issue-10")
        fresh_retained = next(row for row in herdr.list_agents() if row["name"] == "fixture-issue-11")
        self.assertEqual(retained["tab_id"], existing["tab_id"])
        self.assertEqual(retained["session_id"], existing["session_id"])
        self.assertEqual(retained["agent_status"], "idle")
        self.assertEqual(fresh_retained["tab_id"], fresh["tab_id"])
        self.assertEqual(herdr.get_pane(self.board_pane)["draft"], "BOARD COLLABORATION DRAFT")
        self.assertEqual(
            herdr.get_pane(existing["pane_id"])["draft"],
            "ISSUE 10 COLLABORATION DRAFT",
        )
        self.assertEqual(
            herdr.get_pane(fresh["pane_id"])["draft"],
            "ISSUE 11 DRAFT AFTER HANDOFF",
        )
        starts = [
            row
            for row in herdr.log
            if row["operation"] == "agent.start"
            and row["inputs"]["name"] == "fixture-issue-11"
        ]
        self.assertEqual(len(starts), 1)
        self.assert_only_fresh_handoff("fixture-issue-11")
        self.assertEqual(self.prompts_for("board-test"), [])
        self.assertEqual(self.prompts_for("fixture-issue-10"), [])

    def test_present_owner_statuses_and_selection_gates_remain_authoritative(self) -> None:
        statuses = ("working", "blocked", "idle", "done", "failed", "dead", "unknown")
        config = json.loads(self.config.read_text())
        config["boards"][0]["concurrency"] = len(statuses) + 1
        self.config.write_text(json.dumps(config))
        herdr = FakeHerdr(self.herdr_state)
        herdr.set_draft(self.board_pane, "BOARD DRAFT: status matrix")
        owners: dict[int, dict[str, object]] = {}
        issues: list[dict[str, object]] = []
        for offset, status in enumerate(statuses):
            number = 20 + offset
            owners[number] = self.seed_issue_owner(
                number,
                status=status,
                draft=f"ISSUE {number} DRAFT: {status}",
            )
            issues.append({
                "number": number,
                "title": f"{status} owner",
                "body": "",
                "labels": ["mgr:in-flight"],
                "state": "OPEN",
            })
        issues.extend([
            {"number": 90, "title": "held approval", "body": "", "labels": ["mgr:hold", "mgr:manual-approve"], "state": "OPEN"},
            {"number": 91, "title": "research", "body": "", "labels": ["research"], "state": "OPEN"},
            {"number": 92, "title": "dependent", "body": "Blocked by: #91", "labels": [], "state": "OPEN"},
            {"number": 99, "title": "approved", "body": "", "labels": ["priority:high", "mgr:manual-approve"], "state": "OPEN"},
        ])

        result = self.run_cycle(issues)
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(self.gh_state.read_text())
        claimed = {
            row["number"]
            for row in state["issues"]
            if "mgr:in-flight" in row["labels"]
        }
        self.assertEqual(claimed, {*owners, 99})
        herdr = FakeHerdr(self.herdr_state)
        for number, status in zip(owners, statuses):
            with self.subTest(status=status):
                owner = next(
                    row
                    for row in herdr.list_agents()
                    if row["name"] == f"fixture-issue-{number}"
                )
                self.assertEqual(owner["tab_id"], owners[number]["tab_id"])
                self.assertEqual(owner["agent_status"], status)
                self.assertEqual(
                    herdr.get_pane(owner["pane_id"])["draft"],
                    f"ISSUE {number} DRAFT: {status}",
                )
                self.assertEqual(self.prompts_for(owner["name"]), [])
        self.assertEqual(herdr.get_pane(self.board_pane)["draft"], "BOARD DRAFT: status matrix")
        self.assert_only_fresh_handoff("fixture-issue-99")

    def test_orphan_cleanup_rejects_incomplete_runtime_identity(self) -> None:
        herdr = FakeHerdr(self.herdr_state)
        herdr.set_draft(self.board_pane, "BOARD DRAFT: orphan cleanup")
        orphan_path = self.root / "issue-9-orphan"
        herdr.create_workspace(str(orphan_path), workspace_id="ws_orphan", linked_worktree=True)
        raw = json.loads(self.herdr_state.read_text())
        raw["workspaces"]["ws_orphan"]["worktree"]["repo_root"] = str(self.repo.resolve())
        raw["agents"]["malformed"] = {}
        self.herdr_state.write_text(json.dumps(raw))

        deferred = self.run_cycle([])
        self.assertEqual(deferred.returncode, 0, deferred.stderr)
        self.assertIn("ws_orphan", json.loads(self.herdr_state.read_text())["workspaces"])

        raw = json.loads(self.herdr_state.read_text())
        raw["agents"].pop("malformed")
        self.herdr_state.write_text(json.dumps(raw))
        cleaned = self.run_cycle([])
        self.assertEqual(cleaned.returncode, 0, cleaned.stderr)
        self.assertNotIn("ws_orphan", json.loads(self.herdr_state.read_text())["workspaces"])
        herdr = FakeHerdr(self.herdr_state)
        self.assertEqual(self.input_mutations(), [])
        self.assertEqual(herdr.get_pane(self.board_pane)["draft"], "BOARD DRAFT: orphan cleanup")

    def test_capacity_count_exceeds_cli_default_page_without_overlaunch(self) -> None:
        config = json.loads(self.config.read_text())
        config["boards"][0]["concurrency"] = 31
        self.config.write_text(json.dumps(config))
        herdr = FakeHerdr(self.herdr_state)
        herdr.set_draft(self.board_pane, "BOARD DRAFT: capacity")
        issues = []
        for number in range(1, 32):
            issues.append({
                "number": number,
                "title": f"active {number}",
                "body": "",
                "labels": ["mgr:in-flight"],
                "state": "OPEN",
            })
            created = herdr.create_tab("ws_main", str(self.repo), label=f"fixture/issue-{number}: active")
            pane = created["root_pane"]["pane_id"]
            herdr.start_agent(f"fixture-issue-{number}", pane)
            herdr.set_status(pane, agent_status="working")
            herdr.set_draft(pane, f"ISSUE {number} DRAFT")
        issues.append({"number": 99, "title": "must wait", "body": "", "labels": [], "state": "OPEN"})

        result = self.run_cycle(issues)
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(self.gh_state.read_text())
        waiting = next(row for row in state["issues"] if row["number"] == 99)
        self.assertNotIn("mgr:in-flight", waiting["labels"])
        self.assertFalse(any(
            row["operation"] == "agent.start" and row["inputs"]["name"] == "fixture-issue-99"
            for row in FakeHerdr(self.herdr_state).log
        ))
        herdr = FakeHerdr(self.herdr_state)
        self.assertEqual(self.input_mutations(), [])
        self.assertEqual(herdr.get_pane(self.board_pane)["draft"], "BOARD DRAFT: capacity")
        for number in range(1, 32):
            owner = next(
                row
                for row in herdr.list_agents()
                if row["name"] == f"fixture-issue-{number}"
            )
            self.assertEqual(herdr.get_pane(owner["pane_id"])["draft"], f"ISSUE {number} DRAFT")
        self.assertIn("in-flight=31 free=0", result.stdout)


if __name__ == "__main__":
    unittest.main()
