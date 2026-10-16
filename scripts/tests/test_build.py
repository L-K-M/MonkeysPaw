"""Run the local orchestrator with recording packagers, without any builds."""

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
        for name in ("dirname", "basename", "rm", "mkdir", "sha256sum", "awk"):
            (self.bin / name).symlink_to(shutil.which(name))
        (self.bin / "python3").symlink_to(sys.executable)
        for name in ("swift", "dpkg-deb", "dpkg-shlibdeps", "readelf", "strip", "flatpak-builder", "pkg-config"):
            self.script(self.bin / name, "exit 0\n")
        self.script(self.bin / "uname", 'if [[ "$1" == -m ]]; then echo "${FAKE_ARCH:-x86_64}"; else echo Linux; fi\n')
        self.script(self.bin / "dpkg", "echo amd64\n")
        self.script(self.bin / "flatpak", '[[ "${FAKE_MISSING_RUNTIME:-}" != 1 ]]\n')
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
''')
        self.script(self.root / "scripts/build-flatpak.sh", '''
[[ "$1" == dist/monkeyspaw_0.2.0~rc~1_amd64.deb && "$2" == 0.2.0-rc-1 ]]
[[ "$(< "$1")" == 'fresh deb' ]] || exit 1
printf 'flatpak\n' >> "$BUILD_CALLS"
[[ "${FAKE_FLATPAK_FAILURE:-}" != 1 ]]
''')
        self.script(self.root / "scripts/package-android.sh", '''
if [[ "$1" == --check ]]; then
  [[ "${FAKE_ANDROID_AVAILABLE:-}" == 1 ]] || { echo '!! no Android SDK'; exit 1; }
else
  printf 'android\n' >> "$BUILD_CALLS"
fi
''')
        self.script(self.bin / "engine", 'printf "%s\\n" "$BUILD_APP_NAME" "$BUILD_KIND" "$BUILD_XCODE_SCHEME" "$@" > "$BUILD_CALLS"\n')
        self.env = os.environ | {"PATH": str(self.bin), "SWIFT": "swift",
                                 "BUILD_CALLS": str(self.root / "calls"), "LKM_BUILD_BIN": "engine"}

    def script(self, path, body, shebang=True):
        path.write_text(("#!/bin/bash\nset -euo pipefail\n" if shebang else "") + body)
        path.chmod(0o755)

    def run_build(self, *args, **env):
        return subprocess.run(["/bin/bash", "scripts/build.sh", *args], cwd=self.root,
                              env=self.env | env, capture_output=True, text=True)

    def calls(self):
        file = self.root / "calls"
        return file.read_text().splitlines() if file.exists() else []

    def test_default_builds_deb_and_flatpak_once_and_skips_unavailable_targets(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), ["deb", "flatpak"])
        self.assertIn("mac: skipped (requires macOS)", result.stdout)
        self.assertIn("android: skipped (no Android SDK)", result.stdout)

    def test_both_orders_and_duplicate_targets_build_the_deb_only_once(self):
        for args in (("deb", "flatpak", "deb"), ("flatpak", "deb", "flatpak"), ("flatpak",)):
            with self.subTest(args=args):
                (self.root / "calls").unlink(missing_ok=True)
                result = self.run_build(*args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.calls(), ["deb", "flatpak"])

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

    def test_named_mac_fails_clearly_on_linux_and_app_flags_are_forwarded(self):
        result = self.run_build("mac")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mac: FAILED (requires macOS)", result.stdout)
        result = self.run_build("app", "--debug", "--run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), ["MonkeysPaw", "xcode", "MonkeysPaw", "--debug", "--run"])


class FlatpakRepackTests(unittest.TestCase):
    def test_fake_command_suite(self):
        result = subprocess.run(["/bin/bash", str(ROOT / "scripts/tests/test-build-flatpak.sh")],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
