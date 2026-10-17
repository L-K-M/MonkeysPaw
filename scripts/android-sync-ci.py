#!/usr/bin/env python3
"""Full Kotlin sync acceptance and offline controls for disposable same-head servers."""

import json
import fcntl
import hashlib
import os
from pathlib import Path
import re
import secrets
import selectors
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
import xml.etree.ElementTree as ET
from contextlib import closing


ROOT = Path(__file__).resolve().parents[1]
COMMAND_TIMEOUT = 60
BUILD_TIMEOUT = 1200
RUNNER_TIMEOUT = 1800
HEALTH_TIMEOUT = 120
OUTPUT_CAP = 65536
ULID = re.compile(r"[0-7][0-9A-HJKMNP-TV-Z]{25}")


class SmokeFailure(Exception):
    """Fixed diagnostics only; never retain subprocess or HTTP error bodies."""


def executable(name):
    candidate = shutil.which(name)
    if candidate is None:
        raise SmokeFailure("required executable unavailable")
    result = Path(candidate).resolve()
    if not result.is_file() or not os.access(result, os.X_OK):
        raise SmokeFailure("required executable unavailable")
    return str(result)


def run_command(arguments, timeout=COMMAND_TIMEOUT, *, capture=False, env=None):
    """Own the process group, drain stdout before wait, and discard stderr."""
    argv = [executable(arguments[0]), *arguments[1:]]
    process = None
    try:
        process = subprocess.Popen(argv, cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, start_new_session=True)
        deadline = time.monotonic() + timeout
        output = bytearray()
        if capture:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while selector.get_map():
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise SmokeFailure("command deadline exceeded")
                    for key, _ in selector.select(min(remaining, 1)):
                        chunk = os.read(key.fileobj.fileno(), OUTPUT_CAP + 1)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        if len(output) + len(chunk) > OUTPUT_CAP:
                            raise SmokeFailure("command output exceeded limit")
                        output.extend(chunk)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise SmokeFailure("command deadline exceeded")
        if process.wait(timeout=remaining) != 0:
            raise SmokeFailure("command failed")
        return bytes(output)
    except subprocess.TimeoutExpired:
        raise SmokeFailure("command deadline exceeded") from None
    except OSError:
        raise SmokeFailure("command could not start") from None
    finally:
        if process is not None:
            failure_active = sys.exc_info()[0] is not None
            cleanup_failed = False
            # Also reap descendants left by an exited wrapper or inherited stdout pipe.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError:
                cleanup_failed = True
            try:
                process.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                cleanup_failed = True
            if process.stdout is not None:
                process.stdout.close()
            if cleanup_failed:
                if not failure_active:
                    raise SmokeFailure("command cleanup failed")
                print("Android sync smoke: command cleanup failed", file=sys.stderr)


def private_file(path, contents):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as file:
        os.fchmod(file.fileno(), 0o600)
        file.write(contents)


def json_output(arguments, **options):
    try:
        return json.loads(run_command(arguments, capture=True, **options))
    except (ValueError, UnicodeError):
        raise SmokeFailure("invalid command result") from None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def health(url, timeout):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(url + "/api/health", timeout=timeout) as response:
            body = response.read(4097)
            if response.status != 200 or len(body) > 4096:
                raise SmokeFailure("invalid server health")
            value = json.loads(body)
            if not isinstance(value, dict) or value.get("status") != "ok" or not isinstance(value.get("version"), str):
                raise SmokeFailure("invalid server health")
            return True
    except urllib.error.HTTPError:
        raise SmokeFailure("server health rejected") from None
    except (ValueError, UnicodeError):
        raise SmokeFailure("invalid server health") from None
    except (urllib.error.URLError, TimeoutError, OSError):
        return False


def endpoint(docker, name):
    ports = json_output([docker, "inspect", "--format", "{{json .NetworkSettings.Ports}}", name])
    try:
        bindings = ports["8080/tcp"]
        if len(bindings) != 1 or bindings[0]["HostIp"] != "127.0.0.1":
            raise ValueError()
        port = bindings[0]["HostPort"]
        if not isinstance(port, str) or not re.fullmatch(r"[0-9]+", port) or not 1 <= int(port) <= 65535:
            raise ValueError()
        return "http://127.0.0.1:" + port
    except (KeyError, TypeError, ValueError):
        raise SmokeFailure("invalid loopback publication") from None


def wait_healthy(docker, name, url):
    deadline = time.monotonic() + HEALTH_TIMEOUT
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise SmokeFailure("server health deadline exceeded")
        state = run_command([docker, "inspect", "--format", "{{.State.Running}}", name],
                            timeout=min(10, remaining), capture=True)
        if state.strip() != b"true":
            raise SmokeFailure("server stopped before health")
        remaining = deadline - time.monotonic()
        if remaining > 0 and health(url, min(5, remaining)):
            return
        time.sleep(min(1, max(0, deadline - time.monotonic())))


