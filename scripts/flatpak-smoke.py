#!/usr/bin/env python3
"""Exercise installed GApplication exports under a disposable bus and display.

Needs python3-pyatspi, python3-xlib and at-spi2-core. No product test hook or invite parser:
observe mapped X11 windows, read the GTK accessibility tree and record loopback HTTP requests.
Never print subprocess arguments, invite input or accessibility tree contents.
"""

import configparser
from contextlib import closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import threading
import time
from urllib.parse import quote


APP_ID = "ch.lkmc.monkeyspaw"


def command(*args, allowed=(0,)):
    result = subprocess.run(args, capture_output=True, text=True, timeout=15)
    if result.returncode not in allowed:
        raise RuntimeError("Installed application command failed")
    return result.stdout.strip()


def bus(destination, method, *args):
    path = "/org/freedesktop/DBus" if destination == "org.freedesktop.DBus" else "/ch/lkmc/monkeyspaw"
    return command("gdbus", "call", "--session", "--dest", destination,
                   "--object-path", path, "--method", method, *args)


def owner():
    exists = bus("org.freedesktop.DBus", "org.freedesktop.DBus.NameHasOwner", APP_ID)
    return bus("org.freedesktop.DBus", "org.freedesktop.DBus.GetNameOwner", APP_ID) if exists == "(true,)" else None


def wait_for(predicate, message):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.2)
    raise RuntimeError(message)


def action(name):
    command("gapplication", "action", APP_ID, name)


def stop():
    # A unique name cannot cold-activate a replacement during shutdown.
    current = owner()
    if current:
        name = current.split("'")[1]
        bus(name, "org.gtk.Actions.Activate", "quit", "[]", "{}")
        wait_for(lambda: owner() is None, "Installed application did not quit")


def singleton(expected):
    def one_instance():
        if not expected or owner() != expected:
            raise RuntimeError("Activation replaced the primary application")
        instances = command("flatpak", "ps", "--columns=application").splitlines()
        return instances.count(APP_ID) == 1

    # Flatpak retains newly created instance records for at least three seconds,
    # including exited tooling sandboxes and resident URI-forwarding launchers.
    wait_for(one_instance, "Expected exactly one installed application instance")


def visible_windows(title):
    from Xlib import X
    from Xlib.display import Display
    from Xlib.error import BadWindow

    # Xvfb has no window manager: app toplevels are direct root children.
    # Match class and title independently; xdotool search accepts only one pattern.
    with closing(Display()) as display:
        matches = []
        for window in display.screen().root.query_tree().children:
            try:
                if (window.get_attributes().map_state == X.IsViewable
                        and any(value.lower() == APP_ID for value in (window.get_wm_class() or ()))
                        and window.get_wm_name() == title):
                    matches.append(window.id)
            except BadWindow:
                # A window may close between enumeration and property reads.
                continue
        return matches


def descendants(node):
    yield node
    for child in node:
        if child is not None:
            yield from descendants(child)


def invite_is_staged(nodes, destination, atspi):
    visible = [node for node in nodes if node.getState().contains(atspi.STATE_SHOWING)]
    names = [node.name or "" for node in visible]
    return (
        sum(node.name == "Settings" and node.getRole() == atspi.ROLE_FRAME for node in visible) == 1
        and any(name.startswith("Invite server: " + destination + "\n") for name in names)
        and "Review the server and account before accepting. Opening an invite does not use it." in names
        and any(node.name == "Accept and create account"
                and node.getState().contains(atspi.STATE_SENSITIVE) for node in visible)
        and "Invite accepted." not in names
    )


