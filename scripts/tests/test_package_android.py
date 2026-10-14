"""Local Android packaging with fake wrapper/toolchains, without SDK downloads."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class AndroidPackagingTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="monkeyspaw-package-android-")
        self.addCleanup(directory.cleanup)
        self.fixture = Path(directory.name)
        self.root = self.fixture / "repo with spaces"
        self.bin = self.fixture / "bin"
        self.bin.mkdir()
        self.sdk = self.fixture / "SDK directory"
        self.jdk = self.fixture / "jdk"
        for path in ("scripts", "android/app", "android/gradle/wrapper", "MonkeysPaw.xcodeproj"):
            (self.root / path).mkdir(parents=True)
        for name in ("check-version.py", "package-android.sh", "build.sh"):
            shutil.copy2(ROOT / "scripts" / name, self.root / "scripts" / name)
        (self.root / "MonkeysPaw.xcodeproj/project.pbxproj").write_text(
            'MARKETING_VERSION = 0.1.0;\nMARKETING_VERSION = 0.1.0;\n')
        (self.root / "README.md").write_text('<!-- version -->0.1.0<!-- /version -->\n')
        self.gradle = self.root / "android/app/build.gradle.kts"
        self.gradle.write_text('versionName = "0.1.0"\nversionCode = 7\n')
        for file in ("gradle-wrapper.jar", "gradle-wrapper.properties"):
            (self.root / "android/gradle/wrapper" / file).write_text("fixture\n")
        platform = self.sdk / "platforms/android-37.0/android.jar"
        platform.parent.mkdir(parents=True)
        platform.write_text("fixture\n")
        self.executable(self.sdk / "build-tools/36.0.0/aapt2", '#!/bin/sh\nexit 0\n')
        self.executable(self.jdk / "bin/java", r'''#!/bin/sh
printf 'openjdk version "%s.0.0"\n' "${FAKE_JDK_VERSION:-21}" >&2
''')
        self.executable(self.jdk / "bin/javac", '#!/bin/sh\necho "javac ${FAKE_JDK_VERSION:-21}.0.0"\n')
        self.executable(self.bin / "uname", '#!/bin/sh\necho "${FAKE_HOST:-Linux}"\n')
        self.calls = self.fixture / "calls.json"
        self.executable(self.root / "android/gradlew", '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
Path(os.environ["FAKE_CALLS"]).write_text(json.dumps({"args": sys.argv[1:], "cwd": os.getcwd()}))
if os.environ.get("FAKE_FAILURE") == "gradle":
    sys.exit(42)
if os.environ.get("FAKE_FAILURE") != "missing-apk":
    apk = Path("app/build/outputs/apk/release/app-release.apk")
    apk.parent.mkdir(parents=True, exist_ok=True)
    apk.write_bytes(b"signed fixture APK")
''')
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("ANDROID_", "JAVA_", "LKM_", "BUILD_", "FAKE_"))}
        self.env.update(PATH=f"{self.bin}:{os.environ['PATH']}", JAVA_HOME=str(self.jdk),
                        ANDROID_HOME=str(self.sdk), FAKE_CALLS=str(self.calls),
                        SWIFT=str(self.fixture / "missing-swift"), PYTHONDONTWRITEBYTECODE="1",
                        LANG="C.UTF-8", LC_ALL="C.UTF-8")

    def executable(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755)

    def run_script(self, name, *args, **environment):
        return subprocess.run(["/bin/bash", str(self.root / "scripts" / name), *args],
                              cwd=self.fixture, env=self.env | environment,
                              capture_output=True, text=True)

    def assert_rejected_before_build(self, reason, **environment):
        result = self.run_script("build.sh", "android", **environment)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"android: FAILED ({reason}", result.stdout)
        self.assertFalse(self.calls.exists())
        self.assertFalse((self.root / "dist").exists())

    def test_stable_and_prerelease_packaging_wrapper_arguments_and_checksums(self):
        original = self.gradle.read_bytes()
        for arguments, version in (((), "0.1.0"), (("v0.1.0-beta.1",), "0.1.0-beta.1"),
                                   (("0.1.0-rc-1",), "0.1.0-rc-1")):
            with self.subTest(version=version):
                result = self.run_script("package-android.sh", *arguments, GITHUB_RUN_NUMBER="99999")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                calls = json.loads(self.calls.read_text())
                self.assertEqual(calls["cwd"], str(self.root / "android"))
                self.assertEqual(calls["args"],
                                 ["--max-workers=2", ":app:assembleRelease", f"-PreleaseVersion={version}",
                                  "-Pandroid.builder.sdkDownload=false"])
                artifact = f"monkeyspaw-v{version}.apk"
                apk = self.root / "dist" / artifact
                self.assertEqual(apk.read_bytes(), b"signed fixture APK")
                self.assertEqual(apk.with_suffix(".apk.sha256").read_text(),
                                 f"{hashlib.sha256(apk.read_bytes()).hexdigest()}  {artifact}\n")
                self.assertEqual(self.gradle.read_bytes(), original)

    def test_named_build_stages_apk_and_has_one_summary(self):
        result = self.run_script("build.sh", "android", "--no-open")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("android: ok (dist/)", result.stdout)
        self.assertEqual(result.stdout.count("\nSummary\n"), 1)
        self.assertTrue((self.root / "dist/monkeyspaw-v0.1.0.apk.sha256").exists())

    def test_missing_sdk_is_skipped_automatically_and_fails_when_named(self):
        environment = {"ANDROID_HOME": str(self.fixture / "absent-sdk")}
        result = self.run_script("build.sh", **environment)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("android: skipped (missing Android SDK", result.stdout)
        self.assertEqual(result.stdout.count("\nSummary\n"), 1)
        self.assert_rejected_before_build("missing Android SDK", **environment)

    def test_missing_wrapper_or_wrapper_files_fail_with_a_named_reason(self):
        for path, reason in (("android/gradlew", "missing executable Android wrapper"),
                             ("android/gradle/wrapper/gradle-wrapper.jar", "missing Android wrapper file"),
                             ("android/gradle/wrapper/gradle-wrapper.properties", "missing Android wrapper file")):
            file = self.root / path
            saved = file.read_bytes()
            mode = file.stat().st_mode
            file.unlink()
            with self.subTest(path=path):
                self.assert_rejected_before_build(reason)
            file.write_bytes(saved)
            file.chmod(mode)

    def test_missing_or_old_jdk_fails_before_wrapper(self):
        self.assert_rejected_before_build("requires JDK 17+", JAVA_HOME=str(self.fixture / "absent-jdk"))
        self.assert_rejected_before_build("requires JDK 17+", FAKE_JDK_VERSION="11")

    def test_missing_platform_and_build_tools_fail_before_wrapper(self):
        for path, reason in (("platforms/android-37.0/android.jar", "missing Android SDK platform"),
                             ("build-tools/36.0.0/aapt2", "missing Android SDK build tools")):
            file = self.sdk / path
            file.rename(file.with_suffix(".saved"))
            with self.subTest(path=path):
                self.assert_rejected_before_build(reason)
            file.with_suffix(".saved").rename(file)

    def test_check_validates_configuration_only_and_local_properties_match_gradle_precedence(self):
        sdk_path = str(self.sdk).replace(" ", "\\ ")
        # Gradle's Properties loader also accepts CRLF files written on Windows.
        for ending in ("\n", "\r\n"):
            with self.subTest(ending=repr(ending)):
                (self.root / "android/local.properties").write_bytes(f"sdk.dir={sdk_path}{ending}".encode())
                result = self.run_script("package-android.sh", "--check", ANDROID_HOME="/absent-sdk")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(self.calls.exists())
                self.assertFalse((self.root / "dist").exists())

    def test_bad_or_misaligned_package_versions_fail_before_wrapper(self):
        for version in ("", "0.1", "0.2.0", "0.2.0-beta.1", "0.1.0-beta.01", "0.1.0+build",
                        "0.1.0-beta.1+build", "0.1.0/other", "0.1.0\n", "00.1.0"):
            with self.subTest(version=version):
                result = self.run_script("package-android.sh", version)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.calls.exists())
                self.assertFalse((self.root / "dist").exists())

    def test_failed_gradle_or_missing_apk_never_stages_an_artifact(self):
        for failure in ("gradle", "missing-apk"):
            with self.subTest(failure=failure):
                self.calls.unlink(missing_ok=True)
                result = self.run_script("package-android.sh", FAKE_FAILURE=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(self.calls.exists())
                self.assertFalse((self.root / "dist").exists())

    def test_failure_does_not_replace_previously_staged_outputs(self):
        result = self.run_script("package-android.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        outputs = {path.name: path.read_bytes() for path in (self.root / "dist").iterdir()}
        result = self.run_script("package-android.sh", FAKE_FAILURE="gradle")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(outputs, {path.name: path.read_bytes() for path in (self.root / "dist").iterdir()})

    def test_checksum_failure_preserves_outputs_and_removes_temporary_staging(self):
        result = self.run_script("package-android.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        outputs = {path.name: path.read_bytes() for path in (self.root / "dist").iterdir()}
        temporary = self.fixture / "temporary"
        temporary.mkdir()
        self.executable(self.bin / "sha256sum", '#!/bin/sh\nexit 43\n')
        result = self.run_script("package-android.sh", TMPDIR=str(temporary))
        self.assertEqual(result.returncode, 43)
        self.assertEqual(outputs, {path.name: path.read_bytes() for path in (self.root / "dist").iterdir()})
        self.assertEqual(list(temporary.iterdir()), [])

    def test_one_target_failure_does_not_prevent_later_targets_building(self):
        result = self.run_script("build.sh", "deb", "android")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("deb: FAILED", result.stdout)
        self.assertIn("android: ok (dist/)", result.stdout)
        self.assertEqual(result.stdout.count("\nSummary\n"), 1)

    def test_app_path_preserves_xcode_engine_configuration_and_check_arguments(self):
        engine = self.bin / "fake-build"
        self.executable(engine, '''#!/usr/bin/env python3
import json
import os
import sys
print(json.dumps({"kind": os.environ["BUILD_KIND"], "project": os.environ["BUILD_XCODE_PROJECT"],
                  "scheme": os.environ["BUILD_XCODE_SCHEME"], "args": sys.argv[1:]}))
''')
        result = self.run_script("build.sh", "app", "--check", "--debug", LKM_BUILD_BIN=str(engine))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"kind": "xcode", "project": "MonkeysPaw.xcodeproj",
                                                   "scheme": "MonkeysPaw", "args": ["--check", "--debug"]})
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()
