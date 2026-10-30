import copy
import json
import multiprocessing
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from security.events import Journal, normalize, report  # noqa: E402
from security.policy import TEMPLATE, validate, validate_install  # noqa: E402
from security.workflow import Workflow  # noqa: E402

KEY = b"synthetic-test-fingerprint-key-32bytes"


def write_event(directory, number):
    Journal(directory).record({"hook_event_name": "PostToolUse",
                               "tool_use_id": str(number)})


class EventsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name) / "journal"

    def test_secret_fields_never_persist(self):
        secret = "synthetic-secret-that-must-not-persist"
        event = {"hook_event_name": "PermissionDenied", "session_id": secret,
                 "tool_use_id": secret, "parent_session_id": secret,
                 "tool_name": "mcp__" + secret, "cwd": secret, "reason": secret,
                 "transcript_path": secret, "tool_input": {"command": secret},
                 "tool_response": secret, "unrecognized": secret}
        Journal(self.directory).record(event)
        for path in self.directory.iterdir():
            self.assertNotIn(secret.encode(), path.read_bytes())
        row = json.loads((self.directory / "events.jsonl").read_text())
        self.assertEqual(row["operation_class"], "mcp")
        self.assertEqual(row["source"], "auto_mode")

    def test_spoofed_metadata_is_ignored(self):
        row = normalize({"hook_event_name": "PostToolUseFailure",
                         "source": "human", "outcome": "succeeded",
                         "environment": "test", "error": "Permission denied"}, KEY)
        self.assertEqual((row["source"], row["outcome"]), ("unknown", "failed"))
        self.assertEqual(row["environment"], "production")

    def test_interruption_is_not_denial(self):
        row = normalize({"hook_event_name": "PostToolUseFailure",
                         "is_interrupt": True}, KEY)
        self.assertEqual(row["outcome"], "interrupted")

    def test_fingerprint_is_keyed_and_stable(self):
        raw = {"tool_name": "Bash", "tool_input": {"command": "git status"}}
        self.assertEqual(normalize(raw, KEY)["fingerprint"],
                         normalize(raw, KEY)["fingerprint"])
        self.assertNotEqual(normalize(raw, KEY)["fingerprint"],
                            normalize(raw, b"x" * 32)["fingerprint"])

    def test_invalid_free_text_metadata_rejected(self):
        for metadata in ({"source": "raw secret", "outcome": "denied"},
                         {"policy": "raw secret"}, {"target": "raw secret"},
                         {"environment": "raw secret"}):
            with self.subTest(metadata=metadata), self.assertRaises(ValueError):
                normalize({}, KEY, **metadata)

    def test_report_excludes_tests_and_duplicates_not_distinct_outcomes(self):
        raw = {"hook_event_name": "PermissionDenied", "session_id": "s",
               "tool_use_id": "one"}
        denied = normalize(raw, KEY)
        allowed = normalize(raw, KEY, source="auto_mode", outcome="succeeded")
        fixture = normalize(raw, KEY, environment="test")
        result = report([denied, denied, allowed, fixture])
        self.assertEqual(result["duplicates_excluded"], 1)
        self.assertEqual(result["test_events_excluded"], 1)
        self.assertEqual(sum(r["count"] for r in result["observations"]), 2)
        self.assertEqual(result["workflow_interruptions"], "unknown")
        self.assertEqual(result["false_positive_denials"], "unknown")

    def test_uncorrelated_observations_not_silently_deduplicated(self):
        row = normalize({}, KEY)
        result = report([row, row])
        self.assertEqual(result["uncorrelated_events"], 2)
        self.assertEqual(result["observations"][0]["count"], 2)

    def test_unknown_schema_rejected(self):
        with self.assertRaises(ValueError):
            report([{"schema_version": 2}])

    def test_report_rejects_free_text_in_enum_fields(self):
        row = normalize({}, KEY)
        row["source"] = "synthetic-secret"
        with self.assertRaises(ValueError):
            report([row])

    def test_journal_files_private_and_rotation_bounded(self):
        journal = Journal(self.directory, max_bytes=1000)
        for n in range(5):
            journal.record({"tool_use_id": str(n)})
        files = list(self.directory.iterdir())
        self.assertIn("events.previous.jsonl", [p.name for p in files])
        self.assertEqual(len(files), 4)
        self.assertTrue(all(p.stat().st_mode & 0o777 == 0o600 for p in files))
        for name in ("events.jsonl", "events.previous.jsonl"):
            for line in (self.directory / name).read_text().splitlines():
                json.loads(line)

    def test_concurrent_writes_remain_valid(self):
        jobs = [multiprocessing.Process(target=write_event,
                                        args=(str(self.directory), n))
                for n in range(8)]
        for job in jobs:
            job.start()
        for job in jobs:
            job.join(10)
            self.assertEqual(job.exitcode, 0)
        lines = (self.directory / "events.jsonl").read_text().splitlines()
        self.assertEqual(len(lines), 8)
        self.assertEqual(len({json.loads(line)["tool_use_id"] for line in lines}), 8)

    def test_symlink_directory_and_file_refused(self):
        self.directory.symlink_to(self.temp.name, target_is_directory=True)
        with self.assertRaises(ValueError):
            Journal(self.directory)
        self.directory.unlink()
        journal = Journal(self.directory)
        target = Path(self.temp.name) / "untouched"
        target.write_text("untouched")
        (self.directory / "events.jsonl").symlink_to(target)
        with self.assertRaises((OSError, ValueError)):
            journal.record({})
        self.assertEqual(target.read_text(), "untouched")

    def test_world_readable_directory_and_hardlink_refused(self):
        self.directory.mkdir(mode=0o755)
        with self.assertRaises(ValueError):
            Journal(self.directory)
        self.directory.chmod(0o700)
        journal = Journal(self.directory)
        target = Path(self.temp.name) / "shared-file"
        target.write_text("untouched")
        target.chmod(0o600)
        os.link(target, self.directory / "events.jsonl")
        with self.assertRaises(ValueError):
            journal.record({})
        self.assertEqual(target.read_text(), "untouched")

    def test_collector_never_requests_retry(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / "security/events.py"), "collect",
             "--directory", str(self.directory), "--environment", "test"],
            input=json.dumps({"hook_event_name": "PermissionDenied"}),
            text=True, capture_output=True, check=True)
        self.assertIs(json.loads(result.stdout)["hookSpecificOutput"]["retry"], False)

    def test_malformed_input_not_echoed(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / "security/events.py"), "collect",
             "--directory", str(self.directory)],
            input="synthetic-secret", text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("synthetic-secret", result.stdout + result.stderr)


