"""Bounded fake commands prove the wrapper's failure and private cleanup paths, not Docker."""

import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import stat
import sqlite3
import fcntl
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[1] / "android-sync-ci.py"
spec = importlib.util.spec_from_file_location("android_sync_ci", SCRIPT)
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class CommandTests(unittest.TestCase):
    def test_resolved_absolute_argv_preserves_literal_shell_characters(self):
        arguments = ["literal; value", "$HOME", "`no command`", "a\nb"]
        output = smoke.run_command([sys.executable, "-c", "import json, sys; print(json.dumps(sys.argv[1:]))", *arguments], capture=True)
        self.assertEqual(json.loads(output), arguments)
        self.assertTrue(Path(smoke.executable(sys.executable)).is_absolute())

    def test_stderr_larger_than_pipe_capacity_is_discarded(self):
        output = smoke.run_command([sys.executable, "-c", "import sys; sys.stderr.write('private error' * 20000); print('ok')"], timeout=2, capture=True)
        self.assertEqual(output, b"ok\n")

    def test_failures_never_include_tool_output_or_input(self):
        for program in ("print('PRIVATE BODY'); raise SystemExit(3)", "import sys; sys.stderr.write('PRIVATE BODY'); raise SystemExit(3)"):
            with self.assertRaises(smoke.SmokeFailure) as failure:
                smoke.run_command([sys.executable, "-c", program], capture=True)
            self.assertEqual(str(failure.exception), "command failed")
        with self.assertRaises(smoke.SmokeFailure):
            smoke.run_command(["/no-such-android-sync-command"])

    def test_captured_stdout_is_capped(self):
        with self.assertRaisesRegex(smoke.SmokeFailure, "output exceeded limit"):
            smoke.run_command([sys.executable, "-c", "print('X' * 100000)"], timeout=2, capture=True)

    def test_cleanup_errors_preserve_the_command_failure_and_close_stdout(self):
        for cleanup in ("kill", "wait"):
            with self.subTest(cleanup=cleanup):
                process = Mock(pid=12345, stdout=Mock())
                process.wait.side_effect = [subprocess.TimeoutExpired("private command", 1),
                    subprocess.TimeoutExpired("private command", 5) if cleanup == "wait" else 0]
                stderr = io.StringIO()
                with patch.object(smoke.subprocess, "Popen", return_value=process), \
                        patch.object(smoke.os, "killpg", side_effect=PermissionError("PRIVATE") if cleanup == "kill" else None), \
                        redirect_stderr(stderr):
                    with self.assertRaisesRegex(smoke.SmokeFailure, "^command deadline exceeded$"):
                        smoke.run_command([sys.executable])
                self.assertEqual(process.wait.call_count, 2)
                process.stdout.close.assert_called_once_with()
                self.assertIn("command cleanup failed", stderr.getvalue())
                self.assertNotIn("PRIVATE", stderr.getvalue())

    def test_cleanup_errors_fail_an_otherwise_successful_command(self):
        process = Mock(pid=12345, stdout=None)
        process.wait.return_value = 0
        with patch.object(smoke.subprocess, "Popen", return_value=process), \
                patch.object(smoke.os, "killpg", side_effect=PermissionError("PRIVATE")):
            with self.assertRaisesRegex(smoke.SmokeFailure, "^command cleanup failed$"):
                smoke.run_command([sys.executable])
        self.assertEqual(process.wait.call_count, 2)

    def test_timeout_kills_the_owned_parent_and_descendant(self):
        with tempfile.TemporaryDirectory(prefix="android-sync-command-test-") as directory:
            pid_file = Path(directory) / "pids"
            program = ("import os, pathlib, subprocess, sys, time; "
                       "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)']); "
                       "pathlib.Path(sys.argv[1]).write_text(str(os.getpid()) + ' ' + str(child.pid)); time.sleep(30)")
            clock = time.monotonic
            started = None

            def ready_clock():
                nonlocal started
                if started is None:
                    # Bound startup separately so the kill deadline cannot race PID publication.
                    deadline = clock() + 5
                    while not pid_file.exists() and clock() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(pid_file.exists(), "child did not publish owned PIDs")
                    started = clock()
                return clock()

            with patch.object(smoke.time, "monotonic", side_effect=ready_clock):
                with self.assertRaisesRegex(smoke.SmokeFailure, "deadline exceeded"):
                    smoke.run_command([sys.executable, "-c", program, str(pid_file)], timeout=0.5, capture=True)
            self.assertLess(time.monotonic() - started, 3)
            for pid in map(int, pid_file.read_text().split()):
                self.assert_stopped(pid)

    def test_success_also_terminates_a_wrapper_descendant(self):
        with tempfile.TemporaryDirectory(prefix="android-sync-child-test-") as directory:
            pid_file = Path(directory) / "pid"
            program = ("import pathlib, subprocess, sys; "
                       "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)']); "
                       "pathlib.Path(sys.argv[1]).write_text(str(child.pid))")
            smoke.run_command([sys.executable, "-c", program, str(pid_file)], timeout=2)
            self.assert_stopped(int(pid_file.read_text()))

    def assert_stopped(self, pid):
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            try:
                value = Path(f"/proc/{pid}/stat").read_text()
                if value.split(") ", 1)[1].split()[0] == "Z":
                    return  # The dead grandchild belongs to init; our direct child is reaped.
            except FileNotFoundError:
                return
            time.sleep(0.01)
        self.fail("Owned subprocess remained running")


