"""Check Flatpak release gates, byte round-trips and invite-proof assertions."""

import hashlib
import importlib.util
import io
import os
from pathlib import Path
import re
import runpy
import subprocess
import tempfile
from contextlib import redirect_stderr, redirect_stdout
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from test_release_workflow import JOBS, SOURCE, step_script


ROOT = Path(__file__).resolve().parents[2]
CI = (ROOT / ".github/workflows/ci.yml").read_text()
CI_JOBS = dict(re.findall(r"^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)",
                          CI.split("\njobs:\n", 1)[1], re.MULTILINE | re.DOTALL))
spec = importlib.util.spec_from_file_location("flatpak_smoke", ROOT / "scripts/flatpak-smoke.py")
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)
COMMAND_FAILURE = (r"^Installed application command failed \(phase=[a-z-]+; operation=[a-z-]+; "
                   r"kind=exit; code=[0-9]+\)$")


class FlatpakWorkflowTests(unittest.TestCase):
    def test_release_uses_the_exact_tested_deb_and_blocks_all_publishers(self):
        job = JOBS["flatpak"]
        self.assertIn("needs: [tests, verify, linux]", job)
        self.assertIn("DEB_FILE: ${{ needs.linux.outputs.deb_file }}", job)
        self.assertIn("name: MonkeysPaw-release-deb", job)
        self.assertIn('"$RUNNER_TEMP/monkeyspaw-tested-deb/$DEB_FILE" "$VERSION"', job)
        self.assertIn('apt-get install -y --no-install-recommends "./dist/$deb_file"', JOBS["linux"])
        self.assertIn('$(/usr/bin/monkeyspaw --version)', JOBS["linux"])
        for name in ("artifacts", "publish"):
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


class VisibleWindowTests(unittest.TestCase):
    def window(self, identifier, *, title="Monkey's Paw", classes=(smoke.APP_ID, "Ch.lkmc.monkeyspaw"),
               map_state=2):
        return SimpleNamespace(id=identifier, get_wm_name=lambda: title, get_wm_class=lambda: classes,
                               get_attributes=lambda: SimpleNamespace(map_state=map_state))

    def visible(self, windows, title="Monkey's Paw"):
        class BadWindow(Exception):
            pass

        display = SimpleNamespace(screen=lambda: SimpleNamespace(root=SimpleNamespace(
            query_tree=lambda: SimpleNamespace(children=windows))), close=lambda: None)
        with patch.dict("sys.modules", {"Xlib": SimpleNamespace(X=SimpleNamespace(IsViewable=2)),
                                        "Xlib.display": SimpleNamespace(Display=lambda: display),
                                        "Xlib.error": SimpleNamespace(BadWindow=BadWindow)}):
            return smoke.visible_windows(title)

    def test_requires_mapped_app_class_and_exact_title(self):
        windows = [self.window(1), self.window(2, classes=("other", "Other")),
                   self.window(3, title="Repeat last"), self.window(4, map_state=0),
                   self.window(5, classes=None), self.window(6, title=None),
                   self.window(7, map_state=1)]
        self.assertEqual(self.visible(windows), [1])
        self.assertEqual(self.visible(windows, "Repeat last"), [3])
        self.assertEqual(self.visible(windows, "Settings"), [])

    def test_accepts_the_app_identity_in_either_wm_class_field(self):
        windows = [self.window(1, classes=(smoke.APP_ID, "Other")),
                   self.window(2, classes=("other", "Ch.lkmc.monkeyspaw"))]
        self.assertEqual(self.visible(windows), [1, 2])

    def test_a_retired_window_does_not_hide_other_matches(self):
        def retired():
            from Xlib.error import BadWindow
            raise BadWindow()

        window = self.window(1)
        window.get_attributes = retired
        self.assertEqual(self.visible([window, self.window(2)]), [2])


class RepeatProofComplete(Exception):
    """Stop main after the action proof, before invite setup."""


