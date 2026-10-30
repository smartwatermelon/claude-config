"""Privacy-preserving event normalization and bounded local journal.

This is an observation adapter, not an authorization boundary. Only trusted
collectors may supply source/policy metadata. Agent-supplied events remain
untrusted until a separate controller authenticates their transport.
"""

import argparse
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import stat
import sys
from collections import Counter
from datetime import datetime, timezone

SOURCES = frozenset(
    ("auto_mode", "permission_rule", "hook", "sandbox", "harness", "os",
     "wrapper", "git_gate", "human", "tool", "unknown")
)
OUTCOMES = frozenset(("allowed", "succeeded", "denied", "failed", "interrupted"))
POLICIES = frozenset(
    ("unknown", "auto_mode", "managed_floor", "denial_latch", "review_gate",
     "merge_approval", "secret_protection", "worktree_scope", "collector")
)
OPERATIONS = frozenset(
    ("shell", "file_read", "file_write", "web", "mcp", "agent", "unknown")
)
TARGETS = frozenset(("workspace", "policy", "credential", "remote", "unknown"))
MAX_INPUT = 1024 * 1024


def fingerprint(key, value):
    """Keyed rather than plain hashing: low-entropy commands resist guessing."""
    data = json.dumps(value, sort_keys=True, separators=(",", ":"))
    return hmac.new(key, data.encode(), hashlib.sha256).hexdigest()


def operation(tool):
    if tool in ("Bash", "PowerShell", "Monitor"):
        return "shell"
    if tool in ("Read", "Grep", "Glob"):
        return "file_read"
    if tool in ("Write", "Edit", "NotebookEdit"):
        return "file_write"
    if tool in ("WebFetch", "WebSearch"):
        return "web"
    if isinstance(tool, str) and tool.startswith("mcp__"):
        return "mcp"
    if tool in ("Agent", "Task"):
        return "agent"
    return "unknown"


def normalize(raw, key, *, source=None, policy="unknown", outcome=None,
              target="unknown", environment="production", now=None):
    """Persist an allowlist of fields, never commands, paths, reasons or output.

    PermissionDenied covers auto mode ONLY. An arbitrary failed tool result is
    not evidence of an authorization denial, even if its text says 'denied'.
    source/outcome overrides are for trusted adapters (not tool_input fields).
    """
    if not isinstance(raw, dict) or not isinstance(key, bytes) or len(key) < 32:
        raise ValueError("invalid event or fingerprint key")
    if environment not in ("production", "test"):
        raise ValueError("invalid environment")
    event = raw.get("hook_event_name")
    if source is None and outcome is None:
        source, outcome = {
            "PermissionDenied": ("auto_mode", "denied"),
            "PostToolUse": ("tool", "succeeded"),
            "PostToolUseFailure": ("unknown", "failed"),
        }.get(event, ("unknown", "failed"))
        if event == "PermissionDenied":
            policy = "auto_mode"
        if event == "PostToolUseFailure" and raw.get("is_interrupt") is True:
            outcome = "interrupted"
    if source not in SOURCES or outcome not in OUTCOMES or policy not in POLICIES:
        raise ValueError("invalid trusted event metadata")
    if target not in TARGETS:
        raise ValueError("invalid target class")
    tool = raw.get("tool_name")
    # HMAC all identifiers too: repository content can inject arbitrary strings
    # into session/tool IDs. No raw free-text field crosses the privacy boundary.
    ids = {}
    for name in ("session_id", "tool_use_id", "parent_session_id"):
        value = raw.get(name)
        ids[name] = fingerprint(key, [name, value]) if value else None
    timestamp = now or datetime.now(timezone.utc).isoformat()
    return {
        "schema_version": 1, "timestamp": timestamp,
        "environment": environment, "source": source, "policy_id": policy,
        "operation_class": operation(tool), "target_class": target,
        "outcome": outcome, "retry_status": "unknown",
        "workflow_interruption": "unknown", "assessment": "unreviewed",
        "fingerprint": fingerprint(key, [tool, raw.get("tool_input", {})]),
        **ids,
    }


def private_directory(path):
    """Reject symlink ancestors and nonprivate final directory.

    The caller must place this below a controller-owned, non-agent-writable
    parent in production. These checks do not defeat a hostile directory owner.
    """
    path = Path(os.path.abspath(path))
    for part in (path, *path.parents):
        if part.is_symlink():
            raise ValueError("journal path contains a symlink")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.stat()
    if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError("journal directory must be owned by collector, mode 0700")
    return path