class PrivateFileTests(unittest.TestCase):
    def test_private_file_mode_is_exact_even_with_a_restrictive_umask(self):
        with tempfile.TemporaryDirectory(prefix="android-sync-mode-test-") as directory:
            path = Path(directory) / "password"
            previous = os.umask(0o777)
            try:
                smoke.private_file(path, "synthetic secret")
            finally:
                os.umask(previous)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_private_file_is_exclusive_0600_and_never_overwrites_a_link(self):
        with tempfile.TemporaryDirectory(prefix="android-sync-private-test-") as directory:
            root = Path(directory)
            target = root / "password"
            smoke.private_file(target, "synthetic secret")
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
            with self.assertRaises(FileExistsError):
                smoke.private_file(target, "replacement")
            link = root / "link"
            link.symlink_to(target)
            with self.assertRaises(OSError):
                smoke.private_file(link, "replacement")
            self.assertEqual(target.read_text(), "synthetic secret")


FAKE_DOCKER = r'''#!/usr/bin/python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ["FAKE_CALLS"], "a") as file:
    file.write(json.dumps(args) + "\n")
stage = "image" if args[:2] == ["image", "rm"] else args[0]
if stage == os.environ.get("FAKE_FAIL"):
    print("PRIVATE DOCKER BODY", file=sys.stderr)
    raise SystemExit(23)
if stage == "inspect":
    if "NetworkSettings" in args[2]:
        print(json.dumps({"8080/tcp": [{"HostIp": os.environ.get("FAKE_IP", "127.0.0.1"), "HostPort": "32123"}]}))
    else:
        print(os.environ.get("FAKE_RUNNING", "true"))
elif stage == "exec":
    print(json.dumps({"id": "01ARZ3NDEKTSV4RRFFQ69G5FAZ", "username": args[5]}))
elif stage == "ps":
    print(os.environ.get("FAKE_OWNED", ""))
'''