def database_control(value):
    """Mutations require stopped serve; reads share its nonblocking flock protocol."""
    data = Path(value["data"])
    if not data.is_absolute() or data.is_symlink() or not data.is_dir():
        raise SmokeFailure("invalid control directory")
    descriptor = os.open(data / ".monkeyspaw.lock", os.O_RDWR | os.O_NOFOLLOW)
    try:
        reading = value["action"] == "inspect"
        fcntl.flock(descriptor, (fcntl.LOCK_SH if reading else fcntl.LOCK_EX) | fcntl.LOCK_NB)
        database = data / "monkeyspaw.db"
        if database.is_symlink() or not database.is_file():
            raise SmokeFailure("invalid control database")
        mode = "ro" if reading else "rw"
        with closing(sqlite3.connect(f"file:{database}?mode={mode}", uri=True, timeout=1)) as connection, connection:
            connection.execute("PRAGMA foreign_keys = ON")
            if value["action"] == "inspect":
                return inspect_database(connection, value.get("scope"))
            if value["action"] == "retention_begin":
                # Observe committed maintenance effects, including repeated floor raises.
                # These disposable audit triggers never mutate production rows.
                connection.execute("CREATE TABLE acceptance_retention (kind TEXT NOT NULL)")
                for table, kind, clause in (("changes", "changes", "DELETE"), ("prompt_revisions", "revisions", "DELETE"),
                                            ("prompts", "tombstones", "DELETE"), ("scope_floors", "floors", "INSERT"),
                                            ("scope_floors", "floors", "UPDATE")):
                    condition = " WHEN NEW.floor_seq > OLD.floor_seq" if clause == "UPDATE" else ""
                    connection.execute(f"CREATE TRIGGER acceptance_{table}_{clause} AFTER {clause} ON {table}{condition} "
                                       f"BEGIN INSERT INTO acceptance_retention VALUES ('{kind}'); END")
                return inspect_database(connection)
            if value["action"] == "retention_end":
                counts = {kind: connection.execute("SELECT COUNT(*) FROM acceptance_retention WHERE kind=?", (kind,)).fetchone()[0]
                          for kind in ("changes", "floors", "tombstones", "revisions")}
                for (name,) in connection.execute("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'acceptance_%'").fetchall():
                    connection.execute(f'DROP TRIGGER "{name}"')
                connection.execute("DROP TABLE acceptance_retention")
                return counts
            if value["action"] != "age" or type(value["seconds"]) is not int or value["seconds"] <= 0:
                raise SmokeFailure("invalid clock control")
            kind = value["kind"]
            columns = {"retention": {"changes": {"at"}, "prompts": {"deleted_at"}},
                       "expiry": {"snapshots": {"created_at", "expires_at"}}}.get(kind)
            if columns is None:
                raise SmokeFailure("invalid clock control")
            # Immutable events/manifests keep every non-clock column and trigger.
            connection.execute("BEGIN IMMEDIATE")
            before = database_fingerprint(connection, columns)
            for table, names in columns.items():
                trigger = table + "_immutable"
                row = connection.execute("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?", (trigger,)).fetchone()
                if row:
                    connection.execute(f"DROP TRIGGER {trigger}")
                assignments = ", ".join(f"{name}=strftime('%Y-%m-%dT%H:%M:%fZ', {name}, ?)" for name in sorted(names))
                connection.execute(f"UPDATE {table} SET {assignments}", [f"-{value['seconds']} seconds"] * len(names))
                if row:
                    connection.execute(row[0])
            if database_fingerprint(connection, columns) != before:
                raise SmokeFailure("clock control changed non-clock data")
            connection.commit()
            return inspect_database(connection)
    except (OSError, sqlite3.Error):
        raise SmokeFailure("offline database control failed or server still running") from None
    finally:
        os.close(descriptor)


def database_fingerprint(connection, excluded):
    digest = hashlib.sha256()
    tables = connection.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").fetchall()
    for (table,) in tables:
        names = [row[1] for row in connection.execute(f'PRAGMA table_info("{table}")') if row[1] not in excluded.get(table, set())]
        rows = connection.execute('SELECT ' + ','.join('"' + name + '"' for name in names) + f' FROM "{table}"').fetchall()
        digest.update(repr((table, sorted(rows, key=repr))).encode())
    digest.update(repr(connection.execute("SELECT name, sql FROM sqlite_master WHERE type='trigger' ORDER BY name").fetchall()).encode())
    return digest.hexdigest()