def main():
    import pyatspi
    from gi.repository import GLib
    from Xlib.display import Display
    from Xlib.protocol.event import ClientMessage

    if not os.environ.get("DISPLAY") or not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        raise RuntimeError("A private bus and required display are missing")
    command("xdpyinfo")
    desktop = pyatspi.Registry.getDesktop(0)
    context = GLib.MainContext.default()

    def nodes():
        # Drain accessibility lifecycle/property events between cold launches.
        for _ in range(100):
            if not context.pending():
                break
            context.iteration(False)
        try:
            return list(descendants(desktop))
        except Exception:
            # Accessibility objects can retire between a quit and a cold launch.
            return []

    def label_visible(label):
        return any(node.name == label and node.getState().contains(pyatspi.STATE_SHOWING) for node in nodes())

    def repeat_windows():
        return visible_windows("Repeat last")

    def dismiss_repeat_result():
        windows = repeat_windows()
        if len(windows) != 1:
            return False
        # Xvfb has no window manager or guaranteed titlebar Close button.
        # Send the normal close request so GTK's hide-on-close keeps the window reusable.
        with closing(Display()) as display:
            window = display.create_resource_object("window", int(windows[0]))
            window.send_event(ClientMessage(window=window, client_type=display.intern_atom("WM_PROTOCOLS"),
                                           data=(32, [display.intern_atom("WM_DELETE_WINDOW"), 0, 0, 0, 0])))
            display.sync()
        return True

    def picker_visible():
        return bool(visible_windows("Monkey's Paw"))

    def show_review():
        windows = visible_windows("Settings")
        if len(windows) != 1:
            return False
        # Account's invite form is below its login form; keep both in view on
        # the tall Xvfb screen, without clicking or typing into either form.
        command("xdotool", "windowsize", str(windows[0]), "1000", "2200")
        return True

    class Recorder(BaseHTTPRequestHandler):
        requests = 0

        def do_POST(self):
            type(self).requests += 1
            self.send_response(403)
            self.end_headers()

        do_GET = do_POST

        def log_message(self, *_args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Recorder)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    clients = []
    bearers = []
    try:
        if owner() is not None:
            raise RuntimeError("Proof requires a cold installed application")
        action("toggle")
        wait_for(picker_visible, "Cold toggle did not show the picker")
        primary = owner()
        # The action debounce must settle before the resident toggle.
        time.sleep(1)
        action("toggle")
        wait_for(lambda: not picker_visible(), "Resident toggle did not hide the picker")
        singleton(primary)
        stop()
        action("repeat")
        wait_for(lambda: label_visible("Nothing to repeat"), "Cold repeat did not show its empty-record result")
        primary = owner()
        wait_for(dismiss_repeat_result, "Cold repeat result could not be dismissed")
        wait_for(lambda: not repeat_windows() and not label_visible("Nothing to repeat"),
                 "Cold repeat result did not dismiss")
        action("repeat")
        wait_for(lambda: repeat_windows() and label_visible("Nothing to repeat"),
                 "Resident repeat did not show its empty-record result")
        singleton(primary)
        stop()

        config = configparser.ConfigParser(interpolation=None)
        config.read(Path(os.environ["XDG_DATA_HOME"]) / "flatpak/exports/share/applications" / (APP_ID + ".desktop"))
        launcher = shlex.split(config["Desktop Entry"]["Exec"])
        if "%u" not in launcher or Path(launcher[0]).name != "flatpak":
            raise RuntimeError("Installed launcher does not forward an invite URI")

        for route in ("cold-open", "resident-open", "resident-launcher", "cold-launcher"):
            if route.startswith("cold"):
                stop()
            primary = owner()
            token = secrets.token_urlsafe(32)
            destination = f"http://127.0.0.1:{server.server_port}/paw%20base/a+b/{route}"
            # Exercise double-escaped URL bytes, plus, and an encoded token byte.
            uri = "monkeyspaw://join?server=" + quote(destination, safe="") + "&token=%" + f"{ord(token[0]):02X}" + token[1:]
            bearers.extend((token.encode(), uri.encode()))
            if route.endswith("open"):
                bus(APP_ID, "org.freedesktop.Application.Open", "['" + uri + "']", "{}")
            else:
                arguments = [uri if value == "%u" else value for value in launcher]
                child = subprocess.Popen(arguments, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                clients.append(child)
                if primary:
                    if child.wait(timeout=15) != 0:
                        raise RuntimeError("Resident launcher failed")
            wait_for(show_review, "Installed Settings window did not appear")
            wait_for(lambda: invite_is_staged(nodes(), destination, pyatspi), "Installed invite review did not appear")
            singleton(primary or owner())
            if picker_visible():
                raise RuntimeError("Invite activation toggled the picker")
            if Recorder.requests:
                raise RuntimeError("Invite activation made an HTTP request before Accept")
        # Give any wrongly scheduled redemption time to reach the recorder.
        time.sleep(1)
        if Recorder.requests:
            raise RuntimeError("Invite activation redeemed without Accept")
        stop()
        for child in clients:
            if child.wait(timeout=15) != 0:
                raise RuntimeError("Installed launcher exited unsuccessfully")
        state = Path.home() / ".var/app" / APP_ID
        for file in state.rglob("*"):
            if file.is_file() and not file.is_symlink():
                data = file.read_bytes()
                if any(token in data for token in bearers):
                    raise RuntimeError("Invite bearer was persisted")
    finally:
        proof_failed = sys.exc_info()[0] is not None
        cleanup_error = None
        try:
            command("flatpak", "kill", APP_ID, allowed=(0, 1))
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            cleanup_error = error
        for child in clients:
            try:
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=5)
            except (OSError, subprocess.SubprocessError) as error:
                cleanup_error = cleanup_error or error
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        # Keep the proof's original error while still attempting every cleanup.
        if cleanup_error is not None and not proof_failed:
            raise cleanup_error
    print("Installed Flatpak: cold/resident actions and invite review passed; no redemption or persisted bearer")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except Exception:
        # Exception strings/tracebacks can include subprocess argv or UI input.
        print("Installed Flatpak proof failed (no invite data is logged)", file=sys.stderr)
        sys.exit(1)
