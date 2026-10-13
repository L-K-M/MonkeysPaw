#!/usr/bin/env bash
# Use only against a disposable, freshly bootstrapped Compose database.
set +x
set -euo pipefail
umask 077

if [[ $# -lt 2 || $# -gt 3 ]]; then
    printf 'Usage: %s BASE_URL ADMIN_PASSWORD_FILE [ADMIN_USERNAME]\n' "$0" >&2
    exit 2
fi

# Keep passwords, tokens and response bodies out of shell variables and argv.
python3 -I - "$@" <<'PY'
import json
import re
import secrets
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from urllib.parse import urlsplit

base_url = sys.argv[1].rstrip("/")
password_file = Path(sys.argv[2])
username = sys.argv[3] if len(sys.argv) == 4 else "admin"
phase = "setup"
# Exit codes, HTTP statuses and exception types carry no secrets.
detail = ""

try:
    url = urlsplit(base_url)
    assert url.scheme in ("http", "https") and url.hostname
    assert not (url.username or url.password or url.query or url.fragment or url.path)
    assert password_file.is_file() and password_file.stat().st_mode & 0o077 == 0
    password = password_file.read_bytes()
    # Match BootstrapConfiguration: remove one terminal LF or CRLF, not spaces.
    if password.endswith(b"\n"):
        password = password[:-1]
        if password.endswith(b"\r"):
            password = password[:-1]
    password = password.decode("utf-8")

    with tempfile.TemporaryDirectory(prefix="monkeyspaw-compose-smoke-") as directory:
        work = Path(directory)
        headers_file = work / "auth.headers"

        def request(method, endpoint, body=None, authenticated=True):
            response_file = work / "response.json"
            command = [
                "curl", "--disable", "--fail", "--silent", "--show-error",
                "--noproxy", "*",
                "--connect-timeout", "5", "--max-time", "15",
                "--request", method, "--output", str(response_file),
                "--write-out", "%{http_code}",
            ]
            if authenticated:
                command += ["--header", "@" + str(headers_file)]
            if body is not None:
                request_file = work / "request.json"
                request_file.write_text(json.dumps(body), encoding="utf-8")
                command += ["--header", "Content-Type: application/json",
                            "--data-binary", "@" + str(request_file)]
            command.append(base_url + endpoint)
            result = subprocess.run(command, capture_output=True, timeout=20)
            global detail
            status = result.stdout.strip().decode("ascii", "replace")
            detail = "curl exit " + str(result.returncode) + ", HTTP " + (status or "none")
            assert result.returncode == 0 and status == "200"
            detail = ""
            return json.loads(response_file.read_text(encoding="utf-8"))

        phase = "unauthenticated health"
        health = request("GET", "/api/health", authenticated=False)
        assert health["status"] == "ok" and isinstance(health["version"], str) and health["version"]

        phase = "bootstrap login"
        auth = request("POST", "/api/v1/auth/login", {
            "username": username, "password": password, "device_name": "Compose smoke CI",
        }, authenticated=False)
        assert auth["user"]["username"] == username and auth["user"]["account_kind"] == "admin"
        user_id = auth["user"]["id"]
        assert re.fullmatch(r"[0-7][0-9A-HJKMNP-TV-Z]{25}", user_id)
        assert re.fullmatch(r"[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]", auth["device_token"])
        headers_file.write_text("Authorization: Bearer " + auth["device_token"] + "\n", encoding="utf-8")

        alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
        value = (int(time.time() * 1000) << 80) | secrets.randbits(80)
        prompt_id = "".join(alphabet[(value >> shift) & 31] for shift in range(125, -1, -5))
        endpoint = "/api/v1/prompts/" + prompt_id
        scope_key = "user:" + user_id

        def write_and_read(base_rev, suffix, body):
            path = "Compose-smoke/" + prompt_id + suffix + ".md"
            # Canonical front matter and LF body; private storage preserves bytes.
            content = "---\nid: " + prompt_id + "\ntitle: Compose smoke\n---\n" + body + "\n"
            write = request("PUT", endpoint, {
                "base_rev": base_rev, "scope": "user", "path": path, "content": content,
            })
            assert type(write["rev"]) is int and write["rev"] == base_rev + 1
            assert type(write["seq"]) is int and write["seq"] > 0
            expected = {"id": prompt_id, "rev": write["rev"], "path": path, "content": content}
            # The PUT DTO returns rev/seq; GET supplies the stored representation.
            assert request("GET", endpoint) == {**expected, "scope": "user"}
            return write, expected

        def check_pull(response, mode, write, expected):
            database_id = response["database_id"]
            assert str(uuid.UUID(database_id)) == database_id
            assert response["removed"] == []
            assert response["scopes"] == [{
                "key": scope_key, "kind": "user", "mode": mode,
                "head": write["seq"], "cursor": str(write["seq"]), "has_more": False,
                "items": [{"seq": write["seq"], "kind": "upsert", "prompt": expected}],
            }]

        phase = "first write and read"
        first, first_prompt = write_and_read(0, "", "First smoke write.")
        phase = "initial snapshot"
        snapshot = request("POST", "/api/v1/sync/pull", {"database_id": None, "cursors": {}})
        check_pull(snapshot, "snapshot", first, first_prompt)

        phase = "second write and read"
        second, second_prompt = write_and_read(first["rev"], "-updated", "Second smoke write.")
        assert second["seq"] > first["seq"]
        phase = "delta from snapshot cursor"
        delta = request("POST", "/api/v1/sync/pull", {
            "database_id": snapshot["database_id"],
            "cursors": {scope_key: snapshot["scopes"][0]["cursor"]},
        })
        check_pull(delta, "delta", second, second_prompt)
        assert delta["database_id"] == snapshot["database_id"]
except (AssertionError, OSError, ValueError, KeyError, IndexError, TypeError, subprocess.TimeoutExpired) as error:
    # Response bodies and curl stderr may contain credentials or prompt content.
    sys.exit("Compose smoke failed during " + phase + " (" + (detail or type(error).__name__) + ").")

print("Compose smoke passed: health, login, writes, snapshot and delta.")
PY