FAKE_RUNNER = r'''#!/usr/bin/python3
import json, os, pathlib, stat, sys
manifest_path = pathlib.Path(os.environ["MONKEYSPAW_SYNC_MANIFEST"])
manifest = json.loads(manifest_path.read_text())
root = pathlib.Path(manifest["root"])
files = [manifest_path] + list((root / "secrets").iterdir())
assert all(stat.S_IMODE(file.stat().st_mode) == 0o600 for file in files)
assert all(stat.S_IMODE((root / name).stat().st_mode) == 0o700 for name in [".", "data", "secrets", "devices"])
assert os.environ["MONKEYSPAW_REQUIRE_SYNC_SERVER"] == "1"
assert manifest["servers"]["main"]["url"] == "http://127.0.0.1:32123"
calls = pathlib.Path(os.environ["FAKE_CALLS"]).read_text()
assert all(file.read_text() not in calls for file in (root / "secrets").iterdir())
pathlib.Path(os.environ["FAKE_OBSERVATION"]).write_text(json.dumps({"root": str(root), "manifest": str(manifest_path)}))
print("PRIVATE RUNNER BODY")
print("PRIVATE RUNNER ERROR", file=sys.stderr)
raise SystemExit(17 if os.environ.get("FAKE_FAIL") == "runner" else 0)
'''


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="android-sync-wrapper-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for name, text in (("docker", FAKE_DOCKER), ("runner", FAKE_RUNNER)):
            path = self.root / name
            path.write_text(text)
            path.chmod(0o700)
        self.calls = self.root / "calls.jsonl"
        self.observation = self.root / "observation.json"
        self.env = patch.dict(os.environ, {"PATH": str(self.root) + os.pathsep + os.environ["PATH"],
            "TMPDIR": str(self.root), "FAKE_CALLS": str(self.calls), "FAKE_OBSERVATION": str(self.observation)}, clear=False)
        self.env.start()
        self.addCleanup(self.env.stop)
        # tempfile may have already cached the host tempdir; isolate all disposable roots here.
        self.tempdir = patch.object(tempfile, "tempdir", str(self.root))
        self.tempdir.start()
        self.addCleanup(self.tempdir.stop)
        for field, value in (("BUILD_TIMEOUT", 5), ("RUNNER_TIMEOUT", 5), ("COMMAND_TIMEOUT", 5), ("HEALTH_TIMEOUT", 5)):
            value_patch = patch.object(smoke, field, value)
            value_patch.start()
            self.addCleanup(value_patch.stop)
        for field in ("getuid", "getgid"):
            identity = patch.object(smoke.os, field, return_value=1000)
            identity.start()
            self.addCleanup(identity.stop)

    def run_smoke(self, healthy=True):
        with patch.object(smoke, "health", return_value=healthy):
            smoke.smoke([str(self.root / "runner"), "literal; argument"])

    def read_calls(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def assert_clean(self):
        self.assertEqual(list(self.root.glob("monkeyspaw-android-sync-*")), [])

    def test_success_uses_nonroot_loopback_private_manifest_and_removes_everything(self):
        self.run_smoke()
        calls = self.read_calls()
        run = next(call for call in calls if call[0] == "run")
        self.assertEqual(run[run.index("--user") + 1], "1000:1000")
        self.assertEqual(run[run.index("--publish") + 1], "127.0.0.1::8080")
        self.assertEqual(calls[-2][:2], ["rm", "--force"])
        self.assertEqual(calls[-1][:3], ["image", "rm", "--force"])
        self.assertFalse(Path(json.loads(self.observation.read_text())["root"]).exists())
        self.assert_clean()

    def test_runtime_directories_and_files_are_private_with_a_restrictive_umask(self):
        self.calls.touch(mode=0o600)
        self.observation.touch(mode=0o600)
        previous = os.umask(0o777)
        try:
            self.run_smoke()
        finally:
            os.umask(previous)
        self.assert_clean()

    def test_command_and_runner_failures_always_attempt_bounded_cleanup(self):
        for stage in ("build", "run", "inspect", "exec", "runner"):
            with self.subTest(stage=stage), patch.dict(os.environ, {"FAKE_FAIL": stage}):
                self.calls.unlink(missing_ok=True)
                with self.assertRaises(smoke.SmokeFailure) as failure:
                    self.run_smoke()
                self.assertNotIn("PRIVATE", str(failure.exception))
                calls = self.read_calls()
                self.assertEqual(calls[-1][:3], ["image", "rm", "--force"])
                if stage != "build":
                    self.assertEqual(calls[-2][:2], ["rm", "--force"])
                self.assert_clean()

    def test_stopped_unhealthy_and_nonloopback_servers_fail(self):
        for env, healthy in (({"FAKE_RUNNING": "false"}, True), ({"FAKE_IP": "0.0.0.0"}, True), ({}, False)):
            with self.subTest(env=env), patch.dict(os.environ, env), patch.object(smoke, "HEALTH_TIMEOUT", 5 if healthy else 0.1):
                with self.assertRaises(smoke.SmokeFailure):
                    self.run_smoke(healthy=healthy)
                self.assert_clean()

    def test_cleanup_failure_fails_and_still_attempts_remaining_cleanup(self):
        for stage in ("rm", "image"):
            with self.subTest(stage=stage), patch.dict(os.environ, {"FAKE_FAIL": stage}):
                with self.assertRaisesRegex(smoke.SmokeFailure, "cleanup failed"):
                    self.run_smoke()
                self.assertEqual(self.read_calls()[-1][:3], ["image", "rm", "--force"])
                self.assert_clean()

    def test_cleanup_failure_preserves_primary_failure_and_reports_both(self):
        for stage in ("build", "run", "runner"):
            with self.subTest(stage=stage), patch.dict(os.environ, {"FAKE_FAIL": stage}):
                original = smoke.run_command
                stderr = io.StringIO()

                def fail_cleanup(arguments, *args, **kwargs):
                    if arguments[1:3] == ["rm", "--force"] or arguments[1:3] == ["image", "rm"]:
                        original(arguments, *args, **kwargs)
                        raise smoke.SmokeFailure("command failed")
                    return original(arguments, *args, **kwargs)

                with patch.object(smoke, "run_command", side_effect=fail_cleanup), redirect_stderr(stderr):
                    with self.assertRaisesRegex(smoke.SmokeFailure, "^command failed$"):
                        self.run_smoke()
                self.assertIn("container or image cleanup failed", stderr.getvalue())
                self.assertNotIn("PRIVATE", stderr.getvalue())
                self.assertEqual(self.read_calls()[-1][:3], ["image", "rm", "--force"])
                self.assert_clean()

    def test_interrupted_runner_containers_are_removed_by_the_owned_label(self):
        with patch.dict(os.environ, {"FAKE_OWNED": "deadbeefdead"}):
            self.run_smoke()
        calls = self.read_calls()
        listing = next(call for call in calls if call[0] == "ps")
        self.assertTrue(listing[-1].startswith("label=monkeyspaw.sync-run=monkeyspaw-android-sync-"))
        self.assertIn(["rm", "--force", "deadbeefdead"], calls)
        self.assert_clean()

    def test_missing_runner_docker_or_root_identity_fails_before_provisioning(self):
        with self.assertRaises(smoke.SmokeFailure):
            smoke.smoke([])
        with self.assertRaises(smoke.SmokeFailure):
            smoke.smoke(["/missing-runner"])
        with patch.dict(os.environ, {"PATH": "/nonexistent"}):
            with self.assertRaises(smoke.SmokeFailure):
                smoke.smoke([str(self.root / "runner")])
        with patch.object(smoke.os, "getuid", return_value=0):
            with self.assertRaisesRegex(smoke.SmokeFailure, "non-root runner"):
                self.run_smoke()
        self.assertFalse(self.calls.exists())
        self.assert_clean()

    def test_cli_prints_only_fixed_diagnostics(self):
        for reason in (None, "command failed"):
            stdout, stderr = io.StringIO(), io.StringIO()
            effect = None if reason is None else smoke.SmokeFailure(reason)
            with patch.object(smoke, "smoke", side_effect=effect), patch.object(sys, "argv", [str(SCRIPT), "--", "runner"]), \
                    patch.object(signal, "signal"), redirect_stdout(stdout), redirect_stderr(stderr):
                self.assertEqual(smoke.main(), 0 if reason is None else 1)
            self.assertNotIn("PRIVATE", stdout.getvalue() + stderr.getvalue())
            self.assertIn("PASS" if reason is None else "command failed", stdout.getvalue() + stderr.getvalue())


class HealthTests(unittest.TestCase):
    def test_health_requires_a_bounded_ok_json_response_and_disables_redirects(self):
        class Response:
            status = 200
            def __init__(self, body): self.body = body
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def read(self, count): return self.body[:count]

        for body, valid in ((b'{"status":"ok","version":"dev"}', True), (b'{"status":"bad","version":"dev"}', False),
                            (b'PRIVATE BODY', False), (b'X' * 5000, False)):
            with patch.object(smoke.urllib.request, "build_opener") as factory:
                factory.return_value.open.return_value = Response(body)
                if valid:
                    self.assertTrue(smoke.health("http://127.0.0.1:32123", 1))
                else:
                    with self.assertRaises(smoke.SmokeFailure): smoke.health("http://127.0.0.1:32123", 1)
                self.assertIsInstance(factory.call_args.args[0], smoke.urllib.request.ProxyHandler)
                self.assertIsInstance(factory.call_args.args[1], smoke.NoRedirect)
        self.assertIsNone(smoke.NoRedirect().redirect_request(None, None, 302, "", {}, "http://outside.invalid"))


class OfflineControlTests(unittest.TestCase):
    def setUp(self):
        root = tempfile.TemporaryDirectory(prefix="android-sync-control-test-")
        self.addCleanup(root.cleanup)
        self.data = Path(root.name)
        (self.data / ".monkeyspaw.lock").touch(mode=0o600)
        self.database = self.data / "monkeyspaw.db"
        with sqlite3.connect(self.database) as db:
            db.executescript("""
                CREATE TABLE meta(database_id TEXT);
                INSERT INTO meta VALUES ('AE279D6D-61B8-4EAA-A1D1-D286264D2EC1');
                CREATE TABLE changes(seq INTEGER PRIMARY KEY, scope_key TEXT, at TEXT, content TEXT);
                INSERT INTO changes VALUES(1,'user:01ARZ3NDEKTSV4RRFFQ69G5FAZ','2026-10-14T00:00:00.000Z','exact bytes');
                CREATE TRIGGER changes_immutable BEFORE UPDATE ON changes BEGIN SELECT RAISE(ABORT,'immutable'); END;
                CREATE TABLE prompts(id TEXT, scope TEXT, owner_id TEXT, group_id TEXT, deleted_at TEXT, rev INTEGER, content TEXT);
                CREATE TABLE prompt_revisions(scope TEXT, owner_id TEXT, group_id TEXT, rev INTEGER);
                CREATE TABLE retired_prompt_ids(scope TEXT, owner_id TEXT, group_id TEXT);
                CREATE TABLE scope_heads(scope_key TEXT, head_seq INTEGER);
                INSERT INTO scope_heads VALUES('user:01ARZ3NDEKTSV4RRFFQ69G5FAZ',1);
                CREATE TABLE scope_floors(scope_key TEXT, floor_seq INTEGER);
                CREATE TABLE snapshots(scope_key TEXT, created_at TEXT, expires_at TEXT, manifest BLOB,
                    CHECK(expires_at > created_at));
                INSERT INTO snapshots VALUES('user:01ARZ3NDEKTSV4RRFFQ69G5FAZ','2026-10-14T00:00:00.000Z',
                    '2026-10-14T00:15:00.000Z',x'000102');
                CREATE TRIGGER snapshots_immutable BEFORE UPDATE ON snapshots BEGIN SELECT RAISE(ABORT,'immutable'); END;
            """)

    def control(self, action, **fields):
        return smoke.database_control(dict(action=action, data=str(self.data), **fields))

    def test_only_timestamps_age_and_immutable_triggers_are_restored(self):
        with sqlite3.connect(self.database) as db:
            original = smoke.database_fingerprint(db, {"changes": {"at"}, "prompts": {"deleted_at"},
                                                       "snapshots": {"created_at", "expires_at"}})
        self.control("age", kind="retention", seconds=91 * 86400)
        self.control("age", kind="expiry", seconds=901)
        with sqlite3.connect(self.database) as db:
            self.assertEqual(original, smoke.database_fingerprint(db, {"changes": {"at"}, "prompts": {"deleted_at"},
                                                                       "snapshots": {"created_at", "expires_at"}}))
            self.assertLess(db.execute("SELECT at FROM changes").fetchone()[0], "2026-08")
            self.assertLess(db.execute("SELECT expires_at FROM snapshots").fetchone()[0], "2026-10-14T00:00:00.000Z")
            with self.assertRaises(sqlite3.IntegrityError): db.execute("UPDATE changes SET content='changed'")
            with self.assertRaises(sqlite3.IntegrityError): db.execute("UPDATE snapshots SET manifest=x'ff'")
        self.assertEqual(self.control("inspect")["changes"], 1)
        self.assertEqual(self.control("inspect", scope="user:01ARZ3NDEKTSV4RRFFQ69G5FAZ")["head"], 1)

    def test_a_live_server_lock_refuses_all_offline_mutation(self):
        with (self.data / ".monkeyspaw.lock").open("r+b") as lock:
            fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
            with self.assertRaisesRegex(smoke.SmokeFailure, "server still running"):
                self.control("age", kind="retention", seconds=91 * 86400)
        self.assertEqual(self.control("inspect")["changes"], 1)

    def test_maintenance_observer_counts_only_committed_effects_and_removes_itself(self):
        self.control("retention_begin")
        self.control("age", kind="retention", seconds=91 * 86400)
        with sqlite3.connect(self.database) as db:
            db.execute("DELETE FROM changes")
            db.rollback()
            db.execute("DELETE FROM changes")
            db.execute("INSERT INTO scope_floors VALUES('user:01ARZ3NDEKTSV4RRFFQ69G5FAZ',2)")
            db.execute("UPDATE scope_floors SET floor_seq=3")
            db.execute("UPDATE scope_floors SET floor_seq=3")
        self.assertEqual(self.control("retention_end"), {"changes": 1, "floors": 2, "tombstones": 0, "revisions": 0})
        with sqlite3.connect(self.database) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'acceptance_%'").fetchone()[0], 0)

    def test_invalid_age_controls_never_change_the_database(self):
        for fields in (dict(kind="retention", seconds=0), dict(kind="retention", seconds=True), dict(kind="heads", seconds=1)):
            with self.assertRaises(smoke.SmokeFailure): self.control("age", **fields)
        self.assertEqual(self.control("inspect")["changes"], 1)


class ArtifactTests(unittest.TestCase):
    def test_failure_artifact_cannot_copy_credentials_bodies_or_stack_traces(self):
        with tempfile.TemporaryDirectory(prefix="android-sync-reports-") as directory:
            root = Path(directory)
            (root / "TEST-private.xml").write_text('''<testsuite tests="2" failures="1" errors="0" skipped="0"
                name="SECRET TOKEN"><testcase name="PRIVATE CONTENT"><failure message="PASSWORD">PRIVATE STACK</failure></testcase>
                <system-out>SECRET TOKEN
Full semantic sync acceptance: 24 files / 87 cases / 3000 actions / 8000 expectations; pending 0.
                </system-out></testsuite>''')
            result = root / "sanitized.json"
            totals, summaries = smoke.sanitized_reports(root, result)
            self.assertEqual(totals, dict(tests=2, failures=1, errors=0, skipped=0))
            self.assertEqual(summaries[0]["cases"], 87)
            self.assertNotRegex(result.read_text(), "SECRET|PRIVATE|PASSWORD|TOKEN|STACK")


if __name__ == "__main__":
    unittest.main()
