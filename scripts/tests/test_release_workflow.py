"""Exercise release gates with temporary assets and a recording GitHub CLI."""

import fnmatch
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / ".github/workflows/release.yml").read_text()
JOBS = dict(re.findall(r"^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)",
                       SOURCE.split("\njobs:\n", 1)[1], re.MULTILINE | re.DOTALL))


def step_script(job, name, jobs=JOBS):
    step = jobs[job].split(f"      - name: {name}\n", 1)[1].split("\n      - ", 1)[0]
    return textwrap.dedent(step.split("        run: |\n", 1)[1])


def evaluate(expression, event, ref_type, dry_run, publish="false"):
    # Evaluate the workflow's simple event predicates, without any GitHub API calls.
    for name, value in {"github.event_name": event, "github.ref_type": ref_type,
                        "inputs.dry_run": dry_run, "needs.verify.outputs.publish": publish}.items():
        expression = expression.replace(name, repr(value))
    expression = re.sub(r"!(?!=)", "not ", expression.replace("&&", "and").replace("||", "or"))
    return eval(expression, {"__builtins__": {}}, {})


class ReleasePolicyTests(unittest.TestCase):
    def test_fork_and_same_repo_prs_and_manual_dry_runs_skip_publication(self):
        requested = re.search(r"PUBLISH_REQUESTED: \$\{\{ (.+) \}\}", JOBS["verify"])[1]
        for event, ref_type, dry_run, allowed in (
            ("pull_request", "branch", False, False), ("pull_request", "branch", True, False),
            ("workflow_dispatch", "branch", True, False), ("workflow_dispatch", "tag", True, False),
            ("workflow_dispatch", "tag", False, True), ("push", "tag", False, True),
        ):
            publish = "true" if evaluate(requested, event, ref_type, dry_run) else "false"
            with self.subTest(event=event, ref_type=ref_type, dry_run=dry_run):
                condition = re.search(r"^    if: (.+)$", JOBS["publish"], re.MULTILINE)[1]
                self.assertEqual(evaluate(condition, event, ref_type, dry_run, publish), allowed)
                self.assertNotIn("uses: actions/checkout", JOBS["publish"])

    def test_images_are_never_pushed_and_no_job_requests_package_write(self):
        self.assertNotIn("image-publish", JOBS)
        self.assertNotIn("IMAGE_NAME:", SOURCE)
        self.assertNotIn("image_tags:", JOBS["verify"])
        for source in (SOURCE, (ROOT / ".github/workflows/ci.yml").read_text()):
            self.assertNotRegex(source, r"\bpackages:\s*write\b|permissions:\s*write-all\b")
            self.assertNotIn("ghcr.io/", source)
            self.assertNotRegex(source, r"\b(?:docker|podman)\s+(?:login|logout|push)\b|"
                                r"docker/login-action|buildx\s+imagetools|--push\b|"
                                r"type=registry|push:\s*true\b|docker://")

    def test_both_native_image_builds_and_smokes_gate_release_publication(self):
        job = JOBS["server-images"]
        self.assertEqual(re.findall(r"- arch: (\w+)\n\s+runner: ([\w.-]+)", job),
                         [("amd64", "ubuntu-24.04"), ("arm64", "ubuntu-24.04-arm")])
        self.assertIn("needs: [tests, verify, linux]", job)
        self.assertIn("contents: read", job)
        self.assertNotRegex(job, re.compile(r"^    if:", re.MULTILINE))
        build = step_script("server-images", "Build native OCI archive and load it for smoke testing")
        self.assertIn('case "$ARCH:$(uname -m)"', build)
        self.assertIn('docker buildx build --platform "linux/$ARCH"', build)
        for name in ("VERSION", "REVISION", "CREATED"):
            self.assertIn(f'--build-arg "{name}=${name}"', build)
        self.assertIn('--output "type=oci,dest=$archive"', build)
        self.assertIn('skopeo copy "oci-archive:$archive" docker-daemon:monkeyspaw-server:release', build)
        smoke = step_script("server-images", "Wait for container health and require API status 200")
        self.assertIn('$bootstrap_dir/admin-password:/run/secrets/admin-password:ro', smoke)
        self.assertIn('"$health" == healthy', smoke)
        self.assertIn("http://127.0.0.1:8080/api/health", smoke)
        self.assertIn('if [[ "$status" != 200 ]]', smoke)
        self.assertLess(job.index("Wait for container health and require API status 200"),
                        job.index("Upload smoke-tested OCI archive and digest"))
        self.assertIn("name: MonkeysPaw-server-image-${{ matrix.arch }}", job)
        for name in ("artifacts", "publish"):
            dependencies = re.search(r"^    needs: \[(.+)\]$", JOBS[name], re.MULTILINE)[1].split(", ")
            self.assertIn("server-images", dependencies)

    def test_version_step_allows_dry_runs_and_rejects_branch_publication_and_wrong_tags(self):
        with tempfile.TemporaryDirectory(prefix="monkeyspaw-release-policy-") as directory:
            output = Path(directory) / "outputs"
            version = subprocess.check_output(["python3", "scripts/check-version.py", "--committed-version"],
                                              cwd=ROOT, text=True).strip()
            cases = (("branch", "feature", "false", True), ("branch", "feature", "true", False),
                     ("tag", f"v{version}", "false", True), ("tag", f"v{version}-beta.1", "false", True),
                     ("tag", "v99.99.99", "false", False), ("tag", f"v{version}+build", "false", False))
            for ref_type, ref, publish, allowed in cases:
                with self.subTest(ref=ref, publish=publish):
                    output.unlink(missing_ok=True)
                    result = subprocess.run(["/bin/bash", "-e", "-o", "pipefail", "-c",
                                             step_script("verify", "Check tag against committed settings")],
                                            cwd=ROOT, env=os.environ | {"GITHUB_REF_TYPE": ref_type,
                                            "GITHUB_REF_NAME": ref, "PUBLISH_REQUESTED": publish,
                                            "GITHUB_OUTPUT": str(output)}, capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, allowed, result.stdout + result.stderr)
                    if allowed:
                        self.assertIn("publish=false\n", output.read_text())
                    else:
                        self.assertFalse(output.exists())

    def test_android_assets_gate_assembly_and_publication(self):
        self.assertIn("needs: [tests, verify]", JOBS["android-build"])
        self.assertIn("testDebugUnitTest lintDebug assembleRelease", JOBS["android-build"])
        self.assertIn('"-PreleaseVersion=$VERSION"', JOBS["android-build"])
        self.assertIn("scripts/package-android.sh", JOBS["android-build"])
        self.assertIn("scripts/verify-android-release.py", JOBS["android-build"])
        self.assertNotIn("secrets.", JOBS["android-build"])
        for job in ("artifacts", "publish"):
            dependencies = re.search(r"^    needs: \[(.+)\]$", JOBS[job], re.MULTILINE)[1].split(", ")
            self.assertIn("android-build", dependencies)
            for required in ("tests", "verify", "linux", "macos"):
                self.assertIn(required, dependencies)
        self.assertIn("server-images", JOBS["artifacts"])
        for required in ("artifacts", "server-images"):
            self.assertIn(required, JOBS["publish"])
        for path in (".github/workflows/ci.yml", "android/**", "spec/**", "seed/**", "scripts/package-android.sh",
                     "scripts/verify-android-release.py", "scripts/check-version.py"):
            self.assertIn(f"      - {path}\n", SOURCE.split("\nconcurrency:", 1)[0])

    def test_retained_failure_reports_do_not_join_release_assets_after_a_retry(self):
        names = re.findall(r"^          name: (.+)$", SOURCE, re.MULTILINE)
        selected = {name for name in names if fnmatch.fnmatchcase(name, "MonkeysPaw-release-*")}
        self.assertEqual(selected, {"MonkeysPaw-release-deb", "MonkeysPaw-release-macos",
                                    "MonkeysPaw-release-android", "MonkeysPaw-release-flatpak"})
        report_step = JOBS["android-build"].split("      - name: Upload Android reports on failure\n", 1)[1]
        self.assertIn("if: failure()", report_step)
        report = re.search(r"^          name: (.+)$", report_step, re.MULTILINE)[1]
        self.assertFalse(fnmatch.fnmatchcase(report, "MonkeysPaw-release-*"))
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertNotIn(f"name: {report}\n", ci, "Release/ordinary CI report names must be distinct")

    def test_ordinary_ci_keeps_the_five_task_gate_and_verifies_release_artifacts(self):
        source = (ROOT / ".github/workflows/ci.yml").read_text()
        android = source.split("\n  android:\n", 1)[1].split("\n  core-macos:\n", 1)[0]
        self.assertIn("./gradlew :core:test testDebugUnitTest lintDebug assembleDebug assembleRelease", android)
        self.assertIn("scripts/package-android.sh", android)
        self.assertIn("scripts/verify-android-release.py", android)
        self.assertIn("name: MonkeysPaw-android-release", android)
        self.assertIn("contents: read", android)
        self.assertNotIn("secrets.", android)


