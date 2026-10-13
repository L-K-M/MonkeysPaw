#!/usr/bin/env python3
"""Select CI jobs from a PR's merge-base diff; other events run every job."""

import os
from pathlib import Path
import re
import shutil
import subprocess


JOBS = (
    "core-linux", "linux-app", "deb", "flatpak", "android", "core-macos", "macos-app",
    "macos-artifacts", "server", "server-image", "compose-smoke",
)
ALL_JOBS = frozenset(JOBS)
SWIFT_JOBS = ALL_JOBS - {"android"}
LINUX_JOBS = frozenset({"linux-app", "deb"})
MACOS_JOBS = frozenset({"macos-app", "macos-artifacts"})
SERVER_JOBS = frozenset({"server", "server-image", "compose-smoke"})
# The parent manifest validates Linux target paths even for Core/server builds;
# Docker also copies all of Sources/, including the Linux targets.
LINUX_SOURCE_JOBS = LINUX_JOBS | SERVER_JOBS | {"core-linux"}

FILES = {
    "Package.swift": SWIFT_JOBS,
    "Package.resolved": SWIFT_JOBS,
    # Android's JVM conformance test reads the frozen Swift table directly.
    "Sources/MonkeysPawCore/Sync/SyncPathCaseFold.swift": ALL_JOBS,
    # This is a check-version.py input, despite its Markdown extension.
    "README.md": frozenset({"core-linux", "deb"}),
    "compose.yaml": SERVER_JOBS,
    ".env.example": SERVER_JOBS,
    "Caddyfile": SERVER_JOBS,
    ".dockerignore": frozenset({"server-image", "compose-smoke"}),
    "update.sh": SERVER_JOBS | {"deb"},
    "media-sources/icon.png": LINUX_JOBS | MACOS_JOBS,
    "scripts/check-pbxproj.py": frozenset({"core-linux"}),
    "scripts/check-version.py": frozenset({"core-linux", "deb"}),
    "scripts/linux-delivery-smoke.sh": frozenset({"linux-app"}),
    "scripts/package-macos.sh": frozenset({"macos-artifacts"}),
    "scripts/make-icons.sh": MACOS_JOBS,
    "scripts/make-linux-icons.sh": frozenset({"deb"}),
    "scripts/build.sh": frozenset({"deb", "macos-artifacts"}),
    "scripts/release.sh": ALL_JOBS,
    "scripts/generate-seeds.py": SWIFT_JOBS,
    "scripts/generate-assistant-prompts.py": SWIFT_JOBS,
    "scripts/generate-kotlin-sync-fold.py": frozenset({"android"}),
    "scripts/backup.sh": SERVER_JOBS | {"deb"},
    # unittest discovery in core-linux also executes the compose script.
    "scripts/compose-smoke.sh": SERVER_JOBS | {"core-linux"},
    "scripts/sync-android-version.sh": frozenset({"android"}),
    "scripts/tests/test-backup.sh": frozenset({"core-linux", "deb"}),
    "scripts/tests/test-update.sh": frozenset({"core-linux", "deb"}),
    "scripts/tests/test_compose_smoke.py": frozenset({"core-linux", "compose-smoke"}),
    # Python tests run through core-linux unittest discovery.
    "scripts/tests/test_check_version.py": frozenset({"core-linux"}),
    # The Flatpak job repacks the deb job's tested artifact.
    "scripts/build-flatpak.sh": frozenset({"deb", "flatpak"}),
    "scripts/tests/test-build-flatpak.sh": frozenset({"deb", "flatpak"}),
    "scripts/ci-changes.py": ALL_JOBS,
    "scripts/tests/test_ci_changes.py": ALL_JOBS,
}
PREFIXES = (
    (".github/workflows/", ALL_JOBS),
    (".github/actions/", ALL_JOBS),
    ("Sources/MonkeysPawCore/", SWIFT_JOBS),
    ("Tests/MonkeysPawCoreTests/", SWIFT_JOBS),
    ("Assistant/Prompts/", SWIFT_JOBS),
    ("spec/", ALL_JOBS),
    ("seed/", ALL_JOBS),
    ("Sources/CGtk/", LINUX_SOURCE_JOBS),
    ("Sources/MonkeysPawLinux/", LINUX_SOURCE_JOBS),
    ("Sources/monkeyspaw/", LINUX_SOURCE_JOBS),
    ("Tests/MonkeysPawLinuxTests/", LINUX_JOBS),
    # Keep the macOS exception before the general packaging rule.
    ("packaging/macos/", MACOS_JOBS),
    ("packaging/", LINUX_JOBS),
    ("MonkeysPaw/", MACOS_JOBS),
    ("MonkeysPawTests/", MACOS_JOBS),
    ("MonkeysPaw.xcodeproj/", MACOS_JOBS | {"core-linux", "deb"}),
    ("server/", SERVER_JOBS),
    ("deploy/caddy/", SERVER_JOBS),
    ("android/", frozenset({"android"})),
    ("flatpak/", frozenset({"deb", "flatpak"})),
    ("docs/", frozenset()),
)


def jobs_for_path(path):
    if path in FILES:
        return FILES[path]
    for prefix, jobs in PREFIXES:
        if path.startswith(prefix):
            return jobs
    if path == "LICENSE" or ("/" not in path and path.endswith(".md")):
        return frozenset()
    # New inputs must receive a rule before they can skip any checks.
    return ALL_JOBS


def select_jobs(event_name, paths):
    if event_name != "pull_request":
        return ALL_JOBS
    selected = frozenset().union(*(jobs_for_path(path) for path in paths))
    # Every deb change also changes the Flatpak bundle built from it.
    return selected | {"flatpak"} if "deb" in selected else selected


def changed_paths(base, head):
    if not re.fullmatch(r"[0-9a-f]{40}", base) or not re.fullmatch(r"[0-9a-f]{40}", head):
        raise ValueError("PR base and head must be full commit SHAs")
    git = shutil.which("git")
    if git is None:
        raise FileNotFoundError("git is required to select PR jobs")
    # Disable rename detection to include both the deleted and added names.
    result = subprocess.run(
        [git, "diff", "--name-only", "--no-renames", "-z", f"{base}...{head}", "--"],
        check=True, capture_output=True,
    )
    return [os.fsdecode(path) for path in result.stdout.split(b"\0") if path]


def format_outputs(selected):
    return "".join(f"{job}={'true' if job in selected else 'false'}\n" for job in JOBS)


def main():
    event_name = os.environ["CI_EVENT_NAME"]
    paths = changed_paths(os.environ["CI_BASE_SHA"], os.environ["CI_HEAD_SHA"]) \
        if event_name == "pull_request" else []
    # Do not catch failures or publish outputs until the diff is complete.
    with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
        output.write(format_outputs(select_jobs(event_name, paths)))


if __name__ == "__main__":
    main()
