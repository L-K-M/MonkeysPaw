"""Android bump safety and the installed release engine's disposable integration."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
ENGINE = shutil.which("lkm-release")


class AndroidVersionFixture(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="monkeyspaw-version-")
        self.addCleanup(directory.cleanup)
        self.fixture = Path(directory.name)
        self.root = self.fixture / "repo"
        self.bin = self.fixture / "bin"
        self.bin.mkdir()
        (self.root / "scripts").mkdir(parents=True)
        (self.root / "android/app").mkdir(parents=True)
        (self.root / "MonkeysPaw.xcodeproj").mkdir()
        for name in ("check-version.py", "sync-android-version.sh", "release.sh"):
            shutil.copy2(ROOT / "scripts" / name, self.root / "scripts" / name)
        self.gradle = self.root / "android/app/build.gradle.kts"
        self.gradle.write_text('    versionName = "0.1.0"\n    versionCode = 1\n')
        (self.root / "README.md").write_text('<!-- version -->0.1.0<!-- /version -->\n')
        (self.root / "MonkeysPaw.xcodeproj/project.pbxproj").write_text(
            'MARKETING_VERSION = 0.1.0;\nMARKETING_VERSION = 0.1.0;\n')
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("RELEASE_", "LKM_", "GIT_"))}
        self.env.update(PATH=f"{self.bin}:{os.environ['PATH']}",
                        PYTHONDONTWRITEBYTECODE="1", GIT_CONFIG_GLOBAL="/dev/null",
                        GIT_CONFIG_NOSYSTEM="1", LANG="C.UTF-8", LC_ALL="C.UTF-8")

    def run_script(self, name, *args, **environment):
        return subprocess.run(["/bin/bash", str(self.root / "scripts" / name), *args],
                              cwd=self.root, env=self.env | environment,
                              capture_output=True, text=True)

    def hook(self, version=None):
        environment = {} if version is None else {"RELEASE_NEW_VERSION": version}
        return self.run_script("sync-android-version.sh", **environment)

    def executable(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)
        return str(path)


class AndroidVersionHookTests(AndroidVersionFixture):
    def test_each_changed_version_increments_once_and_aligned_retry_is_untouched(self):
        self.env["GITHUB_RUN_NUMBER"] = "999999"
        for version, code in (("0.2.0", 2), ("0.2.1", 3)):
            result = self.hook(version)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.gradle.read_text(),
                             f'    versionName = "{version}"\n    versionCode = {code}\n')
            before = self.gradle.stat()
            result = self.hook(version)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.gradle.stat(), before)

    def test_missing_and_malformed_new_versions_do_not_change_any_bytes(self):
        original = self.gradle.read_bytes()
        for version in (None, "", "0.2", "v0.2.0", "0.2.0-beta.1", "0.2.0+build",
                        "00.2.0", "0.2.0\n", " 0.2.0", "0.2.0; touch unwanted"):
            with self.subTest(version=version):
                result = self.hook(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.gradle.read_bytes(), original)
                self.assertEqual(list(self.gradle.parent.glob(".version-*")), [])

    def test_unique_literal_declarations_and_valid_existing_values_are_required(self):
        original = self.gradle.read_text()
        for text in (original + 'versionName = "0.1.0"\n', original + 'versionCode = 2\n',
                     original + 'versionCode = provider.get()\n',
                     original.replace('versionName = "0.1.0"', '// versionName = "0.1.0"'),
                     original.replace('versionCode = 1', '// versionCode = 1'),
                     original.replace('"0.1.0"', '"0.1.0-beta.1"'),
                     original.replace('"0.1.0"', 'provider.get()'),
                     *(original.replace('versionCode = 1', f'versionCode = {value}')
                       for value in ("0", "-1", "01", "1.0", "1 + 2", "2147483648",
                                     'System.getenv("GITHUB_RUN_NUMBER")'))):
            self.gradle.write_text(text)
            with self.subTest(text=text):
                result = self.hook("0.2.0")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.gradle.read_text(), text)

    def test_overflow_leaves_both_values_untouched_but_aligned_maximum_is_valid(self):
        text = 'versionCode = 2147483647\nversionName = "0.1.0"\n'
        self.gradle.write_text(text)
        self.assertNotEqual(self.hook("0.2.0").returncode, 0)
        self.assertEqual(self.gradle.read_text(), text)
        before = self.gradle.stat()
        self.assertEqual(self.hook("0.1.0").returncode, 0)
        self.assertEqual(self.gradle.stat(), before)

    def test_replacement_preserves_comments_permissions_order_and_crlf(self):
        text = (b'// versionName = "9.9.9"\r\n'
                b'\tversionCode  = 9999 // committed code\r\n'
                b'\tversionName = "0.1.0"  // numeric version\r\n')
        self.gradle.write_bytes(text)
        self.gradle.chmod(0o640)
        result = self.hook("0.2.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.gradle.read_bytes(), text.replace(b'9999', b'10000')
                         .replace(b'"0.1.0"', b'"0.2.0"'))
        self.assertEqual(self.gradle.stat().st_mode & 0o777, 0o640)

    def test_symlink_is_rejected_without_changing_target(self):
        target = self.fixture / "target"
        original = self.gradle.read_bytes()
        self.gradle.rename(target)
        self.gradle.symlink_to(target)
        self.assertNotEqual(self.hook("0.2.0").returncode, 0)
        self.assertTrue(self.gradle.is_symlink())
        self.assertEqual(target.read_bytes(), original)

    def test_stub_exports_xcode_hook_and_fake_engine_supplies_new_version(self):
        engine = self.executable("fake-release", '''#!/usr/bin/env bash
set -euo pipefail
[[ "$RELEASE_KIND" == xcode && "$RELEASE_XCODE_PROJECT" == MonkeysPaw.xcodeproj ]]
[[ "$RELEASE_XCODE_SCHEME" == MonkeysPaw && "$RELEASE_POST_BUMP" == scripts/sync-android-version.sh ]]
if [[ "$1" == --check ]]; then echo "config only: $RELEASE_POST_BUMP"; exit 0; fi
RELEASE_NEW_VERSION="$1" bash -c "$RELEASE_POST_BUMP"
''')
        before = self.gradle.read_bytes()
        result = self.run_script("release.sh", "--check", LKM_RELEASE_BIN=engine)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("config only", result.stdout)
        self.assertEqual(self.gradle.read_bytes(), before)
        result = self.run_script("release.sh", "0.2.0", LKM_RELEASE_BIN=engine)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('versionName = "0.2.0"', self.gradle.read_text())
        self.assertIn('versionCode = 2', self.gradle.read_text())


@unittest.skipUnless(ENGINE, "installed lkm-release required for disposable integration")
class InstalledReleaseEngineTests(AndroidVersionFixture):
    def setUp(self):
        super().setUp()
        self.env["LKM_RELEASE_BIN"] = ENGINE
        self.executable("xcodebuild", '''#!/usr/bin/env python3
from pathlib import Path
import re
text = Path("MonkeysPaw.xcodeproj/project.pbxproj").read_text()
print("    MARKETING_VERSION = " + re.search(r"MARKETING_VERSION = ([^;]+);", text)[1])
''')

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, env=self.env,
                              capture_output=True, text=True, check=True).stdout.strip()

    def seed_repository(self):
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Release fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")
        self.git("add", ".")
        self.git("commit", "-m", "Seed fixture")

    def test_hook_edits_are_in_the_release_commit_and_annotated_tag(self):
        self.seed_repository()
        result = self.run_script("release.sh", "0.2.0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("rev-list", "--count", "HEAD"), "2")
        self.assertEqual(self.git("cat-file", "-t", "refs/tags/v0.2.0"), "tag")
        self.assertEqual(self.git("rev-parse", "v0.2.0^{}"), self.git("rev-parse", "HEAD"))
        self.assertIn('versionName = "0.2.0"', self.git("show", "v0.2.0:android/app/build.gradle.kts"))
        self.assertIn('versionCode = 2', self.git("show", "v0.2.0:android/app/build.gradle.kts"))
        self.assertIn("<!-- version -->0.2.0<!-- /version -->", self.git("show", "HEAD:README.md"))
        self.assertIn("MARKETING_VERSION = 0.2.0;", self.git("show", "HEAD:MonkeysPaw.xcodeproj/project.pbxproj"))
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_aligned_version_tags_without_an_extra_commit_or_code_increment(self):
        self.seed_repository()
        result = self.run_script("release.sh", "0.1.0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("rev-list", "--count", "HEAD"), "1")
        self.assertIn('versionCode = 1', self.git("show", "v0.1.0:android/app/build.gradle.kts"))
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_check_only_reports_configuration_even_when_hook_would_fail(self):
        self.gradle.write_text('versionName = invalid\n')
        self.seed_repository()
        before = self.git("rev-parse", "HEAD")
        result = self.run_script("release.sh", "--check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("post-bump: scripts/sync-android-version.sh", result.stdout)
        self.assertEqual(self.git("rev-parse", "HEAD"), before)
        self.assertEqual(self.git("tag", "--list"), "")
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_hook_failure_rolls_back_desktop_bump_without_commit_or_tag(self):
        for version, text in (("0.2.0", 'versionName = "0.1.0"\nversionCode = 2147483647\n'),
                              ("0.2", 'versionName = "0.1.0"\nversionCode = 1\n')):
            with self.subTest(version=version):
                self.gradle.write_text(text)
                if not (self.root / ".git").exists():
                    self.seed_repository()
                else:
                    self.git("add", ".")
                    self.git("commit", "-m", "Change fixture")
                before = self.git("rev-parse", "HEAD")
                result = self.run_script("release.sh", version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("RELEASE_POST_BUMP failed", result.stderr)
                self.assertEqual(self.git("rev-parse", "HEAD"), before)
                self.assertEqual(self.git("status", "--porcelain"), "")
                self.assertEqual(self.git("tag", "--list"), "")
                self.assertEqual(self.gradle.read_text(), text)
                self.assertIn("MARKETING_VERSION = 0.1.0;",
                              (self.root / "MonkeysPaw.xcodeproj/project.pbxproj").read_text())


if __name__ == "__main__":
    unittest.main()
