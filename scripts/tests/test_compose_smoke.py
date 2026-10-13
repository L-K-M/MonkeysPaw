#!/usr/bin/env python3
"""Exercise the smoke contract and secret handling with a fake curl."""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SMOKE = Path(__file__).resolve().parents[1] / "compose-smoke.sh"
PASSWORD = 'smoke-"password\\$# café  '
TOKEN = "A" * 43
FAKE_CURL = r'''#!/usr/bin/env python3
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

args = sys.argv[1:]
assert args[0] == "--disable"
assert all(os.environ["FAKE_PASSWORD"] not in arg and "A" * 43 not in arg for arg in args)
assert args[args.index("--connect-timeout") + 1] == "5"
assert args[args.index("--max-time") + 1] == "15"
assert args[args.index("--noproxy") + 1] == "*"
assert "--fail" in args and "--silent" in args and "--location" not in args
state_file = Path(os.environ["FAKE_STATE"])
state = json.loads(state_file.read_text()) if state_file.exists() else {"step": 0}
step = state["step"]
method = args[args.index("--request") + 1]
endpoint = urlsplit(args[-1]).path
assert method == ["GET", "POST", "PUT", "GET", "POST", "PUT", "GET", "POST"][step]
if step == 0:
    assert endpoint == "/api/health"
elif step == 1:
    assert endpoint == "/api/v1/auth/login"
elif step in (4, 7):
    assert endpoint == "/api/v1/sync/pull"
else:
    assert re.fullmatch(r"/api/v1/prompts/[0-7][0-9A-HJKMNP-TV-Z]{25}", endpoint)

headers = [args[i + 1] for i, arg in enumerate(args) if arg == "--header"]
auth = [header for header in headers if header.startswith("@")]
assert bool(auth) == (step >= 2)
if auth:
    header_file = Path(auth[0][1:])
    assert header_file.stat().st_mode & 0o077 == 0
    assert header_file.read_text() == "Authorization: Bearer " + "A" * 43 + "\n"
body = None
if method != "GET":
    data_arg = args[args.index("--data-binary") + 1]
    assert data_arg.startswith("@")
    request_file = Path(data_arg[1:])
    assert request_file.stat().st_mode & 0o077 == 0
    assert "Content-Type: application/json" in headers
    body = json.loads(request_file.read_text())
else:
    assert "--data-binary" not in args

database_id = "12345678-1234-4234-8234-123456789abc"
user_id = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
scope_key = "user:" + user_id
case = os.environ["FAKE_CASE"]
if step == 0:
    response = {"status": "ok", "version": "dev"}
elif step == 1:
    assert body == {"username": "admin", "password": os.environ["FAKE_PASSWORD"], "device_name": "Compose smoke CI"}
    response = {"device_token": "A" * 43, "user": {
        "id": user_id, "username": "admin", "display_name": None, "account_kind": "admin",
        "created_at": "2026-10-13T00:00:00.000Z", "disabled_at": None,
    }}
    if case == "bad_login":
        response["device_token"] = "A" * 43 + "\nInjected: header"
elif step in (2, 5):
    rev = 1 if step == 2 else 2
    prompt_id = endpoint.rsplit("/", 1)[1]
    if rev == 2:
        assert prompt_id == state["prompt"]["id"]
    suffix = "" if rev == 1 else "-updated"
    text = "First" if rev == 1 else "Second"
    expected = {"base_rev": rev - 1, "scope": "user",
                "path": "Compose-smoke/" + prompt_id + suffix + ".md",
                "content": "---\nid: " + prompt_id + "\ntitle: Compose smoke\n---\n" + text + " smoke write.\n"}
    assert body == expected
    state["prompt"] = {"id": prompt_id, "rev": rev, "path": body["path"], "content": body["content"]}
    state["seq"] = rev + 6  # Sequences need not equal prompt revisions.
    response = {"rev": rev, "seq": state["seq"]}
    if case == "bad_write" and step == 2:
        response["rev"] = 2
elif step in (3, 6):
    assert endpoint.endswith(state["prompt"]["id"])
    response = {**state["prompt"], "scope": "user"}
    if case == "bad_read" and step == 3:
        response["content"] += "Unexpected bytes"
else:
    expected_request = {"database_id": None, "cursors": {}} if step == 4 else {
        "database_id": database_id, "cursors": {scope_key: "7"},
    }
    assert body == expected_request
    scope = {"key": scope_key, "kind": "user", "mode": "snapshot" if step == 4 else "delta",
             "head": state["seq"], "cursor": str(state["seq"]), "has_more": False,
             "items": [{"seq": state["seq"], "kind": "upsert", "prompt": dict(state["prompt"])}]}
    response = {"database_id": database_id, "removed": [], "scopes": [scope]}
    if case == "bad_snapshot_database" and step == 4:
        response["database_id"] = "invalid"
    if case == "bad_delta_database" and step == 7:
        response["database_id"] = "87654321-1234-4234-8234-123456789abc"
    if case == "bad_snapshot_mode" and step == 4:
        scope["mode"] = "delta"
    if case == "bad_delta_mode" and step == 7:
        scope["mode"] = "snapshot"
    if case == "bad_snapshot_item" and step == 4:
        scope["items"][0]["prompt"]["path"] = "Wrong.md"
    if case == "bad_delta_item" and step == 7:
        scope["items"][0]["prompt"]["rev"] = 1
    if case == "bad_delta_cursor" and step == 7:
        scope["cursor"] = "7"
    if case == "incomplete_snapshot" and step == 4:
        scope["has_more"] = True

state["step"] += 1
state_file.write_text(json.dumps(state))
output = Path(args[args.index("--output") + 1])
output.write_text(json.dumps(response))
assert output.stat().st_mode & 0o077 == 0
if case == "transport_failure" and step == 0:
    sys.stderr.write(os.environ["FAKE_PASSWORD"] + "A" * 43)
    sys.exit(7)
sys.stdout.write("201" if case == "wrong_http_status" and step == 0 else "200")
'''


