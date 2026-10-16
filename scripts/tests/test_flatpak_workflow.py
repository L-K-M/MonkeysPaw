"""Check Flatpak release gates, byte round-trips and invite-proof assertions."""

import hashlib
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from test_release_workflow import JOBS, SOURCE, step_script


ROOT = Path(__file__).resolve().parents[2]
CI = (ROOT / ".github/workflows/ci.yml").read_text()
CI_JOBS = dict(re.findall(r"^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)",
                          CI.split("\njobs:\n", 1)[1], re.MULTILINE | re.DOTALL))
spec = importlib.util.spec_from_file_location("flatpak_smoke", ROOT / "scripts/flatpak-smoke.py")
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class FlatpakWorkflowTests(unittest.TestCase):
    def test_release_uses_the_exact_tested_deb_and_blocks_all_publishers(self):
        job = JOBS["flatpak"]
        self.assertIn("needs: [tests, verify, linux]", job)
        self.assertIn("DEB_FILE: ${{ needs.linux.outputs.deb_file }}", job)
        self.assertIn("name: MonkeysPaw-release-deb", job)
        self.assertIn('"$RUNNER_TEMP/monkeyspaw-tested-deb/$DEB_FILE" "$VERSION"', job)
        self.assertIn('apt-get install -y --no-install-recommends "./dist/$deb_file"', JOBS["linux"])
        self.assertIn('$(/usr/bin/monkeyspaw --version)', JOBS["linux"])
        for name in ("artifacts", "image-publish", "publish"):
            dependencies = re.search(r"^    needs: \[(.+)\]$", JOBS[name], re.MULTILINE)[1].split(", ")
            self.assertIn("flatpak", dependencies)
        for path in ("flatpak/**", "scripts/build-flatpak.sh", "scripts/flatpak-smoke.py"):
            self.assertIn("      - " + path + "\n", SOURCE.split("\nconcurrency:", 1)[0])

    def test_both_flatpak_jobs_are_bare_read_only_bounded_and_cleaned(self):
        for jobs in (JOBS, CI_JOBS):
            with self.subTest(workflow=jobs is JOBS):
                job = jobs["flatpak"]
                self.assertIn("runs-on: ubuntu-24.04", job)
                self.assertIn("timeout-minutes: 30", job)
                self.assertIn("contents: read", job)
                self.assertIn("persist-credentials: false", job)
                self.assertIn("timeout 10s bwrap", job)
                self.assertIn("org.gnome.Platform//50 org.gnome.Sdk//50", job)
                self.assertIn("if: always()", job)
                self.assertIn('kernel.apparmor_restrict_unprivileged_userns=$(cat ', job)
                self.assertNotRegex(job, r"\b(?:swift|swift64) (?:build|test)\b|container:|secrets\.")
                for action in re.findall(r"uses: (.+)", job):
                    self.assertRegex(action, r"^[\w/-]+@[0-9a-f]{40}(?: #.*)?$")

    def test_ordinary_ci_uses_installed_exports_and_requires_display_accessibility_and_mime(self):
        job = CI_JOBS["flatpak"]
        self.assertIn('flatpak install --user --noninteractive --assumeyes "dist/$BUNDLE_FILE"', job)
        self.assertIn('cmp "$payload/usr/bin/monkeyspaw" "$deployment/files/bin/monkeyspaw"', job)
        self.assertIn("gio mime x-scheme-handler/monkeyspaw", job)
        self.assertIn("entry['MimeType'] == 'x-scheme-handler/monkeyspaw;'", job)
        self.assertIn("GTK_A11Y=atspi", job)
        self.assertIn("python3-xlib", job)
        self.assertIn('XDG_DATA_DIRS="$XDG_DATA_HOME/flatpak/exports/share:', job)
        self.assertIn("timeout --kill-after=5s 180s xvfb-run -a --server-args='-screen 0 1280x2400x24'", job)
        self.assertIn("dbus-run-session -- /usr/bin/python3 scripts/flatpak-smoke.py", job)
        self.assertIn("flatpak override --user", job)
        for variable, value in (("GTK_A11Y", "atspi"), ("GSK_RENDERER", "cairo"),
                                ("GSETTINGS_BACKEND", "memory"), ("GDK_BACKEND", "x11")):
            self.assertIn(f'--env={variable}="${variable}"', job)
            self.assertIn(f'test "${variable}" = {value}', job)
        self.assertIn("/usr/bin/python3 scripts/flatpak-smoke.py", job)
        self.assertNotIn("xdg-mime default", job)

    def test_both_workflows_round_trip_every_bundle_and_checksum_byte(self):
        with tempfile.TemporaryDirectory(prefix="monkeyspaw-flatpak-roundtrip-") as directory:
            root = Path(directory)
            dist = root / "dist"
            dist.mkdir()
            bundle = "monkeyspaw_0.2.0-rc-1_x86_64.flatpak"
            contents = {bundle: b"Flatpak bundle", bundle + ".sha256":
                        f"{hashlib.sha256(b'Flatpak bundle').hexdigest()}  {bundle}\n".encode()}
            for name, data in contents.items():
                (dist / name).write_bytes(data)
            for jobs, folder in ((JOBS, "flatpak-roundtrip"), (CI_JOBS, "flatpak-ci-roundtrip")):
                download = root / folder
                download.mkdir()
                for name, data in contents.items():
                    (download / name).write_bytes(data)
                script = step_script("flatpak", "Byte-compare against original Flatpak outputs", jobs)

                def run():
                    return subprocess.run(["/bin/bash", "-e", "-o", "pipefail", "-c", script], cwd=root,
                                          env=os.environ | {"BUNDLE_FILE": bundle, "RUNNER_TEMP": str(root)},
                                          capture_output=True, text=True)

                self.assertEqual(run().returncode, 0)
                for name, data in contents.items():
                    with self.subTest(workflow=folder, file=name):
                        file = download / name
                        file.write_bytes(data + b"corrupt")
                        self.assertNotEqual(run().returncode, 0)
                        file.unlink()
                        self.assertNotEqual(run().returncode, 0)
                        file.write_bytes(data)


