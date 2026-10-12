"""Release tags must describe the committed version before assets are built."""

from contextlib import redirect_stdout
import importlib.util
import io
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "check_version", Path(__file__).resolve().parents[1] / "check-version.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class ReleaseVersionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "MonkeysPaw.xcodeproj").mkdir()
        self.write_versions("0.1.0", "0.1.0", "0.1.0")

    def write_versions(self, debug, release, marker):
        (self.root / "MonkeysPaw.xcodeproj/project.pbxproj").write_text(
            f"MARKETING_VERSION = {debug};\nMARKETING_VERSION = {release};\n")
        (self.root / "README.md").write_text(
            f"v<!-- version -->{marker}<!-- /version -->\n")

    def check(self, tag):
        with redirect_stdout(io.StringIO()):
            checker.check_versions(self.root, tag)

    def test_committed_version_cli_prints_only_one_version_line(self):
        script = self.root / "scripts/check-version.py"
        script.parent.mkdir()
        shutil.copyfile(checker.__file__, script)

        result = subprocess.run(
            [sys.executable, str(script), "--committed-version"],
            capture_output=True, text=True, check=True)

        self.assertEqual(result.stdout, "0.1.0\n")
        self.assertEqual(result.stderr, "")

    def test_stable_and_prerelease_tags_match_numeric_version(self):
        for tag in ("v0.1.0", "v0.1.0-beta.1", "v0.1.0-rc-1"):
            with self.subTest(tag=tag):
                self.check(tag)

    def test_other_numeric_versions_fail_for_stable_and_prerelease(self):
        for tag in ("v0.0.9", "v0.1.1-beta.1", "v1.1.0"):
            with self.subTest(tag=tag), self.assertRaisesRegex(ValueError, "numeric core"):
                self.check(tag)

    def test_release_build_metadata_fails_before_packaging(self):
        for tag in ("v0.1.0+ci.1", "v0.1.0-beta.1+ci.1"):
            with self.subTest(tag=tag), self.assertRaisesRegex(ValueError, "build metadata"):
                self.check(tag)

    def test_every_project_configuration_must_match_marker(self):
        self.write_versions("0.1.0", "0.2.0", "0.1.0")
        with self.assertRaisesRegex(ValueError, "must agree"):
            self.check("v0.1.0")

    def test_readme_drift_fails_even_when_tag_matches_project(self):
        self.write_versions("0.1.0", "0.1.0", "0.2.0")
        with self.assertRaisesRegex(ValueError, "must agree"):
            self.check("v0.1.0")

    def test_duplicate_readme_markers_fail(self):
        with (self.root / "README.md").open("a") as readme:
            readme.write("<!-- version -->0.1.0<!-- /version -->\n")
        with self.assertRaisesRegex(ValueError, "must agree"):
            self.check("v0.1.0")

    def test_malformed_or_unprefixed_tags_fail(self):
        for tag in ("0.1.0", "v0.1", "v0.1.0-beta.01", "v0.1.0/other", "v01.1.0"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                self.check(tag)


if __name__ == "__main__":
    unittest.main()
