"""Run the local orchestrator with recording packagers, without any builds."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class BuildTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="monkeyspaw-build-test-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.root / "scripts").mkdir()
        (self.root / "packaging").mkdir()
        shutil.copy(ROOT / "scripts/build.sh", self.root / "scripts/build.sh")
        for name in ("dirname", "basename", "rm", "mkdir", "sha256sum", "awk", "sed", "tail", "tr"):
            (self.bin / name).symlink_to(shutil.which(name))
        self.script(self.bin / "id", 'if [[ "$1" == -u ]]; then echo "${FAKE_UID:-1000}"; else exit 1; fi\n')
        (self.bin / "python3").symlink_to(sys.executable)
        for name in ("swift", "dpkg-deb", "dpkg-shlibdeps", "readelf", "strip", "flatpak-builder", "pkg-config"):
            self.script(self.bin / name, "exit 0\n")
        self.script(self.bin / "uname", 'if [[ "$1" == -m ]]; then echo "${FAKE_ARCH:-x86_64}"; else echo "${FAKE_HOST:-Linux}"; fi\n')
        self.script(self.bin / "git", '''
[[ "${FAKE_GIT_FAILURE:-}" != 1 ]] || exit 1
case "$*" in
  'rev-parse HEAD') echo 0123456789abcdef0123456789abcdef01234567 ;;
  'show -s --format=%cI HEAD') echo 2026-10-15T12:34:56-07:00 ;;
  *) exit 1 ;;
esac
''')
        self.script(self.bin / "open", 'printf "open\\n" >> "$BUILD_CALLS"\n')
        self.script(self.bin / "dpkg", "echo amd64\n")
        self.script(self.bin / "flatpak", '''
if [[ "$1" == install ]]; then
  printf 'flatpak %s\n' "$*" >> "$BUILD_CALLS"
  [[ "${FAKE_INSTALL_FAILURE:-}" != 1 ]]
else
  [[ "${FAKE_MISSING_RUNTIME:-}" != 1 ]]
fi
''')
        self.script(self.bin / "sudo", '''
printf 'sudo %s\n' "$*" >> "$BUILD_CALLS"
[[ "${FAKE_INSTALL_FAILURE:-}" != 1 ]]
''')
        self.script(self.bin / "apt-get", "exit 0\n")
        sdk = self.root / "sdk"
        (sdk / "platform-tools").mkdir(parents=True)
        self.script(sdk / "platform-tools/adb", '''
printf 'adb %s\n' "$*" >> "$BUILD_CALLS"
if [[ "$1" == get-state ]]; then
  [[ "${FAKE_ADB_STATE:-device}" != none ]] || exit 1
  echo "${FAKE_ADB_STATE:-device}"
fi
''')
        self.script(self.root / "scripts/check-version.py", "\n".join((
            f"#!{sys.executable}", "import sys",
            'print("0.2.0-rc-1" if sys.argv[1] == "--committed-version" else sys.argv[2].replace("-", "~"))',
        )), shebang=False)
        self.script(self.root / "packaging/build-deb.sh", '''
printf 'deb\n' >> "$BUILD_CALLS"
[[ "${FAKE_DEB_FAILURE:-}" != 1 ]] || exit 1
[[ "${FAKE_DEB_NO_OUTPUT:-}" != 1 ]] || exit 0
mkdir -p dist
printf 'fresh deb' > dist/monkeyspaw_0.2.0~rc~1_amd64.deb
(cd dist && sha256sum monkeyspaw_0.2.0~rc~1_amd64.deb > monkeyspaw_0.2.0~rc~1_amd64.deb.sha256)
if [[ "${FAKE_DEB_BAD_CHECKSUM:-}" == 1 ]]; then
  printf 'changed after checksum' > dist/monkeyspaw_0.2.0~rc~1_amd64.deb
fi
''')
        self.script(self.root / "scripts/build-flatpak.sh", '''
[[ "$1" == dist/monkeyspaw_0.2.0~rc~1_amd64.deb && "$2" == 0.2.0-rc-1 ]]
[[ "$(< "$1")" == 'fresh deb' ]] || exit 1
printf 'flatpak\n' >> "$BUILD_CALLS"
[[ "${FAKE_FLATPAK_FAILURE:-}" != 1 ]]
printf 'bundle' > dist/monkeyspaw_0.2.0-rc-1_x86_64.flatpak
''')
        self.script(self.root / "scripts/package-android.sh", '''
if [[ "$1" == --check ]]; then
  [[ "${FAKE_ANDROID_AVAILABLE:-}" == 1 ]] || { echo '!! no Android SDK'; exit 1; }
else
  printf 'android\n' >> "$BUILD_CALLS"
  mkdir -p dist
  printf 'apk' > "dist/monkeyspaw-v$1.apk"
fi
''')
        self.script(self.bin / "engine", 'printf "%s\\n" "$BUILD_APP_NAME" "$BUILD_KIND" "$BUILD_XCODE_SCHEME" "$@" > "$BUILD_CALLS"\n')
        self.env = os.environ | {"PATH": str(self.bin), "SWIFT": "swift",
                                 "BUILD_CALLS": str(self.root / "calls"), "LKM_BUILD_BIN": "engine",
                                 "DOCKER_CALLS": str(self.root / "docker-calls"),
                                 "ANDROID_HOME": str(sdk)}
        self.env.pop("ANDROID_SDK_ROOT", None)

    def script(self, path, body, shebang=True):
        path.write_text(("#!/bin/bash\nset -euo pipefail\n" if shebang else "") + body)
        path.chmod(0o755)

    def run_build(self, *args, **env):
        return subprocess.run(["/bin/bash", "scripts/build.sh", *args], cwd=self.root,
                              env=self.env | env, capture_output=True, text=True)

    def calls(self):
        file = self.root / "calls"
        return file.read_text().splitlines() if file.exists() else []

    def install_docker(self):
        self.script(self.bin / "docker", f"#!{sys.executable}\n" + '''
import json
import os
import sys

args = sys.argv[1:]
with open(os.environ["DOCKER_CALLS"], "a") as file:
    file.write(json.dumps(args) + "\\n")
if args == ["info", "--format", "{{.OSType}}"]:
    if os.environ.get("FAKE_DOCKER_INFO_FAILURE") == "1":
        print("daemon connection error", file=sys.stderr)
        sys.exit(1)
    print(os.environ.get("FAKE_DOCKER_OS", "linux"))
elif args and args[0] == "build":
    with open(os.environ["BUILD_CALLS"], "a") as file:
        file.write("server-image\\n")
    sys.exit(1 if os.environ.get("FAKE_DOCKER_BUILD_FAILURE") == "1" else 0)
else:
    sys.exit(1)
''', shebang=False)

    def docker_calls(self):
        file = self.root / "docker-calls"
        return [json.loads(line) for line in file.read_text().splitlines()] if file.exists() else []

    def clear_calls(self):
        for name in ("calls", "docker-calls"):
            (self.root / name).unlink(missing_ok=True)

    def test_default_builds_deb_and_flatpak_once_and_skips_unavailable_targets(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), ["deb", "flatpak"])
        self.assertIn("mac: skipped (requires macOS)", result.stdout)
        self.assertIn("android: skipped (no Android SDK)", result.stdout)
        self.assertIn("server-image: skipped (missing docker", result.stdout)

    def test_server_image_metadata_output_and_duplicates_on_linux_and_darwin(self):
        self.install_docker()
        for host in ("Linux", "Darwin"):
            with self.subTest(host=host):
                self.clear_calls()
                result = self.run_build("server-image", "server-image", FAKE_HOST=host)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.calls(), ["server-image"])
                self.assertEqual(self.docker_calls(), [
                    ["info", "--format", "{{.OSType}}"],
                    ["build", "--load", "--tag", "monkeyspaw-server:0.2.0-rc-1",
                     "--build-arg", "VERSION=0.2.0-rc-1",
                     "--build-arg", "REVISION=0123456789abcdef0123456789abcdef01234567",
                     "--build-arg", "CREATED=2026-10-15T12:34:56-07:00",
                     "-f", "server/Dockerfile", "."],
                ])
                self.assertIn("server-image: ok (Docker image: monkeyspaw-server:0.2.0-rc-1)", result.stdout)
                self.assertFalse((self.root / "dist").exists())

    def test_default_builds_server_image_and_preserves_host_targets(self):
        self.install_docker()
        for host, expected in (("Linux", ["deb", "flatpak", "server-image"]),
                               ("Darwin", ["server-image"])):
            with self.subTest(host=host):
                self.clear_calls()
                result = self.run_build(FAKE_HOST=host)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.calls(), expected)
                self.assertIn("server-image: ok (Docker image:", result.stdout)
                if host == "Darwin":
                    self.assertIn("deb: skipped (requires Linux)", result.stdout)
                    self.assertIn("flatpak: skipped (requires Linux)", result.stdout)
                    # A local dmg falls back to hdiutil; only CI needs create-dmg.
                    self.assertNotIn("create-dmg", result.stdout)

    def test_missing_docker_skips_defaults_and_fails_named_target_on_both_hosts(self):
        for host in ("Linux", "Darwin"):
            for args, status in (((), 0), (("server-image",), 1)):
                with self.subTest(host=host, args=args):
                    self.clear_calls()
                    result = self.run_build(*args, FAKE_HOST=host)
                    self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                    outcome = "skipped" if not args else "FAILED"
                    self.assertIn(f"server-image: {outcome} (missing docker", result.stdout)
                    self.assertNotIn("server-image", self.calls())
                    self.assertEqual(self.docker_calls(), [])

    def test_unusable_docker_skips_defaults_and_fails_named_target_on_both_hosts(self):
        self.install_docker()
        for env, reason in (({"FAKE_DOCKER_INFO_FAILURE": "1"}, "docker info failed"),
                            ({"FAKE_DOCKER_OS": "windows"}, "requires a Linux Docker engine")):
            for host in ("Linux", "Darwin"):
                for args, status in (((), 0), (("server-image",), 1)):
                    with self.subTest(env=env, host=host, args=args):
                        self.clear_calls()
                        result = self.run_build(*args, FAKE_HOST=host, **env)
                        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                        outcome = "skipped" if not args else "FAILED"
                        self.assertIn(f"server-image: {outcome}", result.stdout)
                        self.assertIn(reason, result.stdout)
                        self.assertNotIn("server-image", self.calls())
                        self.assertEqual(self.docker_calls(), [["info", "--format", "{{.OSType}}"]])

    def test_server_image_and_flatpak_dependencies_build_once_in_either_order(self):
        self.install_docker()
        for args, expected in (
            (("server-image", "flatpak", "deb", "server-image"), ["server-image", "deb", "flatpak"]),
            (("flatpak", "server-image", "deb", "flatpak"), ["deb", "flatpak", "server-image"]),
        ):
            with self.subTest(args=args):
                self.clear_calls()
                result = self.run_build(*args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.calls(), expected)
                self.assertEqual(len(self.docker_calls()), 2)

    def test_server_image_failure_summary_and_status_preserve_other_targets(self):
        self.install_docker()
        for host in ("Linux", "Darwin"):
            for args in ((), ("server-image", "android")):
                with self.subTest(host=host, args=args):
                    self.clear_calls()
                    result = self.run_build(*args, "--no-open", FAKE_HOST=host,
                                            FAKE_DOCKER_BUILD_FAILURE="1", FAKE_ANDROID_AVAILABLE="1")
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn("server-image: FAILED", result.stdout.split("Summary\n")[1])
                    self.assertIn("android: ok (dist/)", result.stdout)
                    self.assertEqual(self.calls().count("server-image"), 1)
                    self.assertIn("android", self.calls())

    def test_missing_git_fails_named_target_clearly_and_metadata_failure_prevents_build(self):
        self.install_docker()
        result = self.run_build("server-image", FAKE_GIT_FAILURE="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("server-image: FAILED", result.stdout)
        self.assertEqual(self.calls(), [])
        (self.bin / "git").unlink()
        result = self.run_build("server-image")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("server-image: FAILED (missing git", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_both_orders_and_duplicate_targets_build_the_deb_only_once(self):
        for args in (("deb", "flatpak", "deb"), ("flatpak", "deb", "flatpak"), ("flatpak",)):
            with self.subTest(args=args):
                (self.root / "calls").unlink(missing_ok=True)
                result = self.run_build(*args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.calls(), ["deb", "flatpak"])

    def test_default_skips_an_unavailable_flatpak_without_rebuilding_deb(self):
        (self.bin / "flatpak-builder").unlink()
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), ["deb"])
        self.assertIn("flatpak: skipped (missing flatpak-builder)", result.stdout)

    def test_named_unavailable_runtime_architecture_and_tool_fail_without_building(self):
        for env, reason in (({"FAKE_MISSING_RUNTIME": "1"}, "GNOME 50"),
                            ({"FAKE_ARCH": "aarch64"}, "requires x86_64")):
            result = self.run_build("flatpak", **env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(reason, result.stdout)
            self.assertEqual(self.calls(), [])
        (self.bin / "flatpak-builder").unlink()
        result = self.run_build("flatpak")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing flatpak-builder", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_failed_or_no_output_deb_never_reuses_stale_artifacts_or_retries(self):
        for failure in ("FAKE_DEB_FAILURE", "FAKE_DEB_NO_OUTPUT"):
            with self.subTest(failure=failure):
                dist = self.root / "dist"
                dist.mkdir(exist_ok=True)
                for suffix in (".deb", ".deb.sha256"):
                    (dist / ("monkeyspaw_0.2.0~rc~1_amd64" + suffix)).write_text("stale")
                (self.root / "calls").unlink(missing_ok=True)
                result = self.run_build("flatpak", "deb", **{failure: "1"})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), ["deb"])
                self.assertEqual(list(dist.iterdir()), [])

    def test_flatpak_failure_propagates_and_android_still_runs(self):
        result = self.run_build("flatpak", "android", FAKE_FLATPAK_FAILURE="1", FAKE_ANDROID_AVAILABLE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), ["deb", "flatpak", "android"])

    def test_corrupt_fresh_deb_cannot_reach_the_repacker(self):
        result = self.run_build("flatpak", FAKE_DEB_BAD_CHECKSUM="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), ["deb"])

    def test_named_mac_fails_clearly_on_linux_and_app_flags_are_forwarded(self):
        result = self.run_build("mac")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mac: FAILED (requires macOS)", result.stdout)
        result = self.run_build("app", "--debug", "--run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), ["MonkeysPaw", "xcode", "MonkeysPaw", "--debug", "--run"])

    def test_install_puts_the_deb_on_linux_and_never_a_second_route(self):
        deb_install = "sudo apt-get install -y --reinstall ./dist/monkeyspaw_0.2.0~rc~1_amd64.deb"
        for args in (("--install",), ("flatpak", "deb", "--install")):
            with self.subTest(args=args):
                self.clear_calls()
                result = self.run_build(*args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.calls(), ["deb", "flatpak", deb_install])
                self.assertIn("install deb: ok (apt-get)", result.stdout)
                self.assertIn("install flatpak: skipped (deb is also targeted", result.stdout)

    def test_install_flatpak_alone_installs_the_user_bundle(self):
        result = self.run_build("flatpak", "--install")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [
            "deb", "flatpak",
            "flatpak install --user --assumeyes --reinstall --bundle dist/monkeyspaw_0.2.0-rc-1_x86_64.flatpak",
        ])
        self.assertIn("install flatpak: ok (flatpak --user)", result.stdout)

    def test_install_android_uses_the_sdk_adb_on_one_ready_device(self):
        result = self.run_build("android", "--install", FAKE_ANDROID_AVAILABLE="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [
            "android", "adb get-state", "adb install -r dist/monkeyspaw-v0.2.0-rc-1.apk",
        ])
        self.assertIn("install android: ok (adb)", result.stdout)

    def test_install_android_prefers_the_local_properties_sdk(self):
        sdk = self.root / "local sdk"
        (sdk / "platform-tools").mkdir(parents=True)
        self.script(sdk / "platform-tools/adb", '''
printf 'local-adb %s\n' "$1" >> "$BUILD_CALLS"
[[ "$1" != get-state ]] || echo device
''')
        (self.root / "android").mkdir()
        escaped = str(sdk).replace(":", "\\:")
        (self.root / "android/local.properties").write_bytes(f"sdk.dir = {escaped}\r\n".encode())
        result = self.run_build("android", "--install", FAKE_ANDROID_AVAILABLE="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), ["android", "local-adb get-state", "local-adb install"])

        # An sdk.dir without platform-tools falls through to ANDROID_HOME.
        self.clear_calls()
        (sdk / "platform-tools/adb").unlink()
        result = self.run_build("android", "--install", FAKE_ANDROID_AVAILABLE="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls()[1], "adb get-state")

    def test_install_failures_fail_the_run_after_every_build(self):
        result = self.run_build("android", "deb", "--install", FAKE_ANDROID_AVAILABLE="1", FAKE_ADB_STATE="none")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn("adb install -r dist/monkeyspaw-v0.2.0-rc-1.apk", self.calls())
        self.assertIn("install android: FAILED (no single ready device", result.stdout)
        self.assertIn("install deb: ok (apt-get)", result.stdout)

        self.clear_calls()
        result = self.run_build("deb", "--install", FAKE_INSTALL_FAILURE="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("install deb: FAILED (apt-get install failed)", result.stdout)

        self.clear_calls()
        (self.bin / "sudo").unlink()
        result = self.run_build("deb", "--install")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.calls(), ["deb"])
        self.assertIn("install deb: FAILED (missing sudo", result.stdout)

        # root needs no sudo: apt-get runs directly.
        self.clear_calls()
        self.script(self.bin / "apt-get", 'printf "apt-get %s\\n" "$*" >> "$BUILD_CALLS"\n')
        result = self.run_build("deb", "--install", FAKE_UID="0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), ["deb", "apt-get install -y --reinstall ./dist/monkeyspaw_0.2.0~rc~1_amd64.deb"])

    def test_install_skips_failed_builds_and_points_the_server_to_update(self):
        self.install_docker()
        result = self.run_build("deb", "server-image", "--install", FAKE_DEB_FAILURE="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.calls(), ["deb", "server-image"])
        self.assertNotIn("install deb", result.stdout)
        self.assertIn("install server-image: skipped (deploy the server with ./update.sh)", result.stdout)

    def test_app_engine_keeps_its_install_flag_and_other_app_flags_still_redirect(self):
        result = self.run_build("app", "--install")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), ["MonkeysPaw", "xcode", "MonkeysPaw", "--install"])
        result = self.run_build("--run")
        self.assertEqual(result.returncode, 2)
        self.assertIn("belongs to the app engine", result.stderr)


class FlatpakRepackTests(unittest.TestCase):
    def test_fake_command_suite(self):
        result = subprocess.run(["/bin/bash", str(ROOT / "scripts/tests/test-build-flatpak.sh")],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
