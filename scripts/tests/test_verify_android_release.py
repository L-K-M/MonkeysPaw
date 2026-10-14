"""Reject incorrect APK metadata, signer and checksum before artifact upload."""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
FINGERPRINT = "76a19df68d562789f6ea990b23232875b70a98c9996ba81e794ccab063edd765"


class AndroidReleaseVerificationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="monkeyspaw-verify-apk-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name) / "repo with spaces"
        for directory in ("scripts", "android/app", "MonkeysPaw.xcodeproj", "dist"):
            (self.root / directory).mkdir(parents=True)
        for name in ("check-version.py", "verify-android-release.py"):
            shutil.copy2(ROOT / "scripts" / name, self.root / "scripts" / name)
        (self.root / "README.md").write_text("<!-- version -->0.1.0<!-- /version -->\n")
        (self.root / "MonkeysPaw.xcodeproj/project.pbxproj").write_text("MARKETING_VERSION = 0.1.0;\n")
        self.gradle = self.root / "android/app/build.gradle.kts"
        self.gradle.write_text('versionName = "0.1.0"\nversionCode = 7\n')
        self.tools = self.root / "SDK directory/build-tools/36.0.0"
        self.tools.mkdir(parents=True)
        # Field names from the pinned build-tools 36.0.0 aapt2, including minSdkVersion.
        self.badging = "package: name='ch.lkmc.monkeyspaw' versionCode='7' versionName='0.1.0'\nminSdkVersion:'26'\ntargetSdkVersion:'37'\n"
        self.signature = f"Verifies\nSigner #1 certificate SHA-256 digest: {FINGERPRINT}\n"
        for tool, variable, arguments in (("aapt2", "FAKE_BADGING", "['dump', 'badging']"),
                                          ("apksigner", "FAKE_SIGNATURE", "['verify', '--verbose', '--print-certs']")):
            script = self.tools / tool
            script.write_text(f'''#!{sys.executable}
import os
from pathlib import Path
import sys
assert sys.argv[1:-1] == {arguments}
assert Path(sys.argv[-1]).is_absolute()
print(os.environ['{variable}'], end='')
sys.exit(int(os.environ.get('FAKE_{tool.upper()}_EXIT', '0')))
''')
            script.chmod(0o755)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("ANDROID_")}
        self.env.update(ANDROID_HOME=str(self.tools.parents[1]), FAKE_BADGING=self.badging,
                        FAKE_SIGNATURE=self.signature, PYTHONDONTWRITEBYTECODE="1", GITHUB_RUN_NUMBER="99999")
        self.stage("0.1.0")

    def stage(self, version):
        self.apk = self.root / f"dist/monkeyspaw-v{version}.apk"
        self.apk.write_bytes(b"signed fixture APK")
        self.manifest = self.apk.with_suffix(".apk.sha256")
        self.manifest.write_text(f"{hashlib.sha256(self.apk.read_bytes()).hexdigest()}  {self.apk.name}\n")

    def run_verifier(self, version="0.1.0", **environment):
        return subprocess.run([sys.executable, str(self.root / "scripts/verify-android-release.py"),
                               str(self.apk), version], cwd=self.root, env=self.env | environment,
                              capture_output=True, text=True)

    def assert_rejected(self, version="0.1.0", **environment):
        result = self.run_verifier(version, **environment)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("==> Verified", result.stdout)

    def test_stable_and_prerelease_use_committed_code_and_full_version(self):
        for version in ("0.1.0", "0.1.0-beta.1"):
            with self.subTest(version=version):
                self.stage(version)
                badging = self.badging.replace("versionName='0.1.0'", f"versionName='{version}'")
                result = self.run_verifier(version, FAKE_BADGING=badging)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(f"{version} (code 7)", result.stdout)
                self.assertIn(f"signer {FINGERPRINT}", result.stdout)

    def test_help_does_not_load_the_version_checker(self):
        checker = self.root / "scripts/check-version.py"
        for contents in (None, "raise AssertionError('Version checker loaded for help')\n"):
            with self.subTest(contents=contents):
                if contents is None:
                    checker.unlink()
                else:
                    checker.write_text(contents)
                result = subprocess.run([sys.executable, str(self.root / "scripts/verify-android-release.py"),
                                         "--help"], cwd=self.root, env=self.env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("usage:", result.stdout)

    def test_missing_or_invalid_version_checker_reports_a_cli_error(self):
        checker = self.root / "scripts/check-version.py"
        for contents in (None, "invalid syntax here\n"):
            with self.subTest(contents=contents):
                if contents is None:
                    checker.unlink()
                else:
                    checker.write_text(contents)
                result = self.run_verifier()
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertTrue(result.stderr.startswith("!! "), result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertNotIn("==> Verified", result.stdout)

    def test_wrong_or_invalid_release_version_is_rejected(self):
        for version in ("0.2.0", "v0.1.0", "0.1.0+build", "0.1.0-beta.01", "0.1", "0.1.0\n"):
            with self.subTest(version=version):
                self.assert_rejected(version)
        self.gradle.write_text('versionName = "0.1.0"\nversionCode = 2147483648\n')
        self.assert_rejected()

    def test_application_id_version_code_name_and_api_levels_must_match(self):
        for old, new in (("ch.lkmc.monkeyspaw", "other.app"), ("versionCode='7'", "versionCode='99999'"),
                         ("versionName='0.1.0'", "versionName='0.1.0-beta.1'"),
                         ("minSdkVersion:'26'", "minSdkVersion:'27'"), ("targetSdkVersion:'37'", "targetSdkVersion:'36'")):
            with self.subTest(old=old):
                self.assert_rejected(FAKE_BADGING=self.badging.replace(old, new))
        for badging in ("", self.badging + self.badging, self.badging.replace("versionCode='7'", "")):
            self.assert_rejected(FAKE_BADGING=badging)

    def test_signature_must_verify_and_match_exactly_one_recorded_signer(self):
        self.assert_rejected(FAKE_APKSIGNER_EXIT="1")
        for signature in ("", self.signature.replace(FINGERPRINT, "0" * 64),
                          self.signature + self.signature.replace("Signer #1", "Signer #2")):
            with self.subTest(signature=signature):
                self.assert_rejected(FAKE_SIGNATURE=signature)

    def test_changed_payload_wrong_manifest_name_duplicate_and_missing_checksum_are_rejected(self):
        original = self.manifest.read_text()
        self.apk.write_bytes(b"changed APK")
        self.assert_rejected()
        self.stage("0.1.0")
        for checksum in ("", original + original, original.replace(self.apk.name, "other.apk"),
                         original.replace(self.apk.name, f"./{self.apk.name}"), "0" * 64 + original[64:]):
            with self.subTest(checksum=checksum):
                self.manifest.write_text(checksum)
                self.assert_rejected()
        self.manifest.unlink()
        self.assert_rejected()

    def test_missing_empty_or_misnamed_apk_and_missing_sdk_tool_are_rejected(self):
        self.apk.write_bytes(b"")
        self.assert_rejected()
        self.apk.unlink()
        self.assert_rejected()
        self.stage("0.1.0")
        self.apk = self.apk.rename(self.apk.with_name("app-release.apk"))
        self.assert_rejected()
        self.stage("0.1.0")
        (self.tools / "aapt2").unlink()
        self.assert_rejected()
        self.assert_rejected(ANDROID_HOME="", ANDROID_SDK_ROOT="")

    def test_signer_constant_agrees_with_the_adr(self):
        adr = (ROOT / "docs/decisions/0001-android-zero-secret-signing.md").read_text()
        self.assertIn(":".join(FINGERPRINT[index:index + 2] for index in range(0, 64, 2)).upper(), adr)


if __name__ == "__main__":
    unittest.main()