class OwnerQueryTests(unittest.TestCase):
    no_owner = ("Error: GDBus.Error:org.freedesktop.DBus.Error.NameHasNoOwner: "
                "Could not get owner of name 'ch.lkmc.monkeyspaw': no such name\n")

    def run_calls(self, operation, replies):
        remaining = iter(replies)
        elapsed = 0

        def run(args, **kwargs):
            destination, method, output, status, error = next(remaining)
            path = "/org/freedesktop/DBus" if destination == "org.freedesktop.DBus" else "/ch/lkmc/monkeyspaw"
            self.assertEqual(args[:9], ("gdbus", "call", "--session", "--dest", destination,
                                       "--object-path", path, "--method", method))
            self.assertEqual(args[9:], ("quit", "[]", "{}") if method == "org.gtk.Actions.Activate" else (smoke.APP_ID,))
            self.assertEqual(kwargs, dict(capture_output=True, text=True, timeout=15))
            return subprocess.CompletedProcess(args, status, output, error)

        def sleep(seconds):
            nonlocal elapsed
            elapsed += seconds

        with (patch.object(smoke.subprocess, "run", side_effect=run),
              patch.object(smoke.time, "monotonic", side_effect=lambda: elapsed),
              patch.object(smoke.time, "sleep", side_effect=sleep)):
            operation()
        self.assertEqual(list(remaining), [])

    def reply(self, method, output="", status=0, error="", destination="org.freedesktop.DBus"):
        return destination, "org.freedesktop.DBus." + method, output, status, error

    def test_completed_quit_survives_name_release_between_owner_queries(self):
        self.run_calls(smoke.stop, [self.reply("NameHasOwner", "(true,)"),
                       self.reply("GetNameOwner", "(':1.42',)"),
                       (":1.42", "org.gtk.Actions.Activate", "()", 0, ""),
                       self.reply("NameHasOwner", "(true,)"),
                       self.reply("GetNameOwner", status=1, error=self.no_owner)])

    def test_real_bus_and_command_failures_still_abort_quit(self):
        for method in ("NameHasOwner", "GetNameOwner"):
            for error in ("Error: The connection is closed\n",
                          "Error: GDBus.Error:org.freedesktop.DBus.Error.AccessDenied: denied\n",
                          "unrelated failure: " + self.no_owner):
                with self.subTest(method=method, failure=error.split(":", 1)[0]):
                    replies = [self.reply("NameHasOwner", "(true,)"), self.reply("GetNameOwner", "(':1.42',)"),
                               (":1.42", "org.gtk.Actions.Activate", "()", 0, "")]
                    if method == "GetNameOwner":
                        replies.append(self.reply("NameHasOwner", "(true,)"))
                    replies.append(self.reply(method, status=1, error=error))
                    with self.assertRaisesRegex(RuntimeError, COMMAND_FAILURE):
                        self.run_calls(smoke.stop, replies)

    def test_singleton_rejects_absent_or_replaced_owner_through_real_queries(self):
        for replies in ([self.reply("NameHasOwner", "(false,)")],
                        [self.reply("NameHasOwner", "(true,)"),
                         self.reply("GetNameOwner", status=1, error=self.no_owner)],
                        [self.reply("NameHasOwner", "(true,)"), self.reply("GetNameOwner", "(':1.43',)")]):
            with self.subTest(owner_reply=replies[-1][1]):
                with self.assertRaisesRegex(RuntimeError, "Activation replaced the primary application"):
                    self.run_calls(lambda: smoke.singleton("(':1.42',)"), replies)

    def test_no_owner_error_outside_get_name_owner_is_still_a_failure(self):
        with self.assertRaisesRegex(RuntimeError, COMMAND_FAILURE):
            self.run_calls(smoke.stop, [self.reply("NameHasOwner", status=1, error=self.no_owner)])

    def test_other_exit_status_with_no_owner_text_is_not_absence(self):
        with self.assertRaisesRegex(RuntimeError, COMMAND_FAILURE):
            self.run_calls(smoke.owner, [self.reply("NameHasOwner", "(true,)"),
                           self.reply("GetNameOwner", status=2, error=self.no_owner)])

    def test_command_timeout_is_not_absence(self):
        with (patch.object(smoke.subprocess, "run", side_effect=subprocess.TimeoutExpired("gdbus", 15)),
              self.assertRaises(subprocess.TimeoutExpired)):
            smoke.owner()


