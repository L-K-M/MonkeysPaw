"""CI selection must never omit a consumer or silently accept a failed diff."""

import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci-changes.py"
spec = importlib.util.spec_from_file_location("ci_changes", SCRIPT)
changes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(changes)

ALL = frozenset({
    "core-linux", "linux-app", "deb", "flatpak", "android", "android-sync", "core-macos", "macos-app",
    "macos-artifacts", "server", "server-image", "compose-smoke",
})
SWIFT = ALL - {"android", "android-sync"}
LINUX = frozenset({"linux-app", "deb"})
MACOS = frozenset({"macos-app", "macos-artifacts"})
SERVER = frozenset({"server", "server-image", "compose-smoke", "android-sync"})


def with_flatpak(jobs):
    """The Flatpak job repacks the deb, so any deb selection includes it."""
    return jobs | {"flatpak"} if "deb" in jobs else jobs


class SelectionTests(unittest.TestCase):
    def test_full_sync_acceptance_selects_both_engines_server_and_fixture_inputs(self):
        for path in ("android/core/src/main/kotlin/ch/lkmc/monkeyspaw/core/services/SyncEngine.kt",
                     "android/core/src/syncIntegrationTest/kotlin/ch/lkmc/monkeyspaw/core/integration/ScenarioDeviceProcess.kt",
                     "Sources/MonkeysPawCore/Sync/SyncService.swift", "Tests/MonkeysPawCoreTests/SyncTests.swift",
                     "server/Tests/MonkeysPawSyncIntegrationTests/SyncCrashScenarioTests.swift",
                     "server/Sources/MonkeysPawServer/Services/RetentionService.swift", "spec/fixtures/sync/17-crash-apply.json"):
            self.assertIn("android-sync", changes.select_jobs("pull_request", [path]), path)

    def test_acceptance_workflow_requires_semantic_aggregate_and_only_numeric_artifacts(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        job = workflow.split("  android-sync:\n", 1)[1].split("\n  core-macos:", 1)[0]
        self.assertIn(":core:test :core:syncIntegrationTest --no-daemon --max-workers=2", job)
        self.assertIn("scripts/android-sync-ci.py --verify-reports", job)
        self.assertIn("path: android/core/build/reports/sync-acceptance.json", job)
        self.assertNotIn("continue-on-error", job)
        self.assertNotIn("*.xml", job)

    def test_path_rules(self):
        cases = {
            "Package.swift": SWIFT | {"android-sync"},
            "Package.resolved": SWIFT | {"android-sync"},
            "Sources/MonkeysPawCore/Domain/Prompt.swift": SWIFT | {"android-sync"},
            "Sources/MonkeysPawCore/Sync/SyncPathCaseFold.swift": ALL,
            "Tests/MonkeysPawCoreTests/PromptTests.swift": SWIFT | {"android-sync"},
            "Assistant/Prompts/write.md": ALL,
            "Assistant/Prompts/review.md": ALL,
            "Assistant/Prompts/improve.md": ALL,
            "spec/fixtures/valid.md": ALL,
            "spec/schema/prompt.json": ALL,
            "seed/example.md": ALL,
            "Sources/CGtk/module.modulemap": LINUX | SERVER | {"core-linux"},
            "Sources/MonkeysPawLinux/App.swift": LINUX | SERVER | {"core-linux"},
            "Sources/monkeyspaw/main.swift": LINUX | SERVER | {"core-linux"},
            "Tests/MonkeysPawLinuxTests/AppTests.swift": LINUX,
            "packaging/build-deb.sh": LINUX,
            "packaging/linux/ch.lkmc.monkeyspaw.desktop": LINUX,
            "packaging/debian/copyright": LINUX,
            "packaging/icons/hicolor/16x16/apps/ch.lkmc.monkeyspaw.png": LINUX,
            "packaging/macos/background.png": MACOS,
            "MonkeysPaw/AppDelegate.swift": MACOS,
            "MonkeysPaw/Resources/Assets.xcassets/Contents.json": MACOS,
            "MonkeysPaw/Resources/WishPaw/wish-paw-00@2x.png": LINUX | MACOS,
            "MonkeysPawTests/PanelTests.swift": MACOS,
            "MonkeysPaw.xcodeproj/project.pbxproj": MACOS | {"core-linux", "deb"},
            "MonkeysPaw.xcodeproj/xcshareddata/xcschemes/MonkeysPaw.xcscheme":
                MACOS | {"core-linux", "deb"},
            "server/Package.swift": SERVER,
            "server/Dockerfile": SERVER,
            "server/Sources/MonkeysPawServer/Routes/Health.swift": SERVER,
            "server/Tests/MonkeysPawServerTests/HealthTests.swift": SERVER,
            "compose.yaml": SERVER,
            ".env.example": SERVER,
            "deploy/nginx-proxy-manager/compose.override.yaml.example": SERVER,
            ".dockerignore": frozenset({"server-image", "compose-smoke", "android-sync"}),
            "update.sh": SERVER | {"deb"},
            "media-sources/icon.png": LINUX | MACOS,
            "media-sources/paw-symbol.svg": MACOS | {"android", "android-sync"},
            "media-sources/paw/render-paw.c": frozenset(),
            "media-sources/paw/preview.c": frozenset(),
            "android/app/src/main/AndroidManifest.xml": frozenset({"android", "android-sync"}),
            "android/core/build.gradle.kts": frozenset({"android", "android-sync"}),
            "android/app/build.gradle.kts": frozenset({"android", "android-sync", "core-linux", "deb"}),
            "android/core/src/main/kotlin/ch/lkmc/monkeyspaw/core/llm/AssistantPrompts.generated.kt":
                frozenset({"android", "android-sync", "core-linux"}),
            "scripts/sync-android-version.sh": frozenset({"core-linux", "android"}),
            "scripts/check-pbxproj.py": frozenset({"core-linux"}),
            "scripts/check-version.py": frozenset({"core-linux", "deb", "android"}),
            "scripts/linux-delivery-smoke.sh": frozenset({"linux-app"}),
            "scripts/package-macos.sh": frozenset({"macos-artifacts"}),
            "scripts/make-icons.sh": MACOS,
            "scripts/generate-paw-icon.py": MACOS | {"android", "android-sync"},
            "scripts/make-linux-icons.sh": frozenset({"deb"}),
            "scripts/build.sh": frozenset({"core-linux", "deb", "macos-artifacts", "android"}),
            "scripts/package-android.sh": frozenset({"core-linux", "android"}),
            "scripts/verify-android-release.py": frozenset({"core-linux", "android"}),
            "scripts/release.sh": ALL,
            "scripts/generate-seeds.py": SWIFT,
            "scripts/generate-assistant-prompts.py": ALL,
            "scripts/tests/test_generate_assistant_prompts.py": frozenset({"core-linux"}),
            "scripts/generate-kotlin-sync-fold.py": frozenset({"android", "android-sync"}),
            "scripts/android-sync-ci.py": frozenset({"core-linux", "android-sync"}),
            "scripts/tests/test_android_sync_ci.py": frozenset({"core-linux", "android-sync"}),
            "android/app/src/main/kotlin/ch/lkmc/monkeyspaw/data/OkHttpHttpTransport.kt": frozenset({"android", "android-sync"}),
            "android/app/src/main/kotlin/ch/lkmc/monkeyspaw/data/RootedFileStore.kt": frozenset({"android", "android-sync"}),
            "scripts/backup.sh": SERVER | {"deb"},
            "scripts/compose-smoke.sh": SERVER | {"core-linux"},
            "scripts/tests/test-backup.sh": frozenset({"core-linux", "deb"}),
            "scripts/tests/test-update.sh": frozenset({"core-linux", "deb"}),
            "scripts/tests/test_compose_smoke.py": frozenset({"core-linux", "compose-smoke"}),
            "scripts/tests/test_check_version.py": frozenset({"core-linux"}),
            "scripts/tests/test_android_version.py": frozenset({"core-linux"}),
            "scripts/tests/test_package_android.py": frozenset({"core-linux"}),
            "scripts/tests/test_verify_android_release.py": frozenset({"core-linux"}),
            "scripts/tests/test_release_workflow.py": frozenset({"core-linux"}),
            "scripts/tests/test_build.py": frozenset({"core-linux"}),
            "scripts/tests/test_flatpak_workflow.py": frozenset({"core-linux", "deb", "flatpak"}),
            "scripts/build-flatpak.sh": frozenset({"core-linux", "deb", "flatpak"}),
            "scripts/tests/test-build-flatpak.sh": frozenset({"core-linux", "deb", "flatpak"}),
            "scripts/tests/test-build-deb.sh": frozenset({"core-linux", "deb"}),
            "scripts/flatpak-smoke.py": frozenset({"core-linux", "deb", "flatpak"}),
            "flatpak/ch.lkmc.monkeyspaw.yml": frozenset({"deb", "flatpak"}),
            # A new test may run in any job; it selects everything until mapped.
            "scripts/tests/test_future.py": ALL,
            "README.md": frozenset({"core-linux", "deb"}),
            "README.android.md": frozenset(),
            "AGENTS.md": frozenset(),
            "CHANGELOG.md": frozenset(),
            "LICENSE": frozenset(),
            "docs/plan/14-repository-packaging-ci-release.md": frozenset(),
            "docs/platform/macos.md": frozenset(),
            "docs/decisions/0001-android-zero-secret-signing.md": frozenset({"core-linux"}),
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                self.assertEqual(changes.select_jobs("pull_request", [path]), with_flatpak(expected))

    def test_fail_open_paths(self):
        for path in (
            "new-input.txt", "scripts/new-script.sh", "Sources/NewTarget/File.swift",
            "docs-extra/example.md", "nested/README.md", "specification/data.json",
            ".github/workflows/ci.yml", ".github/workflows/zai-code-review.yml",
            ".github/actions/setup/action.yml", "scripts/ci-changes.py",
            "scripts/tests/test_ci_changes.py",
        ):
            with self.subTest(path=path):
                self.assertEqual(changes.select_jobs("pull_request", ["docs/a.md", path]), ALL)

    def test_non_pr_events_always_run_every_job(self):
        for event in ("push", "workflow_dispatch", "workflow_call", "unknown-event"):
            for paths in ([], ["docs/a.md"], ["android/core/build.gradle.kts"]):
                with self.subTest(event=event, paths=paths):
                    self.assertEqual(changes.select_jobs(event, paths), ALL)

    def test_empty_diff_and_docs_only(self):
        self.assertEqual(changes.select_jobs("pull_request", []), frozenset())
        self.assertEqual(changes.select_jobs("pull_request", ["docs/a.md", "PLAN.md"]), frozenset())

    def test_assistant_shared_families_select_both_semantic_consumers(self):
        for family, filename in (
            ("schema-artifact", "schema.json"), ("artifact-all-fields", "output.txt"),
            ("anthropic-write-official-unset", "1-request.json"),
            ("openai-ladder-none", "1-response.bin"),
            ("merge-improve-typed-metadata", "candidate.md"),
            ("diff-artifact-rename", "case.json"),
        ):
            with self.subTest(family=family):
                self.assertEqual(changes.select_jobs("pull_request", [f"spec/fixtures/llm/{family}/{filename}"]), ALL)

        for path in ("Assistant/Prompts/write.md", "Assistant/Prompts/review.md",
                     "Assistant/Prompts/improve.md", "scripts/generate-assistant-prompts.py"):
            with self.subTest(path=path):
                self.assertEqual(changes.select_jobs("pull_request", [path]), ALL)

    def test_assistant_accounting_drivers_and_disclosure_job_selection(self):
        cases = {
            "Tests/MonkeysPawCoreTests/Assistant/LlmConformanceTests.swift": SWIFT | {"android-sync"},
            "Tests/MonkeysPawCoreTests/PromptConformanceTests.swift": SWIFT | {"android-sync"},
            "android/core/src/test/kotlin/ch/lkmc/monkeyspaw/core/conformance/EveryFixtureTest.kt": {"android", "android-sync"},
            "android/core/src/test/kotlin/ch/lkmc/monkeyspaw/core/conformance/LlmConformanceTest.kt": {"android", "android-sync"},
            "android/app/src/test/kotlin/ch/lkmc/monkeyspaw/ui/settings/AssistantSettingsPersistenceTest.kt": {"android", "android-sync"},
            "android/app/src/main/kotlin/ch/lkmc/monkeyspaw/data/AndroidKeystoreSecretStore.kt": {"android", "android-sync"},
            "android/app/src/main/kotlin/ch/lkmc/monkeyspaw/data/OkHttpHttpTransport.kt": {"android", "android-sync"},
            "docs/platform/android.md": set(),
            "docs/plan/15-milestones.md": set(),
            "README.md": {"core-linux", "deb"},
        }
        for path, jobs in cases.items():
            with self.subTest(path=path):
                self.assertEqual(changes.select_jobs("pull_request", [path]), with_flatpak(jobs))

    def test_multiple_trees_union_their_jobs(self):
        self.assertEqual(changes.select_jobs("pull_request", [
            "android/core/build.gradle.kts", "MonkeysPaw/AppDelegate.swift",
        ]), MACOS | {"android", "android-sync"})

    def test_output_format(self):
        output = changes.format_outputs({"android", "server-image"})
        self.assertEqual(len(output.splitlines()), len(ALL))
        self.assertTrue(output.endswith("\n"))
        self.assertEqual(dict(line.split("=") for line in output.splitlines()), {
            job: "true" if job in {"android", "server-image"} else "false" for job in ALL
        })


class GitAndCLITests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="ci-changes-test-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.git("init", "-q")
        self.git("config", "user.email", "ci-test@example.invalid")
        self.git("config", "user.name", "CI test")
        self.git("config", "commit.gpgsign", "false")

    def git(self, *arguments):
        return subprocess.check_output(["git", "-C", str(self.root), *arguments], text=True).strip()

    def write(self, path):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("identical file contents\n", encoding="utf-8")

    def commit(self):
        self.git("add", "--all")
        self.git("commit", "-qm", "Test commit")
        return self.git("rev-parse", "HEAD")

    def diff(self, base, head):
        original_run = subprocess.run
        with patch.object(changes.subprocess, "run", side_effect=lambda *args, **kwargs:
                          original_run(*args, cwd=self.root, **kwargs)):
            return changes.changed_paths(base, head)

    def run_script(self, event, output, base="", head=""):
        return subprocess.run([sys.executable, str(SCRIPT)], cwd=self.root, env={
            **os.environ, "CI_EVENT_NAME": event, "CI_BASE_SHA": base,
            "CI_HEAD_SHA": head, "GITHUB_OUTPUT": str(output),
        }, capture_output=True, text=True)

    def test_renames_include_both_trees_and_docs_boundaries(self):
        pairs = (
            ("android/old.kt", "MonkeysPaw/new.swift", MACOS | {"android", "android-sync"}),
            ("android/into-docs.kt", "docs/new.md", frozenset({"android", "android-sync"})),
            ("docs/out.md", "MonkeysPaw/new.md", MACOS),
            ("unknown/old.txt", "android/new.kt", ALL),
        )
        for old, new, expected in pairs:
            with self.subTest(old=old, new=new):
                self.write(old)
                base = self.commit()
                (self.root / new).parent.mkdir(parents=True, exist_ok=True)
                self.git("mv", old, new)
                head = self.commit()
                self.assertIn("R100", self.git("diff", "--name-status", "-M", base, head))
                paths = self.diff(base, head)
                self.assertEqual(set(paths), {old, new})
                self.assertEqual(changes.select_jobs("pull_request", paths), expected)

    def test_merge_base_excludes_changes_only_on_base_branch(self):
        self.write("docs/shared.md")
        common = self.commit()
        self.write("android/new.kt")
        head = self.commit()
        self.git("checkout", "-q", "--detach", common)
        self.write("Sources/MonkeysPawCore/base.swift")
        base = self.commit()
        self.assertEqual(self.diff(base, head), ["android/new.kt"])

    def test_nul_diff_handles_spaces_newlines_and_non_ascii(self):
        self.write("docs/base.md")
        base = self.commit()
        paths = {"android/a b.kt", "MonkeysPaw/a\nb.swift", "docs/café.md"}
        for path in paths:
            self.write(path)
        self.assertEqual(set(self.diff(base, self.commit())), paths)

    def test_pr_cli_appends_all_outputs_and_empty_diff_skips_builds(self):
        self.write("docs/base.md")
        base = self.commit()
        self.write("android/a.kt")
        head = self.commit()
        output = self.root / "output"
        output.write_text("existing=value\n")
        result = self.run_script("pull_request", output, base, head)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_text(), "existing=value\n" + changes.format_outputs({"android", "android-sync"}))
        output = self.root / "empty-output"
        result = self.run_script("pull_request", output, head, head)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_text(), changes.format_outputs(set()))

    def test_non_pr_cli_needs_no_git_refs(self):
        for event in ("push", "workflow_dispatch", "workflow_call"):
            with self.subTest(event=event):
                output = self.root / event
                result = self.run_script(event, output)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_text(), changes.format_outputs(ALL))

    def test_failed_diff_or_missing_sha_fails_without_outputs(self):
        for base, head in (("", ""), ("a" * 40, "b" * 40)):
            with self.subTest(base=base):
                output = self.root / "failed-output"
                result = self.run_script("pull_request", output, base, head)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists())

    def test_output_write_failure_fails_the_script(self):
        result = self.run_script("push", self.root / "missing-directory/output")
        self.assertNotEqual(result.returncode, 0)