class AndroidRoundTripTests(unittest.TestCase):
    def test_both_workflows_compare_each_downloaded_apk_and_checksum_byte(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        ci_jobs = dict(re.findall(r"^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)",
                                 ci.split("\njobs:\n", 1)[1], re.MULTILINE | re.DOTALL))
        cases = ((JOBS, "android-build", "Byte-compare against original APK outputs", "android-roundtrip"),
                 (ci_jobs, "android", "Byte-compare against original release APK outputs", "android-ci-roundtrip"))
        with tempfile.TemporaryDirectory(prefix="monkeyspaw-apk-roundtrip-") as directory:
            root = Path(directory)
            android = root / "android"
            android.mkdir()
            dist = root / "dist"
            dist.mkdir()
            apk = "monkeyspaw-v0.1.0-beta.1.apk"
            data = {apk: b"signed APK", f"{apk}.sha256":
                    f"{hashlib.sha256(b'signed APK').hexdigest()}  {apk}\n".encode()}
            for name, content in data.items():
                (dist / name).write_bytes(content)
            for jobs, job, step, download_path in cases:
                with self.subTest(job=job):
                    download = root / download_path
                    download.mkdir()
                    for name, content in data.items():
                        (download / name).write_bytes(content)
                    script = step_script(job, step, jobs)

                    def run():
                        return subprocess.run(["/bin/bash", "-e", "-o", "pipefail", "-c", script],
                                              cwd=android, env=os.environ | {"APK_FILE": apk,
                                              "RUNNER_TEMP": str(root)}, capture_output=True, text=True)

                    result = run()
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    for name, content in data.items():
                        with self.subTest(file=name):
                            file = download / name
                            file.write_bytes(content + b"corruption")
                            self.assertNotEqual(run().returncode, 0)
                            file.unlink()
                            self.assertNotEqual(run().returncode, 0)
                            file.write_bytes(content)


class ReleaseAssetTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="monkeyspaw-release-gate-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.dist = self.root / "dist"
        self.dist.mkdir()
        self.calls = self.root / "gh-calls"
        gh = self.root / "bin/gh"
        gh.parent.mkdir()
        gh.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$GH_CALLS"\n')
        gh.chmod(0o755)
        self.env = os.environ | {
            "PATH": f"{gh.parent}:{os.environ['PATH']}", "GH_CALLS": str(self.calls),
            "GH_REPO": "example/MonkeysPaw", "PRERELEASE": "true", "RUNNER_TEMP": str(self.root),
        }
        self.prepare_assets("0.1.0-beta.1")

    def prepare_assets(self, version):
        for file in self.dist.iterdir():
            file.unlink()
        self.version = version
        self.deb = f"monkeyspaw_{version.replace('-', '~')}_amd64.deb"
        self.bundle = f"monkeyspaw_{self.version}_x86_64.flatpak"
        self.apk = f"monkeyspaw-v{self.version}.apk"
        self.groups = {
            f"{self.deb}.sha256": [self.deb],
            f"{self.bundle}.sha256": [self.bundle],
            f"MonkeysPaw-{self.version}.sha256": [f"MonkeysPaw-{self.version}.zip",
                                                    f"MonkeysPaw-{self.version}.dmg"],
            f"{self.apk}.sha256": [self.apk],
        }
        for manifest, files in self.groups.items():
            lines = []
            for name in files:
                data = f"fixture {name}".encode()
                (self.dist / name).write_bytes(data)
                lines.append(f"{hashlib.sha256(data).hexdigest()}  {name}\n")
            (self.dist / manifest).write_text("".join(lines))
        self.env.update({
            "VERSION": self.version, "RELEASE_TAG": f"v{self.version}", "DEB_FILE": self.deb,
            "BUNDLE_FILE": self.bundle, "APK_FILE": self.apk,
        })

    def run_step(self, job, name):
        return subprocess.run(["/bin/bash", "-e", "-o", "pipefail", "-c", step_script(job, name)],
                              cwd=self.root, env=self.env, capture_output=True, text=True)

    def assert_blocked(self):
        for job, name in (("artifacts", "Require every asset and verify checksums"),
                          ("publish", "Create draft and attach every asset")):
            with self.subTest(job=job):
                result = self.run_step(job, name)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(self.calls.exists(), "An invalid set reached draft creation")

    def test_seven_desktop_assets_plus_android_pair_pass_assembly_and_draft_creation(self):
        result = self.run_step("artifacts", "Require every asset and verify checksums")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_step("publish", "Create draft and attach every asset")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        call = self.calls.read_text()
        self.assertIn("--verify-tag --draft", call)
        self.assertIn("--prerelease=true --latest=false", call)
        self.assertIn("--notes-file", call)
        notes = (self.root / "android-release-notes.md").read_text()
        self.assertIn("public signing key", notes)
        self.assertIn("verify the checksum before sideloading", notes)
        for name in self.dist.iterdir():
            self.assertIn(f"dist/{name.name}", call)

    def test_generated_notes_link_the_full_tag_and_keep_platform_guidance(self):
        for repository, version, prerelease in (
            ("example/StableRelease", "0.1.0", "false"),
            ("another/Prerelease", "0.1.0-rc-1.2", "true"),
        ):
            with self.subTest(repository=repository, version=version):
                self.prepare_assets(version)
                self.calls.unlink(missing_ok=True)
                self.env.update({"GH_REPO": repository, "PRERELEASE": prerelease})
                assets = {file.name: file.read_bytes() for file in self.dist.iterdir()}
                result = self.run_step("publish", "Create draft and attach every asset")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                notes = (self.root / "android-release-notes.md").read_text()
                self.assertIn(f"[Release changelog](https://github.com/{repository}/blob/v{version}/CHANGELOG.md)",
                              notes)
                for guidance in (
                    "Android requires API 26", "verify the checksum before sideloading",
                    "signed and shrunk with R8", "Copy and paste manually", "public signing key",
                    "signature does not establish publisher identity", "/docs/platform/android.md",
                    "Linux x86_64", "GNOME Platform 50", ".flatpak.sha256",
                    "sha256sum -c <bundle>.sha256", "flatpak install --user ./<bundle>",
                    "one active native or Flatpak installation", "home directory", "copy fallback",
                ):
                    self.assertIn(guidance, notes)
                create = self.calls.read_text().splitlines()
                self.assertEqual(len(create), 1)
                self.assertIn(f"release create v{version} ", create[0])
                for flags in ("--verify-tag --draft", "--generate-notes", "--notes-file",
                              f"--prerelease={prerelease} --latest=false"):
                    self.assertIn(flags, create[0])
                self.assertEqual(len(assets), 9)
                self.assertEqual(sorted(arg for arg in create[0].split() if arg.startswith("dist/")),
                                 sorted(f"dist/{name}" for name in assets))
                self.assertEqual({file.name: file.read_bytes() for file in self.dist.iterdir()}, assets)
                result = self.run_step("publish", "Publish only after every comparison passes")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                latest = "false" if prerelease == "true" else "true"
                self.assertEqual(self.calls.read_text().splitlines()[1],
                                 f"release edit v{version} --verify-tag --draft=false "
                                 f"--prerelease={prerelease} --latest={latest}")

    def test_desktop_only_set_cannot_be_published(self):
        (self.dist / self.apk).unlink()
        (self.dist / f"{self.apk}.sha256").unlink()
        self.assert_blocked()

    def test_pre_flatpak_asset_set_cannot_be_published(self):
        (self.dist / self.bundle).unlink()
        (self.dist / f"{self.bundle}.sha256").unlink()
        self.assert_blocked()

    def test_assembly_and_publication_asset_assertions_are_identical(self):
        assembly = step_script("artifacts", "Require every asset and verify checksums").strip()
        publish = step_script("publish", "Create draft and attach every asset").split("\ncat >", 1)[0].strip()
        self.assertEqual(assembly, publish)

    def test_every_missing_or_empty_asset_blocks_publication(self):
        for file in list(self.dist.iterdir()):
            data = file.read_bytes()
            for mode in ("missing", "empty"):
                with self.subTest(file=file.name, mode=mode):
                    if mode == "missing":
                        file.unlink()
                    else:
                        file.write_bytes(b"")
                    self.assert_blocked()
                    file.write_bytes(data)

    def test_extra_visible_hidden_or_directory_asset_blocks_publication(self):
        for name in ("extra.apk", ".extra", "extra-directory"):
            with self.subTest(name=name):
                extra = self.dist / name
                if name == "extra-directory":
                    extra.mkdir()
                else:
                    extra.write_bytes(b"extra")
                self.assert_blocked()
                extra.rmdir() if extra.is_dir() else extra.unlink()

    def test_corrupt_payload_or_checksum_blocks_publication(self):
        for file in self.dist.iterdir():
            with self.subTest(file=file.name):
                data = file.read_bytes()
                file.write_bytes(data + b"corruption")
                self.assert_blocked()
                file.write_bytes(data)

    def test_manifest_cannot_omit_duplicate_or_substitute_an_asset(self):
        for manifest, names in self.groups.items():
            file = self.dist / manifest
            original = file.read_text()
            substitute = (self.dist / f"{self.deb}.sha256").read_text()
            mutations = [original + original, original + original.rstrip("\n"), substitute]
            if len(names) > 1:
                mutations.append(original.splitlines(keepends=True)[0])
            for mutation in mutations:
                if mutation == original:
                    continue
                with self.subTest(manifest=manifest, mutation=mutation):
                    file.write_text(mutation)
                    self.assert_blocked()
                    file.write_text(original)

    def test_draft_download_must_match_all_nine_files(self):
        downloaded = self.root / "release-assets"
        downloaded.mkdir()
        for file in self.dist.iterdir():
            (downloaded / file.name).write_bytes(file.read_bytes())
        name = "Download and byte-compare every draft asset"
        result = self.run_step("publish", name)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for file in list(downloaded.iterdir()):
            with self.subTest(file=file.name):
                data = file.read_bytes()
                file.write_bytes(data + b"corruption")
                self.assertNotEqual(self.run_step("publish", name).returncode, 0)
                file.unlink()
                self.assertNotEqual(self.run_step("publish", name).returncode, 0)
                file.write_bytes(data)
        for extra in ("extra", ".extra"):
            file = downloaded / extra
            file.write_text("extra")
            self.assertNotEqual(self.run_step("publish", name).returncode, 0)
            file.unlink()


if __name__ == "__main__":
    unittest.main()