class SingletonTests(unittest.TestCase):
    def check(self, snapshots, *, owners=(":1.42",), expected=":1.42"):
        elapsed = 0
        commands = []
        remaining = iter(snapshots)
        current = snapshots[-1]
        remaining_owners = iter(owners)
        current_owner = owners[-1]

        def command(*args):
            nonlocal current
            self.assertEqual(args, ("flatpak", "ps", "--columns=application"))
            commands.append(args)
            current = next(remaining, current)
            return current

        def owner():
            nonlocal current_owner
            current_owner = next(remaining_owners, current_owner)
            return current_owner

        def sleep(seconds):
            nonlocal elapsed
            elapsed += seconds

        with (patch.object(smoke, "command", side_effect=command),
              patch.object(smoke, "owner", side_effect=owner),
              patch.object(smoke.time, "monotonic", side_effect=lambda: elapsed),
              patch.object(smoke.time, "sleep", side_effect=sleep)):
            smoke.singleton(expected)
        return len(commands)

    def test_flatpak_process_tree_is_one_sandbox(self):
        # flatpak/bwrap -> bwrap -> monkeyspaw, plus xdg-dbus-proxy and
        # flatpak-session-helper, yields one application row, not one per PID.
        self.assertEqual(self.check([smoke.APP_ID]), 1)

    def test_exited_tool_or_launcher_sandbox_record_can_expire(self):
        # Flatpak 1.14.6 keeps fresh, unlocked records for at least three
        # seconds. The live bwrap/app tree stays registered throughout.
        stale_and_live = "\n".join([smoke.APP_ID] * 2)
        self.assertGreater(self.check([stale_and_live] * 20 + [smoke.APP_ID]), 20)

    def test_other_applications_do_not_count(self):
        self.assertEqual(self.check(["org.gnome.Other\n" + smoke.APP_ID]), 1)

    def test_zero_or_persistent_multiple_sandboxes_fail(self):
        for snapshot in ("", "\n".join([smoke.APP_ID] * 2)):
            with self.subTest(snapshot=snapshot):
                with self.assertRaisesRegex(RuntimeError, "Expected exactly one installed application instance"):
                    self.check([snapshot])

    def test_no_primary_owner_cannot_pass_on_a_stale_record(self):
        with self.assertRaisesRegex(RuntimeError, "Activation replaced the primary application"):
            self.check([smoke.APP_ID], owners=(None,), expected=None)

    def test_owner_must_survive_instance_cleanup(self):
        for replacement in (None, ":1.43"):
            with self.subTest(replacement=replacement):
                with self.assertRaisesRegex(RuntimeError, "Activation replaced the primary application"):
                    self.check(["\n".join([smoke.APP_ID] * 2), smoke.APP_ID],
                               owners=(":1.42", replacement))


class RepeatProofTests(unittest.TestCase):
    def run_proof(self, *, resident_noop=False, dismiss_noop=False, replace_owner=False,
                  instances=1, toggle_noop=False):
        state = {"owner": None, "picker": False, "result": False, "repeats": 0}

        def action(name):
            state["owner"] = state["owner"] or ":1.42"
            if name == "toggle" and not toggle_noop:
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
            return ""

        def visible_windows(title):
            if title == "Repeat last":
                return [456] if state["result"] else []
            return [123] if state["picker"] else []

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
              patch.object(smoke, "visible_windows", side_effect=visible_windows),
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

    def test_noop_cold_toggle_fails_without_a_mapped_picker(self):
        with self.assertRaisesRegex(RuntimeError, "Cold toggle did not show the picker"):
            self.run_proof(toggle_noop=True)

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