class ComposeSmokeTests(unittest.TestCase):
    def run_smoke(self, case, password_mode=0o600):
        with tempfile.TemporaryDirectory(prefix="test-compose-smoke-") as directory:
            work = Path(directory)
            fake_bin = work / "bin"
            fake_bin.mkdir()
            curl = fake_bin / "curl"
            curl.write_text(FAKE_CURL)
            curl.chmod(0o700)
            password = work / "admin-password"
            password.write_bytes((PASSWORD + "\r\n").encode("utf-8"))
            password.chmod(password_mode)
            temporary = work / "temporary"
            temporary.mkdir()
            state = work / "state.json"
            env = {**os.environ, "PATH": str(fake_bin) + os.pathsep + os.environ["PATH"],
                   "TMPDIR": str(temporary), "FAKE_PASSWORD": PASSWORD,
                   "FAKE_STATE": str(state), "FAKE_CASE": case,
                   "http_proxy": "http://proxy.invalid:9999", "https_proxy": "http://proxy.invalid:9999",
                   "all_proxy": "http://proxy.invalid:9999", "no_proxy": "", "NO_PROXY": ""}
            result = subprocess.run(["bash", "-x", str(SMOKE), "http://127.0.0.1:8790", str(password)],
                                    env=env, capture_output=True, text=True, encoding="utf-8", timeout=30)
            self.assertNotIn(PASSWORD, result.stdout + result.stderr)
            self.assertNotIn(TOKEN, result.stdout + result.stderr)
            self.assertEqual(list(temporary.iterdir()), [], "Private request/response files must be removed")
            if case == "readable_password":
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Compose smoke failed during setup", result.stderr)
                self.assertFalse(state.exists(), "No request may run with a group- or world-readable password file")
                return
            if case == "success":
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Compose smoke passed", result.stdout)
                self.assertEqual(json.loads(state.read_text())["step"], 8)
            else:
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Compose smoke passed", result.stdout)
                self.assertIn("Compose smoke failed during", result.stderr)
                # The failure names its cause without bodies: curl status or an exception type.
                self.assertRegex(result.stderr, r"failed during [^(]+\((curl exit \d+, HTTP \S+|[A-Za-z]+Error|TimeoutExpired)\)")
                failure_steps = {
                    "transport_failure": 1, "wrong_http_status": 1, "bad_login": 2,
                    "bad_write": 3, "bad_read": 4, "bad_snapshot_database": 5,
                    "bad_snapshot_mode": 5, "bad_snapshot_item": 5, "incomplete_snapshot": 5,
                    "bad_delta_database": 8, "bad_delta_mode": 8, "bad_delta_item": 8,
                    "bad_delta_cursor": 8,
                }
                self.assertEqual(json.loads(state.read_text())["step"], failure_steps[case])

    def test_round_trip_and_private_files(self):
        self.run_smoke("success")

    def test_rejects_a_readable_password_file(self):
        self.run_smoke("readable_password", password_mode=0o640)

    def test_rejects_failed_transport_status_and_contracts(self):
        for case in ("transport_failure", "wrong_http_status", "bad_login", "bad_write", "bad_read",
                     "bad_snapshot_database", "bad_snapshot_mode", "bad_snapshot_item", "incomplete_snapshot",
                     "bad_delta_database", "bad_delta_mode", "bad_delta_item", "bad_delta_cursor"):
            with self.subTest(case=case):
                self.run_smoke(case)


if __name__ == "__main__":
    unittest.main()