class WorkflowTests(unittest.TestCase):
    def test_every_job_has_a_matching_output_dependency_and_condition(self):
        # Keep unittest discovery standard-library-only in the Swift container.
        # The separate validation gate parses the complete YAML with PyYAML.
        source = (ROOT / ".github/workflows/ci.yml").read_text()
        blocks = dict(re.findall(
            r"^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)",
            source.split("\njobs:\n", 1)[1], re.MULTILINE | re.DOTALL,
        ))
        self.assertEqual(set(blocks), ALL | {"changes"})
        selector = blocks["changes"]
        outputs = dict(re.findall(
            r"^      ([\w-]+): \$\{\{ steps\.select\.outputs\.([\w-]+) \}\}$",
            selector, re.MULTILINE,
        ))
        self.assertEqual(outputs, {job: job for job in ALL})
        self.assertIn("fetch-depth: 0", selector)
        self.assertIn("persist-credentials: false", selector)
        self.assertNotIn("continue-on-error", selector)
        for job in ALL:
            with self.subTest(job=job):
                needs = re.search(r"^    needs: (.+)$", blocks[job], re.MULTILINE)
                self.assertIsNotNone(needs)
                dependencies = re.findall(r"[\w-]+", needs[1])
                self.assertIn("changes", dependencies)
                self.assertLessEqual(set(dependencies), blocks.keys())
                self.assertIn(f"    if: needs.changes.outputs.{job} == 'true'\n", blocks[job])

    def test_release_calls_receive_the_full_ci_default(self):
        source = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertRegex(source, r"(?s)workflow_call:\n    inputs:\n      full-ci:.*?default: true")
        self.assertIn("CI_EVENT_NAME: ${{ inputs.full-ci && 'workflow_call' || github.event_name }}", source)
        self.assertIn("CI_BASE_SHA: ${{ github.event.pull_request.base.sha }}", source)
        self.assertIn("CI_HEAD_SHA: ${{ github.event.pull_request.head.sha }}", source)
        release = (ROOT / ".github/workflows/release.yml").read_text()
        call = release.split("  tests:\n", 1)[1].split("\n  verify:", 1)[0]
        self.assertIn("uses: ./.github/workflows/ci.yml", call)
        self.assertNotIn("with:", call)


if __name__ == "__main__":
    unittest.main()