class CleanupProofTests(unittest.TestCase):
    def run_proof(self, *, proof_fails=True, kill_error=None, child_timeout=False, command_failure=None):
        self.server = Mock(server_port=1234)
        self.thread = Mock()
        child = Mock()
        self.child = child
        child.poll.return_value = None
        launcher = Mock(return_value=child)
        config = smoke.configparser.ConfigParser(interpolation=None)
        config["Desktop Entry"] = {"Exec": "flatpak run " + smoke.APP_ID + " %u"}
        real_command = smoke.command

        def command(*args, **_kwargs):
            if command_failure is not None and args[:len(command_failure)] == command_failure:
                return real_command(*args, **_kwargs)
            if args[:2] == ("flatpak", "kill") and kill_error is not None:
                raise kill_error
            return ""

        def wait_for(_predicate, _message):
            if proof_fails and launcher.called:
                raise RuntimeError("Installed invite review did not appear")

        def wait(*, timeout):
            if child_timeout and timeout == 5:
                raise subprocess.TimeoutExpired("launcher", timeout)
            return 0

        child.wait.side_effect = wait
        with (tempfile.TemporaryDirectory(prefix="monkeyspaw-flatpak-cleanup-") as directory,
              patch.dict("sys.modules", {"pyatspi": Mock(), "gi.repository": Mock(),
                                        "Xlib.display": Mock(), "Xlib.protocol.event": Mock()}),
              patch.dict(os.environ, DISPLAY=":99", DBUS_SESSION_BUS_ADDRESS="test", XDG_DATA_HOME=directory),
              patch.object(smoke, "command", side_effect=command),
              patch.object(smoke, "visible_windows", return_value=[]),
              patch.object(smoke, "owner", return_value=None), patch.object(smoke, "stop"),
              patch.object(smoke, "singleton"), patch.object(smoke, "wait_for", side_effect=wait_for),
              patch.object(smoke, "ThreadingHTTPServer", return_value=self.server),
              patch.object(smoke.threading, "Thread", return_value=self.thread),
              patch.object(smoke.time, "sleep"),
              patch.object(smoke.configparser, "ConfigParser", return_value=config),
              patch.object(smoke.subprocess, "Popen", launcher),
              patch.object(smoke.Path, "home", return_value=Path(directory)),
              patch.object(smoke, "print", create=True) as output):
            self.output = output
            smoke.main()

    def assert_server_closed(self):
        self.server.shutdown.assert_called_once()
        self.server.server_close.assert_called_once()
        self.thread.join.assert_called_once_with(timeout=5)

    def test_kill_failure_preserves_proof_failure_and_closes_server(self):
        for error in (RuntimeError("Installed application command failed"),
                      subprocess.TimeoutExpired("flatpak", 15)):
            with self.subTest(error=type(error).__name__):
                with self.assertRaisesRegex(RuntimeError, "Installed invite review did not appear"):
                    self.run_proof(kill_error=error)
                self.assert_server_closed()

    def test_launcher_wait_timeout_preserves_proof_failure_and_closes_server(self):
        with self.assertRaisesRegex(RuntimeError, "Installed invite review did not appear"):
            self.run_proof(child_timeout=True)
        self.assert_server_closed()

    def test_cleanup_failure_cannot_report_a_successful_proof(self):
        for kwargs, error in (({"kill_error": RuntimeError("Installed application command failed")}, RuntimeError),
                              ({"child_timeout": True}, subprocess.TimeoutExpired)):
            with self.subTest(cleanup=kwargs.keys()):
                with self.assertRaises(error):
                    self.run_proof(proof_fails=False, **kwargs)
                self.assert_server_closed()
                self.output.assert_not_called()

    def test_successful_proof_closes_server_and_reports_success(self):
        self.run_proof(proof_fails=False)
        self.assert_server_closed()
        self.output.assert_called_once()


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

    def test_unnamed_visible_nodes_do_not_hide_the_review(self):
        self.nodes.insert(0, self.node(None))
        for name in (None, ""):
            with self.subTest(name=name):
                self.nodes[0].name = name
                self.assertTrue(self.staged())

    def test_an_unnamed_destination_does_not_satisfy_review(self):
        self.nodes[1] = self.node(None)
        self.assertFalse(self.staged())

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