class WorkflowTest(unittest.TestCase):
    def setUp(self):
        self.flow = Workflow("parent")
        self.flow.register_child("parent", "child")

    def test_denial_in_child_freezes_parent_and_siblings(self):
        self.flow.register_child("parent", "sibling")
        notice = self.flow.deny("child", "denial-1")
        self.assertEqual(notice["notify"], "parent")
        for member in self.flow.members:
            self.assertFalse(self.flow.may_execute(member))
        with self.assertRaises(ValueError):
            self.flow.finish("completed", ["test-pass"])
        self.assertEqual(self.flow.finish("partial")["status"], "blocked")

    def test_all_denials_must_be_reported_and_resolved(self):
        self.flow.deny("parent", "one")
        self.flow.deny("child", "two")
        with self.assertRaises(ValueError):
            self.flow.resolve_by_controller(["one"])
        self.flow.acknowledge("one")
        self.flow.resolve_by_controller(["one"])
        self.assertFalse(self.flow.may_execute("parent"))
        self.flow.acknowledge("two")
        self.flow.resolve_by_controller(["two"])
        self.assertTrue(self.flow.may_execute("parent"))

    def test_claimed_success_needs_controller_evidence(self):
        with self.assertRaises(ValueError):
            self.flow.finish("completed")
        with self.assertRaises(ValueError):
            self.flow.finish("completed", ["claimed-pass"])
        self.flow.verify_by_controller("test-pass")
        self.assertEqual(self.flow.finish("completed", ["test-pass"])["status"],
                         "completed")

    def test_denial_invalidates_previous_completion_and_evidence(self):
        self.flow.verify_by_controller("old-pass")
        self.flow.finish("completed", ["old-pass"])
        self.flow.deny("child", "one")
        self.assertFalse(self.flow.completed)
        self.flow.acknowledge("one")
        self.flow.resolve_by_controller(["one"])
        with self.assertRaises(ValueError):
            self.flow.finish("completed", ["old-pass"])

    def test_unknown_session_and_parent_refused(self):
        self.assertFalse(self.flow.may_execute("unknown"))
        with self.assertRaises(ValueError):
            self.flow.deny("unknown", "one")
        with self.assertRaises(ValueError):
            self.flow.register_child("unknown", "other")

    def test_partial_status_cannot_retain_completed_flag(self):
        self.flow.verify_by_controller("pass")
        self.flow.finish("completed", ["pass"])
        self.flow.finish("partial")
        self.assertFalse(self.flow.completed)


class PolicyTest(unittest.TestCase):
    def setUp(self):
        self.policy = json.loads(TEMPLATE.read_text())

    def test_guest_floor_valid(self):
        validate(self.policy)

    def test_every_floor_key_required(self):
        def remove_each(node, path=()):
            for key, value in node.items():
                changed = copy.deepcopy(self.policy)
                parent = changed
                for item in path:
                    parent = parent[item]
                del parent[key]
                with self.subTest(path=path + (key,)), self.assertRaises(ValueError):
                    validate(changed)
                if isinstance(value, dict):
                    remove_each(value, path + (key,))
        remove_each(self.policy)

    def test_unreviewed_exclusion_and_boolean_coercion_refused(self):
        self.policy["sandbox"]["excludedCommands"] = ["python3"]
        with self.assertRaises(ValueError):
            validate(self.policy)
        self.policy = json.loads(TEMPLATE.read_text())
        self.policy["sandbox"]["enabled"] = 1
        with self.assertRaises(ValueError):
            validate(self.policy)

    def test_installed_policy_symlink_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            link = Path(temp) / "policy.json"
            link.symlink_to(TEMPLATE)
            with self.assertRaises(ValueError):
                validate_install(link)

    def test_legacy_installer_excludes_staged_security(self):
        # Extract the real, side-effect-free exclusion function, not a copy.
        script = (ROOT / "install.sh").read_text()
        function = script.split("_is_excluded() {", 1)[1].split(
            "\n_is_submodule_path()", 1)[0]
        result = subprocess.run(
            ["bash", "-c", "_is_excluded() {" + function
             + '\n_is_excluded "security/managed-settings.guest.json"'],
            capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
