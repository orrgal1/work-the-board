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

if args[:2] == ["issue", "list"]:
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
            "report_agent": "board-test",
            "agent_config": str(self.agent_config),
            "boards": [{
                "name": "fixture", "kind": "repo", "repo": REPO,
                "path": str(self.repo), "workspace": "ws_main",
                "concurrency": 1, "mode": "auto"
            }]
        }))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_cycle(self, issues: list[dict[str, object]]) -> subprocess.CompletedProcess[str]:
        prior = json.loads(self.gh_state.read_text()) if self.gh_state.exists() else {}
        self.gh_state.write_text(json.dumps({"repo": REPO, "issues": issues, "log": prior.get("log", [])}))
        env = os.environ.copy()
        env.update({
            "PATH": f"{self.bin}:{env['PATH']}",
            "FAKE_GH_STATE": str(self.gh_state),
            "FAKE_HERDR_STATE": str(self.herdr_state),
            "WORK_THE_BOARD_ONCE": "1",
        })
        return subprocess.run(
            ["bash", str(WATCHER), "--config", str(self.config)],
            cwd=self.repo, env=env, text=True, capture_output=True, timeout=20,
        )

    def test_real_entrypoint_dispatches_only_ready_issue_and_preserves_gates(self) -> None:
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
        board_prompts = [row for row in prompts if row["inputs"]["name"] == "board-test"]
        self.assertEqual(len(issue_prompts), 1)
        self.assertTrue(board_prompts)
        self.assertIn("mgr:manual-approve", issue_prompts[0]["inputs"]["prompt"])
        self.assertIn("in-flight=0 free=1 ready=2 launching=1", result.stdout)

    def test_restart_recovers_owner_and_closes_only_after_owner_finishes(self) -> None:
        active = [{"number": 5, "title": "recover", "body": "", "labels": ["mgr:in-flight"], "state": "OPEN"}]
        first = self.run_cycle(active)
        self.assertEqual(first.returncode, 0, first.stderr)
        herdr = FakeHerdr(self.herdr_state)
        issue_agents = [row for row in herdr.list_agents() if row["name"] == "fixture-issue-5"]
        self.assertEqual(len(issue_agents), 1, first.stdout + first.stderr)

        second = self.run_cycle(active)
        self.assertEqual(second.returncode, 0, second.stderr)
        herdr = FakeHerdr(self.herdr_state)
        starts = [
            row for row in herdr.log
            if row["operation"] == "agent.start" and row["inputs"]["name"] == "fixture-issue-5"
        ]
        self.assertEqual(len(starts), 1)

        finished = [{"number": 5, "title": "recover", "body": "", "labels": ["mgr:in-flight"], "state": "CLOSED"}]
        while_working = self.run_cycle(finished)
        self.assertEqual(while_working.returncode, 0, while_working.stderr)
        herdr = FakeHerdr(self.herdr_state)
        issue_agent = next(row for row in herdr.list_agents() if row["name"] == "fixture-issue-5")
        self.assertEqual(issue_agent["agent_status"], "working")
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
        malformed["agents"]["fixture-issue-5"]["tab_id"] = issue_agent["tab_id"]
        self.herdr_state.write_text(json.dumps(malformed))


        herdr.set_status(issue_agent["pane_id"], agent_status="done")
        after_done = self.run_cycle(finished)
        self.assertEqual(after_done.returncode, 0, after_done.stderr)
        herdr = FakeHerdr(self.herdr_state)
        self.assertFalse(any(row["name"] == "fixture-issue-5" for row in herdr.list_agents()))
        closes = [row for row in herdr.log if row["operation"] == "tab.close"]
        self.assertEqual(len(closes), 1)
        self.assertIn("closed finished tab", after_done.stdout)

    def test_auto_mode_requires_loaded_config_and_uncertain_prompt_retains_owner(self) -> None:
        config = json.loads(self.config.read_text())
        config.pop("agent_config")
        self.config.write_text(json.dumps(config))
        issue = [{"number": 7, "title": "route safely", "body": "", "labels": [], "state": "OPEN"}]
        rejected = self.run_cycle(issue)
        self.assertEqual(rejected.returncode, 2)
        self.assertIn("agent_config: required when any board uses auto mode", rejected.stderr)
        self.assertNotIn("mgr:in-flight", json.loads(self.gh_state.read_text())["issues"][0]["labels"])

        config["agent_config"] = str(self.agent_config)
        self.config.write_text(json.dumps(config))
        herdr = FakeHerdr(self.herdr_state)
        herdr.queue_failure("agent.prompt", "timeout_after_success", times=2, after_commit=True)
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

    def test_empty_report_recipient_does_not_consume_agent_config(self) -> None:
        config = json.loads(self.config.read_text())
        config.pop("report_agent")
        self.config.write_text(json.dumps(config))
        issue = [{"number": 8, "title": "no reporter", "body": "", "labels": [], "state": "OPEN"}]
        result = self.run_cycle(issue)
        self.assertEqual(result.returncode, 0, result.stderr)
        herdr = FakeHerdr(self.herdr_state)
        start = next(
            row for row in herdr.log
            if row["operation"] == "agent.start" and row["inputs"]["name"] == "fixture-issue-8"
        )
        self.assertEqual(start["inputs"]["omp_args"][-2:], ["--config", str(self.agent_config)])
        self.assertFalse(any(
            row["operation"] == "agent.prompt" and row["inputs"]["name"] == str(self.agent_config)
            for row in herdr.log
        ))

    def test_orphan_cleanup_rejects_incomplete_runtime_identity(self) -> None:
        herdr = FakeHerdr(self.herdr_state)
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

    def test_capacity_count_exceeds_cli_default_page_without_overlaunch(self) -> None:
        config = json.loads(self.config.read_text())
        config["boards"][0]["concurrency"] = 31
        self.config.write_text(json.dumps(config))
        herdr = FakeHerdr(self.herdr_state)
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
            herdr.prompt_agent(f"fixture-issue-{number}", "continue")
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
        self.assertIn("in-flight=31 free=0", result.stdout)


if __name__ == "__main__":
    unittest.main()