class AccessibilityError(RuntimeError):
    """GLib.Error's domain/code contract, without requiring GI in script tests."""

    def __init__(self, domain="atspi_error", code=0):
        super().__init__("Accessible application retired")
        self.domain = domain
        self.code = code


class AccessibilityPollingTests(unittest.TestCase):
    def run_proof(self, phase, read, *, persistent=False, missing=None, error=None):
        state = dict(owner=None, picker=False, result=False, invite=False)
        elapsed = 0
        self.snapshots = 0
        self.reads = 0
        self.poll_elapsed = None
        fixture = InviteProofTests()
        fixture.setUp()
        destination = "http://127.0.0.1:1234/paw%20base/a+b/cold-open"
        fixture.nodes[1].name = "Invite server: " + destination + "\nNo account is signed in."
        if missing == "destination":
            fixture.nodes[1].name = "Invite server: " + destination.replace("%20", " ") + "\n"
        elif missing == "frame":
            fixture.nodes[0] = fixture.node("Settings", role="label")
        elif missing == "visible-frame":
            fixture.nodes[0] = fixture.node("Settings", role="frame", visible=False)
        elif missing == "sensitive-accept":
            fixture.nodes[-1] = fixture.node("Accept and create account", sensitive=False)
        result = fixture.node("Nothing to repeat")
        test = self

        class Retired:
            @property
            def name(self):
                if read == "name":
                    test.reads += 1
                    raise error if error is not None else AccessibilityError()
                return "Settings" if phase == "invite" else "Nothing to repeat"

            def getState(self):
                test.reads += 1
                # libatspi get_state_set has no GError; retirement returns DEFUNCT.
                return SimpleNamespace(contains=lambda value: read != "state" and value == "visible")

            def getRole(self):
                test.reads += 1
                raise error if error is not None else AccessibilityError()

        retired = Retired()

        def descendants(_desktop):
            nonlocal elapsed
            active = state["invite"] if phase == "invite" else state["result"]
            if active:
                self.snapshots += 1
                if self.poll_elapsed is None:
                    self.poll_elapsed = elapsed
                if persistent or self.snapshots == 1:
                    return [retired] + (fixture.nodes[1:] if phase == "invite" else [])
            if state["invite"]:
                return fixture.nodes
            return [result] if state["result"] else []

        def action(name):
            state["owner"] = ":1.42"
            if name == "toggle":
                state["picker"] = not state["picker"]
            elif name == "repeat":
                state["result"] = True

        def stop():
            state.update(owner=None, result=False, invite=False)

        def bus(destination, method, *_args):
            self.assertEqual((destination, method), (smoke.APP_ID, "org.freedesktop.Application.Open"))
            state.update(owner=":1.42", invite=True)

        def singleton(_expected):
            if state["invite"]:
                raise RepeatProofComplete

        def windows(title):
            visible = state["picker"] if title == "Monkey's Paw" else state["result"] if title == "Repeat last" else state["invite"]
            return [123] if visible else []

        def sleep(seconds):
            nonlocal elapsed
            elapsed += seconds
            self.elapsed = elapsed

        display = SimpleNamespace(intern_atom=lambda name: name, sync=lambda: None, close=lambda: None,
            create_resource_object=lambda *_: SimpleNamespace(send_event=lambda _event: state.update(result=False)))
        atspi = SimpleNamespace(**vars(fixture.atspi), Registry=SimpleNamespace(getDesktop=lambda _: object()))
        glib = SimpleNamespace(Error=AccessibilityError,
            MainContext=SimpleNamespace(default=lambda: SimpleNamespace(pending=lambda: False)))
        config = smoke.configparser.ConfigParser(interpolation=None)
        config["Desktop Entry"] = {"Exec": "flatpak run " + smoke.APP_ID + " %u"}
        with (patch.dict("sys.modules", {"pyatspi": atspi, "gi.repository": SimpleNamespace(GLib=glib),
                                        "Xlib.display": SimpleNamespace(Display=lambda: display),
                                        "Xlib.protocol.event": SimpleNamespace(ClientMessage=lambda **event: event)}),
              patch.dict(os.environ, DISPLAY=":99", DBUS_SESSION_BUS_ADDRESS="test", XDG_DATA_HOME="/unused"),
              patch.object(smoke, "command", return_value=""), patch.object(smoke, "action", side_effect=action),
              patch.object(smoke, "stop", side_effect=stop), patch.object(smoke, "bus", side_effect=bus),
              patch.object(smoke, "owner", side_effect=lambda: state["owner"]),
              patch.object(smoke, "singleton", side_effect=singleton),
              patch.object(smoke, "visible_windows", side_effect=windows),
              patch.object(smoke, "descendants", side_effect=descendants),
              patch.object(smoke, "ThreadingHTTPServer", return_value=Mock(server_port=1234)),
              patch.object(smoke.threading, "Thread"),
              patch.object(smoke.time, "monotonic", side_effect=lambda: elapsed),
              patch.object(smoke.time, "sleep", side_effect=sleep),
              patch.object(smoke.configparser, "ConfigParser", side_effect=(lambda **_: config) if phase == "invite" else RepeatProofComplete)):
            smoke.main()

    def test_retired_name_in_repeat_poll_reaches_the_next_snapshot(self):
        with self.assertRaises(RepeatProofComplete):
            self.run_proof("repeat", "name")
        self.assertGreaterEqual(self.snapshots, 2)
        self.assertGreater(self.reads, 0)

    def test_retired_name_or_role_in_invite_poll_reaches_the_next_snapshot(self):
        for read in ("name", "role"):
            with self.subTest(read=read):
                with self.assertRaises(RepeatProofComplete):
                    self.run_proof("invite", read)
                self.assertEqual(self.snapshots, 2)
                self.assertGreater(self.reads, 0)

    def test_defunct_state_already_polls_without_a_throwing_state_read(self):
        for phase in ("repeat", "invite"):
            with self.subTest(phase=phase):
                with self.assertRaises(RepeatProofComplete):
                    self.run_proof(phase, "state")
                self.assertGreaterEqual(self.snapshots, 2)

    def test_persistent_retirement_still_times_out_at_the_existing_bound(self):
        for phase, read in (("repeat", "name"), ("invite", "name"), ("invite", "role")):
            with self.subTest(phase=phase, read=read):
                with self.assertRaisesRegex(RuntimeError, "Cold repeat did not show|Installed invite review did not appear"):
                    self.run_proof(phase, read, persistent=True)
                self.assertGreaterEqual(self.elapsed - self.poll_elapsed, 15)
                self.assertLess(self.elapsed - self.poll_elapsed, 15.21)

    def test_retirement_does_not_replace_required_invite_assertions(self):
        for missing in ("destination", "frame", "visible-frame", "sensitive-accept"):
            with self.subTest(missing=missing):
                with self.assertRaisesRegex(RuntimeError, "Installed invite review did not appear"):
                    self.run_proof("invite", "name", missing=missing)
                self.assertGreaterEqual(self.snapshots, 2)

    def test_unrelated_accessibility_and_programming_errors_still_abort(self):
        for error in (AccessibilityError(code=1), AccessibilityError(domain="other-domain"),
                      RuntimeError("Unrelated read failure")):
            for phase in ("repeat", "invite"):
                with self.subTest(error=type(error).__name__, phase=phase):
                    with self.assertRaises(RuntimeError) as raised:
                        self.run_proof(phase, "name", error=error)
                    if isinstance(error, AccessibilityError):
                        self.assertEqual(str(raised.exception), "Installed accessibility read failed")
                    else:
                        self.assertIs(raised.exception, error)
                    self.assertEqual(self.snapshots, 1)


