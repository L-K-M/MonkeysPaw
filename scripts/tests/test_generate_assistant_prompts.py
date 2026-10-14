"""Both compiled catalogs must preserve the same source bytes without host-dependent output."""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/generate-assistant-prompts.py"
SWIFT = Path("Sources/MonkeysPawCore/Assistant/AssistantPrompts.generated.swift")
KOTLIN = Path("android/core/src/main/kotlin/ch/lkmc/monkeyspaw/core/llm/AssistantPrompts.generated.kt")
spec = importlib.util.spec_from_file_location("generate_assistant_prompts", SCRIPT)
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class AssistantPromptGeneratorTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="assistant-prompts-test-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.script = self.root / "scripts/generate-assistant-prompts.py"
        self.script.parent.mkdir()
        shutil.copyfile(SCRIPT, self.script)
        (self.root / SWIFT).parent.mkdir(parents=True)
        self.source = self.root / "Assistant/Prompts"
        self.source.mkdir(parents=True)
        # Deliberately create files in a different order from the catalog.
        self.prompts = {"improve": "é e\u0301 😀\u2028\u2029", "write": '" \\ $name ${name}\r\n\t\0\x7f', "review": ""}
        for name, content in self.prompts.items():
            (self.source / f"{name}.md").write_bytes(content.encode("utf-8"))

    def run_script(self, *arguments, seed="1"):
        return subprocess.run([sys.executable, str(self.script), *arguments], cwd=self.source,
                              env={**os.environ, "PYTHONHASHSEED": seed}, capture_output=True)

    def outputs(self):
        return {path: (self.root / path).read_bytes() for path in (SWIFT, KOTLIN)}

    def generate(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        return self.outputs()

    def test_shipped_swift_bytes_and_both_catalogs_are_current(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--stdout"], capture_output=True, check=True)
        self.assertEqual(result.stdout, (ROOT / SWIFT).read_bytes())
        result = subprocess.run([sys.executable, str(SCRIPT), "--check"], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_swift_escaping_stays_byte_identical(self):
        value = '" \\ $name ${name}\r\n\t\0\x7f\u2028\u2029é e\u0301 😀'
        self.assertEqual(generator.swift_string(value),
                         r'"\" \\ $name ${name}\r\n\t\u{0}\u{7f}\u{2028}\u{2029}é é 😀"')

    def test_kotlin_escaping_preserves_dollars_controls_and_supplementary_scalars(self):
        value = '" \\ $name ${name}\r\n\t\0\x7f\u2028\u2029é e\u0301 😀'
        self.assertEqual(generator.kotlin_string(value),
                         r'"\" \\ \$name \${name}\r\n\t\u0000\u007f\u2028\u2029é é \ud83d\ude00"')

    def test_both_outputs_are_deterministic_and_keep_source_order_and_line_endings(self):
        first = self.generate()
        self.assertIn(b'\\r\\n', first[SWIFT])
        self.assertIn(b'\\r\\n', first[KOTLIN])
        for name, content in reversed(tuple(self.prompts.items())):
            (self.source / f"{name}.md").unlink()
            (self.source / f"{name}.md").write_bytes(content.encode("utf-8"))
        result = self.run_script(seed="98765")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.outputs(), first)
        for data in first.values():
            self.assertLess(data.index(b"write:"), data.index(b"review:"))
            self.assertLess(data.index(b"review:"), data.index(b"improve:"))

    def test_stdout_is_only_swift_and_never_writes_catalogs(self):
        result = self.run_script("--stdout")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / SWIFT).exists())
        self.assertFalse((self.root / KOTLIN).exists())
        self.assertEqual(result.stdout, self.generate()[SWIFT])
        (self.root / KOTLIN).write_bytes(b"stale Kotlin\n")
        before = self.outputs()
        self.assertEqual(self.run_script("--stdout").stdout, before[SWIFT])
        self.assertEqual(self.outputs(), before)

    def test_check_accepts_current_catalogs_without_rewriting(self):
        before = self.generate()
        timestamps = {path: (self.root / path).stat().st_mtime_ns for path in before}
        result = self.run_script("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(self.outputs(), before)
        self.assertEqual({path: (self.root / path).stat().st_mtime_ns for path in before}, timestamps)

    def test_check_rejects_stale_or_missing_catalogs_without_repairing_them(self):
        expected = self.generate()
        for path in expected:
            for stale in (b"stale\n", expected[path].replace(b"\n", b"\r\n"), None):
                with self.subTest(path=path, missing=stale is None):
                    destination = self.root / path
                    if stale is None:
                        destination.unlink()
                    else:
                        destination.write_bytes(stale)
                    result = self.run_script("--check")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(str(path).encode(), result.stderr)
                    self.assertEqual(destination.read_bytes() if destination.exists() else None, stale)
                    destination.write_bytes(expected[path])

    def test_prompt_edit_stales_both_catalogs(self):
        before = self.generate()
        (self.source / "write.md").write_bytes(b"Changed\r\n")
        result = self.run_script("--check")
        self.assertNotEqual(result.returncode, 0)
        for path in before:
            self.assertIn(str(path).encode(), result.stderr)
        self.assertEqual(self.outputs(), before)

    def test_missing_source_directory_is_rejected(self):
        shutil.rmtree(self.source)
        result = subprocess.run([sys.executable, str(self.script)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"Missing prompt source directory", result.stderr)

    def test_missing_extra_hidden_and_directory_sources_are_rejected(self):
        before = self.generate()
        path = self.source / "review.md"
        path.unlink()
        self.assert_invalid(before, b"Expected exactly")
        path.write_bytes(b"")
        for name in ("extra.md", ".hidden"):
            extra = self.source / name
            extra.write_bytes(b"")
            self.assert_invalid(before, b"Expected exactly")
            extra.unlink()
        path.unlink()
        path.mkdir()
        self.assert_invalid(before, b"regular files")

    def test_symlink_sources_are_rejected(self):
        before = self.generate()
        path = self.source / "review.md"
        path.unlink()
        path.symlink_to("write.md")
        self.assert_invalid(before, b"not symlinks")

    def test_invalid_utf8_is_rejected_before_any_catalog_write(self):
        before = self.generate()
        (self.source / "improve.md").write_bytes(b"\xff")
        self.assert_invalid(before, b"not valid UTF-8")

    def assert_invalid(self, before, message):
        for arguments in ((), ("--check",), ("--stdout",)):
            result = self.run_script(*arguments)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)
            self.assertEqual(self.outputs(), before)


if __name__ == "__main__":
    unittest.main()