class RepeatProofComplete(Exception):
    """Stop main after the action proof, before invite setup."""


class RepeatProofTests(unittest.TestCase):
    def run_proof(self, *, resident_noop=False, dismiss_noop=False, replace_owner=False,
                  instances=1):
        state = {"owner": None, "picker": False, "result": False, "repeats": 0}

        def action(name):
            state["owner"] = state["owner"] or ":1.42"
            if name == "toggle":
                state["picker"] = not state["picker"]
            elif name == "repeat":
                state["repeats"] += 1
                if state["repeats"] == 1 or not resident_noop:
                    state["result"] = True
                if state["repeats"] == 2 and replace_owner:
                    state["owner"] = ":1.43"

        def stop():
            state.update(owner=None, result=False)

        def dismiss(event):
            self.assertEqual(event["client_type"], "WM_PROTOCOLS")
            self.assertEqual(event["data"], (32, ["WM_DELETE_WINDOW", 0, 0, 0, 0]))
            if not dismiss_noop:
                state["result"] = False

        def wait_for(predicate, message):
            if not predicate():
                raise RuntimeError(message)

        def command(*args, **_kwargs):
            if args[:2] == ("flatpak", "ps"):
                count = instances if state["repeats"] == 2 else 1
                return "\n".join([smoke.APP_ID] * count)
            if args[:2] == ("xdotool", "search"):
                if args[-1] == "^Repeat last$":
                    return "456" if state["result"] else ""
                return "123" if state["picker"] else ""
            return ""

        result = SimpleNamespace(name="Nothing to repeat",
                                 getState=lambda: SimpleNamespace(contains=lambda _: state["result"]))
        display = SimpleNamespace(intern_atom=lambda name: name,
                                  create_resource_object=lambda *_: SimpleNamespace(send_event=dismiss),
                                  sync=lambda: None, close=lambda: None)
        atspi = SimpleNamespace(STATE_SHOWING="showing",
                                Registry=SimpleNamespace(getDesktop=lambda _: object()))
        glib = SimpleNamespace(MainContext=SimpleNamespace(default=lambda: SimpleNamespace(pending=lambda: False)))
        with (patch.dict("sys.modules", {"pyatspi": atspi, "gi.repository": SimpleNamespace(GLib=glib),
                                        "Xlib.display": SimpleNamespace(Display=lambda: display),
                                        "Xlib.protocol.event": SimpleNamespace(ClientMessage=lambda **event: event)}),
              patch.dict(os.environ, DISPLAY=":99", DBUS_SESSION_BUS_ADDRESS="test"),
              patch.object(smoke, "command", side_effect=command),
              patch.object(smoke, "action", side_effect=action),
              patch.object(smoke, "owner", side_effect=lambda: state["owner"]),
              patch.object(smoke, "stop", side_effect=stop),
              patch.object(smoke, "wait_for", side_effect=wait_for),
              patch.object(smoke, "descendants", return_value=[result]),
              patch.object(smoke, "ThreadingHTTPServer"), patch.object(smoke.threading, "Thread"),
              patch.object(smoke.time, "sleep"),
              patch.object(smoke.configparser, "ConfigParser", side_effect=RepeatProofComplete)):
            smoke.main()

    def test_cold_then_resident_repeat_reopens_the_dismissed_result(self):
        with self.assertRaises(RepeatProofComplete):
            self.run_proof()

    def test_noop_resident_repeat_fails(self):
        with self.assertRaisesRegex(RuntimeError, "Resident repeat did not show"):
            self.run_proof(resident_noop=True)

    def test_result_must_disappear_before_resident_repeat(self):
        with self.assertRaisesRegex(RuntimeError, "Cold repeat result did not dismiss"):
            self.run_proof(dismiss_noop=True)

    def test_resident_repeat_must_keep_the_primary_owner(self):
        with self.assertRaisesRegex(RuntimeError, "Activation replaced the primary application"):
            self.run_proof(replace_owner=True)

    def test_multiple_instances_fail(self):
        with self.assertRaisesRegex(RuntimeError, "Expected exactly one installed application instance"):
            self.run_proof(instances=2)