def inspect_database(connection, scope=None):
    def scalar(sql, args=()):
        return connection.execute(sql, args).fetchone()[0]
    if scope is None:
        return {"changes": scalar("SELECT COUNT(*) FROM changes"),
                "floors": dict(connection.execute("SELECT scope_key, floor_seq FROM scope_floors")),
                "tombstones": scalar("SELECT COUNT(*) FROM prompts WHERE deleted_at IS NOT NULL"),
                "revisions": scalar("SELECT COUNT(*) FROM prompt_revisions"),
                "database_id": scalar("SELECT database_id FROM meta").lower()}
    if not isinstance(scope, str) or not re.fullmatch(r"(?:user|group):[0-7][0-9A-HJKMNP-TV-Z]{25}", scope):
        raise SmokeFailure("invalid control scope")
    ownership = "(CASE scope WHEN 'user' THEN 'user:' || owner_id ELSE 'group:' || group_id END)=?"
    return {"head": scalar("SELECT COALESCE((SELECT head_seq FROM scope_heads WHERE scope_key=?),0)", (scope,)),
            "floor": scalar("SELECT COALESCE((SELECT floor_seq FROM scope_floors WHERE scope_key=?),0)", (scope,)),
            "changes": scalar("SELECT COUNT(*) FROM changes WHERE scope_key=?", (scope,)),
            "snapshots": scalar("SELECT COUNT(*) FROM snapshots WHERE scope_key=?", (scope,)),
            "tombstones": scalar("SELECT COUNT(*) FROM prompts WHERE deleted_at IS NOT NULL AND " + ownership, (scope,)),
            "revisions": scalar("SELECT COUNT(*) FROM prompt_revisions WHERE " + ownership, (scope,)),
            "retired_ids": scalar("SELECT COUNT(*) FROM retired_prompt_ids WHERE " + ownership, (scope,))}


def admin_control(value):
    data = Path(value["data"])
    name = value["name"]
    action = value["action"]
    if action not in ("backup", "restore") or not re.fullmatch(r"[a-z_]+", name):
        raise SmokeFailure("invalid backup control")
    backup = data / ("acceptance-" + name + ".db")
    native = value.get("native")
    if native:
        result = json_output([native, action, str(backup), "--json"], env=dict(os.environ, MONKEYSPAW_DATA_DIR=str(data)))
    else:
        name = "monkeyspaw-z17-admin-" + uuid.uuid4().hex
        try:
            result = json_output(["docker", "run", "--name", name,
                                  "--label", "monkeyspaw.sync-run=" + value["owner"],
                                  "--user", f"{os.getuid()}:{os.getgid()}",
                                  "--volume", f"{data}:/data", value["image"], action, "/data/" + backup.name, "--json"])
        finally:
            run_command(["docker", "rm", "--force", name], timeout=30)
    if action == "restore" and (not isinstance(result.get("previous_path"), str) or not result.get("database_id")):
        raise SmokeFailure("restore lacked recovery copy")
    return {"database_id": result["database_id"].lower()}


def sanitized_reports(source, destination):
    """Allow only numeric outcomes and the fixed full-corpus summary, never XML text."""
    totals = {"tests": 0, "failures": 0, "errors": 0, "skipped": 0}
    summaries = []
    content = []
    for path in sorted(Path(source).glob("**/TEST-*.xml")):
        suite = ET.parse(path).getroot()
        for key in totals:
            value = int(suite.get(key, "0"))
            if value < 0:
                raise SmokeFailure("invalid test counts")
            totals[key] += value
        for stream in suite.iter("system-out"):
            match = re.search(r"^Full semantic sync acceptance: (\d+) files / (\d+) cases / (\d+) actions / (\d+) expectations; pending 0\.$",
                              stream.text or "", re.MULTILINE)
            if match:
                summaries.append(dict(zip(("files", "cases", "actions", "expectations"), map(int, match.groups()))))
            for match in re.finditer(r"^Kotlin content semantic conformance: (\d+) cases / (\d+) files / (\d+) categories; .*; pending 0\.$",
                                     stream.text or "", re.MULTILINE):
                content.append(dict(zip(("cases", "files", "categories"), map(int, match.groups()))))
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps({"outcomes": totals, "sync": summaries, "content": content}, indent=2) + "\n")
    return totals, summaries