class CommandDiagnosticTests(unittest.TestCase):
    private = "PRIVATE_COMMAND_SENTINEL"

    def fresh_script(self):
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def message(self, operation, *, phase="preflight", status=23):
        kind = "signal" if status < 0 else "exit"
        return (f"Installed application command failed (phase={phase}; operation={operation}; "
                f"kind={kind}; code={abs(status)})")

    def assert_safe(self, value):
        self.assertNotIn(self.private, value)
        self.assertNotIn("monkeyspaw://", value)

    def test_all_command_producers_have_fixed_labels_without_argument_or_error_text(self):
        for args, operation in (
            (("xdpyinfo", self.private), "display-info"),
            (("gapplication", "action", smoke.APP_ID, "toggle", self.private), "toggle"),
            (("gapplication", "action", smoke.APP_ID, "repeat", self.private), "repeat"),
            (("flatpak", "ps", "--columns=application", self.private), "instance-count"),
            (("flatpak", "kill", smoke.APP_ID, self.private), "sandbox-kill"),
            (("xdotool", "windowsize", self.private), "settings-resize"),
            ((self.private, self.private), "unclassified"),
        ):
            with self.subTest(operation=operation):
                module = self.fresh_script()
                result = subprocess.CompletedProcess(args, 23, self.private, self.private)
                with (patch.object(module.subprocess, "run", return_value=result) as run,
                      self.assertRaises(RuntimeError) as raised):
                    module.command(*args)
                self.assertEqual(str(raised.exception), self.message(operation))
                self.assert_safe(str(raised.exception))
                run.assert_called_once_with(args, capture_output=True, text=True, timeout=15)
        for method, operation in (("NameHasOwner", "name-has-owner"), ("GetNameOwner", "get-name-owner"),
                                  ("Activate", "quit"), ("Open", "invite-open"), (self.private, "unclassified")):
            with self.subTest(operation=operation):
                module = self.fresh_script()
                full_method = ("org.gtk.Actions." if method == "Activate" else
                               "org.freedesktop.Application." if method == "Open" else
                               "org.freedesktop.DBus.") + method
                args = ("gdbus", "call", "--session", "--dest", self.private, "--object-path", self.private,
                        "--method", full_method, self.private)
                result = subprocess.CompletedProcess(args, 23, self.private, self.private)
                with (patch.object(module.subprocess, "run", return_value=result),
                      self.assertRaises(RuntimeError) as raised):
                    module.command(*args)
                self.assertEqual(str(raised.exception), self.message(operation))
                self.assert_safe(str(raised.exception))

    def test_exit_and_signal_classes_are_numeric_and_still_fail(self):
        for status in (1, 23, -9):
            with self.subTest(status=status):
                module = self.fresh_script()
                result = subprocess.CompletedProcess(self.private, status, self.private, self.private)
                with (patch.object(module.subprocess, "run", return_value=result),
                      self.assertRaises(RuntimeError) as raised):
                    module.command(self.private)
                self.assertEqual(str(raised.exception), self.message("unclassified", status=status))
                self.assert_safe(str(raised.exception))

    def test_allowed_status_and_success_output_are_unchanged_and_silent(self):
        for status in (0, 1):
            module = self.fresh_script()
            output, errors = io.StringIO(), io.StringIO()
            result = subprocess.CompletedProcess(self.private, status, "  unchanged\n", self.private)
            with (patch.object(module.subprocess, "run", return_value=result),
                  redirect_stdout(output), redirect_stderr(errors)):
                self.assertEqual(module.command("flatpak", "kill", smoke.APP_ID, allowed=(0, 1)), "unchanged")
            self.assertEqual(output.getvalue() + errors.getvalue(), "")

    def test_timeout_and_os_failures_keep_the_original_exception_and_single_attempt(self):
        for error in (subprocess.TimeoutExpired(self.private, 15, output=self.private, stderr=self.private),
                      OSError(2, self.private, self.private)):
            module = self.fresh_script()
            with (patch.object(module.subprocess, "run", side_effect=error) as run,
                  self.assertRaises(type(error)) as raised):
                module.command(self.private)
            self.assertIs(raised.exception, error)
            self.assertEqual(run.call_count, 1)

    def run_cli(self, result):
        output, errors = io.StringIO(), io.StringIO()
        with (patch.dict("sys.modules", {"pyatspi": Mock(), "gi.repository": Mock(),
                                        "Xlib.display": Mock(), "Xlib.protocol.event": Mock()}),
              patch.dict(os.environ, DISPLAY=self.private, DBUS_SESSION_BUS_ADDRESS=self.private),
              patch.object(subprocess, "run", **({"side_effect": result} if isinstance(result, Exception) else {"return_value": result})),
              redirect_stdout(output), redirect_stderr(errors), self.assertRaises(SystemExit) as raised):
            runpy.run_path(str(ROOT / "scripts/flatpak-smoke.py"), run_name="__main__")
        self.assertEqual(raised.exception.code, 1)
        self.assertEqual(output.getvalue(), "")
        self.assert_safe(errors.getvalue())
        return errors.getvalue()

    def test_cli_emits_only_safe_actionable_command_metadata(self):
        result = subprocess.CompletedProcess(self.private, 23, self.private, self.private)
        self.assertEqual(self.run_cli(result), self.message("display-info") + "\n")

    def test_cli_never_renders_unexpected_exception_messages(self):
        for error in (subprocess.TimeoutExpired(self.private, 15, output=self.private, stderr=self.private),
                      OSError(2, self.private, self.private)):
            self.assertEqual(self.run_cli(error), "Installed Flatpak proof failed (no invite data is logged)\n")

    def test_cold_open_command_failure_keeps_its_phase_through_cleanup(self):
        fixture = CleanupProofTests()
        result = subprocess.CompletedProcess(self.private, 23, self.private, self.private)
        with (patch.object(smoke.subprocess, "run", return_value=result) as run,
              self.assertRaises(RuntimeError) as raised):
            fixture.run_proof(proof_fails=False, command_failure=("gdbus", "call"))
        self.assertEqual(str(raised.exception), self.message("invite-open", phase="cold-open"))
        self.assert_safe(str(raised.exception))
        self.assertEqual(run.call_count, 1)
        fixture.assert_server_closed()
        fixture.output.assert_not_called()

    def test_cleanup_command_failure_cannot_replace_proof_error_or_print_success(self):
        for proof_fails in (True, False):
            with self.subTest(proof_fails=proof_fails):
                fixture = CleanupProofTests()
                result = subprocess.CompletedProcess(self.private, 23, self.private, self.private)
                with (patch.object(smoke.subprocess, "run", return_value=result) as run,
                      self.assertRaises(RuntimeError) as raised):
                    fixture.run_proof(proof_fails=proof_fails, command_failure=("flatpak", "kill"))
                expected = "Installed invite review did not appear" if proof_fails else self.message("sandbox-kill", phase="cleanup")
                self.assertEqual(str(raised.exception), expected)
                self.assert_safe(str(raised.exception))
                self.assertEqual(run.call_count, 1)
                fixture.assert_server_closed()
                fixture.child.kill.assert_called()
                fixture.child.wait.assert_any_call(timeout=5)
                fixture.output.assert_not_called()


if __name__ == "__main__":
    unittest.main()
