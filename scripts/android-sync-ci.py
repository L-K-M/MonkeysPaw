#!/usr/bin/env python3
"""Z15 partial smoke: production Kotlin devices against this checkout's server image."""

import json
import os
from pathlib import Path
import re
import secrets
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid


ROOT = Path(__file__).resolve().parents[1]
COMMAND_TIMEOUT = 60
BUILD_TIMEOUT = 1200
RUNNER_TIMEOUT = 900
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
            # Also reap descendants left by an exited wrapper or inherited stdout pipe.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
            if process.stdout is not None:
                process.stdout.close()


def private_file(path, contents):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as file:
        os.fchmod(file.fileno(), 0o600)
        file.write(contents)


def json_output(arguments):
    try:
        return json.loads(run_command(arguments, capture=True))
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
            # Register names before start: a timed-out docker run may have created the container.
            if container_attempted:
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
                raise SmokeFailure("container or image cleanup failed")


def main():
    def interrupted(_signum, _frame):
        raise SmokeFailure("smoke interrupted")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    command = sys.argv[1:]
    if command[:1] == ["--"]:
        command = command[1:]
    try:
        smoke(command)
    except SmokeFailure as failure:
        print("Android sync smoke: " + str(failure), file=sys.stderr)
        return 1
    except Exception:
        print("Android sync smoke: infrastructure failed", file=sys.stderr)
        return 1
    print("Android sync smoke: PASS (Z15 round trip only)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