class InviteProofTests(unittest.TestCase):
    atspi = SimpleNamespace(STATE_SHOWING="visible", STATE_SENSITIVE="sensitive", ROLE_FRAME="frame")
    destination = "http://127.0.0.1:1234/paw%20base/a+b/cold-open"

    def node(self, name, visible=True, sensitive=True, role="label"):
        states = {"visible"} if visible else set()
        if sensitive:
            states.add("sensitive")
        return SimpleNamespace(name=name, getState=lambda: SimpleNamespace(contains=states.__contains__),
                               getRole=lambda: role)

    def setUp(self):
        self.nodes = [self.node("Settings", role="frame"), self.node("Invite server: " + self.destination + "\nNo account is signed in."),
                      self.node("Review the server and account before accepting. Opening an invite does not use it."),
                      self.node("Accept and create account")]

    def staged(self):
        return smoke.invite_is_staged(self.nodes, self.destination, self.atspi)

    def test_requires_visible_exact_destination_and_an_enabled_accept_control(self):
        self.assertTrue(self.staged())
        for index in range(len(self.nodes)):
            original = self.nodes[index]
            self.nodes[index] = self.node(original.name, visible=False)
            self.assertFalse(self.staged())
            self.nodes[index] = original
        self.nodes[-1] = self.node("Accept and create account", sensitive=False)
        self.assertFalse(self.staged())
        self.nodes[-1] = self.node("Accept and create account")
        self.nodes[1] = self.node("Invite server: " + self.destination.replace("%20", " ") + "\n")
        self.assertFalse(self.staged(), "Incorrect URL decoding must fail the installed proof")

    def test_rejects_success_or_an_extra_settings_window(self):
        for extra in (self.node("Invite accepted."), self.node("Settings", role="frame")):
            self.nodes.append(extra)
            self.assertFalse(self.staged())
            self.nodes.pop()


if __name__ == "__main__":
    unittest.main()