def smoke(command):
    if not command:
        raise SmokeFailure("runner command required")
    # Resolve both tools before provisioning anything. No shell command strings.
    command = [executable(command[0]), *command[1:]]
    docker = executable("docker")
    uid, gid = os.getuid(), os.getgid()
    if uid == 0 or gid == 0:
        raise SmokeFailure("non-root runner required")
    name = "monkeyspaw-android-sync-" + uuid.uuid4().hex
    image = name + ":ci"
    container_attempted = False
    image_attempted = False
    with tempfile.TemporaryDirectory(prefix="monkeyspaw-android-sync-") as directory:
        root = Path(directory)
        root.chmod(0o700)
        for child in ("data", "secrets", "devices"):
            path = root / child
            path.mkdir(mode=0o700)
            path.chmod(0o700)
        for user in ("admin", "alice", "bob"):
            private_file(root / "secrets" / user, secrets.token_hex(32))
        cleanup_failed = False
        try:
            image_attempted = True
            run_command([docker, "build", "--tag", image, "-f", "server/Dockerfile", "."], BUILD_TIMEOUT)
            container_attempted = True
            run_command([docker, "run", "--detach", "--name", name, "--user", f"{uid}:{gid}",
                         "--publish", "127.0.0.1::8080", "--volume", f"{root / 'data'}:/data",
                         "--volume", f"{root / 'secrets'}:/run/secrets:ro",
                         "--env", "MONKEYSPAW_ADMIN_PASSWORD_FILE=/run/secrets/admin", image])
            url = endpoint(docker, name)
            wait_healthy(docker, name, url)
            users = {}
            for user in ("alice", "bob"):
                value = json_output([docker, "exec", name, "/usr/local/bin/monkeyspaw-server", "user", "add", user,
                                     "--password-file", "/run/secrets/" + user, "--json"])
                if not isinstance(value, dict) or not isinstance(value.get("id"), str) or not ULID.fullmatch(value["id"]):
                    raise SmokeFailure("invalid created user")
                users[user] = {"id": value["id"], "password_file": str(root / "secrets" / user)}
            manifest = root / "manifest.json"
            private_file(manifest, json.dumps({"schema": 1, "root": str(root), "servers": {"main": {
                "url": url, "container": name, "data": str(root / "data"), "users": users}}}))
            env = dict(os.environ, MONKEYSPAW_SYNC_MANIFEST=str(manifest), MONKEYSPAW_REQUIRE_SYNC_SERVER="1")
            run_command(command, RUNNER_TIMEOUT, env=env)
        finally:
            failure_active = sys.exc_info()[0] is not None
            # Register names before start: a timed-out docker run may have created the container.
            if container_attempted:
                try:
                    owned = run_command([docker, "ps", "--all", "--quiet", "--filter", "label=monkeyspaw.sync-run=" + name], capture=True).decode().split()
                    if any(not re.fullmatch(r"[a-f0-9]{12,64}", child) for child in owned):
                        raise SmokeFailure("invalid owned container identity")
                    if owned:
                        run_command([docker, "rm", "--force", *owned], timeout=30)
                except SmokeFailure:
                    cleanup_failed = True
                try:
                    run_command([docker, "rm", "--force", name], timeout=30)
                except SmokeFailure:
                    cleanup_failed = True
            if image_attempted:
                try:
                    run_command([docker, "image", "rm", "--force", image], timeout=30)
                except SmokeFailure:
                    cleanup_failed = True
            if cleanup_failed:
                if not failure_active:
                    raise SmokeFailure("container or image cleanup failed")
                print("Android sync smoke: container or image cleanup failed", file=sys.stderr)


def main():
    def interrupted(_signum, _frame):
        raise SmokeFailure("smoke interrupted")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    command = sys.argv[1:]
    if command[:1] == ["--"]:
        command = command[1:]
    try:
        if command == ["--control"]:
            value = json.loads(sys.stdin.buffer.read(65537))
            result = admin_control(value) if value["action"] in ("backup", "restore") else database_control(value)
            print(json.dumps(result))
            return 0
        if command == ["--reports"]:
            sanitized_reports(ROOT / "android/core/build/test-results", ROOT / "android/core/build/reports/sync-acceptance.json")
            return 0
        if command == ["--verify-reports"]:
            destination = ROOT / "android/core/build/reports/sync-acceptance.json"
            totals, summaries = sanitized_reports(ROOT / "android/core/build/test-results", destination)
            report = json.loads(destination.read_text())
            files = sorted((ROOT / "spec/fixtures/sync").glob("*.json"))
            cases = sum(len(json.loads(file.read_text())["cases"]) for file in files)
            if (totals["tests"] == 0 or any(totals[key] for key in ("failures", "errors", "skipped")) or
                    len(summaries) != 1 or summaries[0]["files"] != len(files) or summaries[0]["cases"] != cases or
                    not report["content"] or any(item["categories"] != 10 for item in report["content"])):
                raise SmokeFailure("incomplete semantic acceptance reports")
            print("Android sync semantic ownership: PASS (content + sync)")
            return 0
        smoke(command)
    except SmokeFailure as failure:
        print("Android sync smoke: " + str(failure), file=sys.stderr)
        return 1
    except Exception:
        print("Android sync smoke: infrastructure failed", file=sys.stderr)
        return 1
    print("Android sync acceptance: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