def private_open(path, flags):
    fd = os.open(path, flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    info = os.fstat(fd)
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
        os.close(fd)
        raise ValueError("journal file must be private, regular and unlinked")
    return fd


class Journal:
    """Serialized appends; one bounded backup; tests use their own directory."""

    def __init__(self, path, max_bytes=2 * 1024 * 1024):
        self.path = private_directory(path)
        self.max_bytes = max_bytes

    def record(self, raw, **metadata):
        lock = private_open(self.path / "journal.lock", os.O_RDWR | os.O_CREAT)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX)
            key_path = self.path / "fingerprint-key"
            try:
                key_fd = private_open(key_path, os.O_RDONLY)
            except FileNotFoundError:
                key_fd = private_open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
                try:
                    os.write(key_fd, secrets.token_bytes(32))
                    os.fsync(key_fd)
                finally:
                    os.close(key_fd)
                key_fd = private_open(key_path, os.O_RDONLY)
            try:
                key = os.read(key_fd, 33)
            finally:
                os.close(key_fd)
            if len(key) != 32:
                raise ValueError("invalid journal key")
            result = normalize(raw, key, **metadata)
            data = (json.dumps(result, sort_keys=True) + "\n").encode()
            path = self.path / "events.jsonl"
            fd = private_open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT)
            try:
                if os.fstat(fd).st_size + len(data) > self.max_bytes:
                    os.close(fd)
                    fd = None
                    backup = self.path / "events.previous.jsonl"
                    if backup.is_symlink():
                        raise ValueError("journal backup is a symlink")
                    os.replace(path, backup)
                    fd = private_open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT)
                with os.fdopen(fd, "ab", closefd=False) as stream:
                    stream.write(data)
                    stream.flush()
                    os.fsync(fd)
            finally:
                if fd is not None:
                    os.close(fd)
            return result
        finally:
            os.close(lock)


def report(events):
    """Count observed results; never equate denials with workflow interruption."""
    counts = Counter()
    seen = set()
    duplicates = tests = uncorrelated = 0
    for event in events:
        if event.get("schema_version") != 1:
            raise ValueError("unsupported event schema")
        if (event.get("source") not in SOURCES
                or event.get("outcome") not in OUTCOMES
                or event.get("policy_id") not in POLICIES
                or event.get("environment") not in ("test", "production")):
            raise ValueError("invalid event schema")
        if event["environment"] == "test":
            tests += 1
            continue
        correlation = event.get("tool_use_id")
        if correlation:
            identity = (event.get("session_id"), correlation,
                        event["source"], event["policy_id"], event["outcome"])
            if identity in seen:
                duplicates += 1
                continue
            seen.add(identity)
        else:
            uncorrelated += 1
        counts[(event["source"], event["outcome"])] += 1
    return {
        "observations": [dict(source=s, outcome=o, count=n)
                         for (s, o), n in sorted(counts.items())],
        "duplicates_excluded": duplicates, "test_events_excluded": tests,
        "uncorrelated_events": uncorrelated,
        "workflow_interruptions": "unknown",
        "false_positive_denials": "unknown",
        "coverage": "observed collectors only; not all authorization layers",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    collect = sub.add_parser("collect")
    collect.add_argument("--directory", required=True)
    collect.add_argument("--environment", choices=("production", "test"),
                         default="production")
    summary = sub.add_parser("report")
    summary.add_argument("files", nargs="+")
    args = parser.parse_args()
    try:
        if args.command == "collect":
            payload = sys.stdin.buffer.read(MAX_INPUT + 1)
            if len(payload) > MAX_INPUT:
                raise ValueError("event input too large")
            raw = json.loads(payload)
            Journal(args.directory).record(raw, environment=args.environment)
            # Never request a retry or change authorization in a logging hook.
            if raw.get("hook_event_name") == "PermissionDenied":
                print(json.dumps({"hookSpecificOutput": {
                    "hookEventName": "PermissionDenied", "retry": False}}))
        else:
            rows = []
            for name in args.files:
                with open(name, encoding="utf-8") as stream:
                    rows.extend(json.loads(line) for line in stream if line.strip())
            print(json.dumps(report(rows), sort_keys=True, indent=2))
    except (OSError, ValueError, KeyError, TypeError):
        # Do not echo malformed payloads, paths, raw exception messages or secrets.
        print("authorization collector failed; coverage incomplete", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
