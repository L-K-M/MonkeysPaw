#!/usr/bin/env bash
# Run inside a private dbus-run-session and Xvfb; CI bounds this whole script.
set -euo pipefail

smoke_binary=$(realpath "${1:-.build/debug/monkeyspaw}")
smoke_directory=$(mktemp -d)
smoke_app_id=ch.lkmc.monkeyspaw
smoke_app_path=/${smoke_app_id//./\/}
smoke_wait_attempts=100
smoke_poll_seconds=0.1
smoke_call_timeout=3
smoke_app_pid=
smoke_terminal_pid=
smoke_wm_pid=

cleanup() {
    local status=$?
    if (( status != 0 )); then
        printf 'Linux delivery smoke failed (status %s).\n' "$status" >&2
        if [[ -n "$smoke_app_pid" ]] && kill -0 "$smoke_app_pid" 2>/dev/null; then
            printf 'The resident app is still running (pid %s).\n' "$smoke_app_pid" >&2
        else
            printf 'The resident app is not running.\n' >&2
        fi
        timeout "$smoke_call_timeout" gapplication list-actions "$smoke_app_id" \
            >"$smoke_directory/static-actions.stdout" 2>"$smoke_directory/static-actions.stderr" || true
        printf 'gapplication list-actions stdout:\n' >&2
        cat "$smoke_directory/static-actions.stdout" >&2
        printf 'gapplication list-actions stderr:\n' >&2
        cat "$smoke_directory/static-actions.stderr" >&2
        if [[ -f "$smoke_directory/actions.stdout" ]]; then
            printf 'org.gtk.Actions.List stdout:\n' >&2
            cat "$smoke_directory/actions.stdout" >&2
            printf 'org.gtk.Actions.List stderr:\n' >&2
            cat "$smoke_directory/actions.stderr" >&2
        fi
        printf 'Session D-Bus names:\n' >&2
        timeout "$smoke_call_timeout" dbus-send --session --print-reply \
            --dest=org.freedesktop.DBus / org.freedesktop.DBus.ListNames >&2 2>&1 || true
        # App diagnostics contain no prompt or subprocess error bodies. Never
        # print the received file, clipboard, or xdotool's output/error stream.
        if [[ -f "$smoke_directory/app.stderr" ]]; then
            cat "$smoke_directory/app.stderr" >&2
        fi
        for process in "$smoke_app_pid" "$smoke_terminal_pid" "$smoke_wm_pid"; do
            if [[ -n "$process" ]] && ! kill -0 "$process" 2>/dev/null; then
                printf 'Smoke process %s exited before completion.\n' "$process" >&2
            fi
        done
    fi
    for process in "$smoke_app_pid" "$smoke_terminal_pid" "$smoke_wm_pid"; do
        if [[ -n "$process" ]]; then kill "$process" 2>/dev/null || true; fi
    done
    rm -rf "$smoke_directory"
}
trap cleanup EXIT

wait_for() {
    local description=$1
    shift
    for (( attempt=0; attempt<smoke_wait_attempts; attempt++ )); do
        if "$@"; then return 0; fi
        sleep "$smoke_poll_seconds"
    done
    printf 'Timed out waiting for %s.\n' "$description" >&2
    return 1
}

wm_ready() {
    local property
    property=$(timeout "$smoke_call_timeout" xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null) || return 1
    [[ "$property" =~ 0x[[:xdigit:]]+ ]]
}

app_ready() {
    kill -0 "$smoke_app_pid" 2>/dev/null || return 1
    local actions
    # gapplication list-actions reads static .desktop actions, including when
    # the app is stopped. Query the resident application's exported group.
    timeout "$smoke_call_timeout" gdbus call --session --dest "$smoke_app_id" \
        --object-path "$smoke_app_path" --method org.gtk.Actions.List \
        >"$smoke_directory/actions.stdout" 2>"$smoke_directory/actions.stderr" || return 1
    actions=$(<"$smoke_directory/actions.stdout")
    [[ "$actions" == *"'toggle'"* && "$actions" == *"'selftest'"* && "$actions" == *"'quit'"* ]]
}

terminal_ready() {
    [[ -f "$smoke_directory/terminal.ready" ]] || return 1
    smoke_terminal_window=$(timeout "$smoke_call_timeout" xdotool search --onlyvisible \
        --name '^monkeyspaw-smoke-target$' 2>/dev/null) || return 1
    [[ -n "$smoke_terminal_window" ]]
}

panel_ready() {
    smoke_panel_window=$(timeout "$smoke_call_timeout" xdotool search --onlyvisible \
        --name "^Monkey's Paw$" 2>/dev/null) || return 1
    [[ -n "$smoke_panel_window" ]]
}

delivery_received() {
    python3 - "$smoke_directory/received" <<'PY'
import pathlib
import sys
expected = b"Monkey's Paw test: if you can read this, delivery works."
try:
    received = pathlib.Path(sys.argv[1]).read_bytes()
except FileNotFoundError:
    sys.exit(1)
sys.exit(0 if received == expected else 1)
PY
}

action_report_received() {
    python3 - "$smoke_directory/app.stdout" <<'PY'
import json
import pathlib
import sys
try:
    json.loads(pathlib.Path(sys.argv[1]).read_text())
except (OSError, ValueError):
    sys.exit(1)
PY
}

app_exited() { ! kill -0 "$smoke_app_pid" 2>/dev/null; }

# Xvfb supplies a display, but no compositor refocus. Openbox supplies the
# ordinary X11 hide/refocus behavior, rather than adding it to the app driver.
openbox --sm-disable >"$smoke_directory/wm.log" 2>&1 &
smoke_wm_pid=$!
wait_for 'the X11 window manager' wm_ready

"$smoke_binary" --gapplication-service >"$smoke_directory/app.stdout" 2>"$smoke_directory/app.stderr" &
smoke_app_pid=$!
wait_for 'D-Bus actions on the resident app' app_ready

# Raw input lets cat write bytes without a newline. No synthetic Enter is sent
# to a shell or chat field. Explicit translations make this xterm's paste chord
# independent of distro X resources.
# The inner shell, not this script, expands its positional output-file argument.
# shellcheck disable=SC2016
xterm -title monkeyspaw-smoke-target -class XTerm \
    -xrm 'XTerm*VT100.translations: #override Ctrl Shift <Key>V: insert-selection(CLIPBOARD)' \
    -e /bin/sh -c 'stty -echo -icanon; : > "$2"; exec cat > "$1"' sh \
    "$smoke_directory/received" "$smoke_directory/terminal.ready" \
    >"$smoke_directory/terminal.log" 2>&1 &
smoke_terminal_pid=$!
wait_for 'the xterm target' terminal_ready
timeout "$smoke_call_timeout" xdotool windowactivate --sync "$smoke_terminal_window" >/dev/null 2>&1

timeout "$smoke_call_timeout" gapplication action "$smoke_app_id" toggle
wait_for 'the canned picker' panel_ready
timeout "$smoke_call_timeout" xdotool windowactivate --sync "$smoke_panel_window" >/dev/null 2>&1
smoke_panel_class=$(timeout "$smoke_call_timeout" xprop -id "$smoke_panel_window" WM_CLASS 2>/dev/null)
if [[ "${smoke_panel_class,,}" != "wm_class(string) = \"$smoke_app_id\", \"$smoke_app_id\"" ]]; then
    printf 'The picker WM_CLASS does not match the application identity.\n' >&2
    exit 1
fi

# Exercise the real picker key handler, then Core's settle and the xdotool
# backend. Automatic terminal-class selection is scheduled for M7.
timeout "$smoke_call_timeout" xdotool key --clearmodifiers ctrl+shift+Return >/dev/null 2>&1
wait_for 'the exact canned text in xterm through xdotool' delivery_received
printf 'X11 toggle, terminal confirmation, compositor refocus and paste passed.\n'

# Also prove that a forwarded CLI diagnostic returns JSON to its own stdout,
# while the original service remains resident. Readback must prove receipt.
timeout 20 "$smoke_binary" --selftest >"$smoke_directory/report.json" 2>"$smoke_directory/cli.stderr"
kill -0 "$smoke_app_pid"
timeout "$smoke_call_timeout" gapplication action "$smoke_app_id" selftest
wait_for 'the D-Bus selftest action report' action_report_received
python3 - "$smoke_directory/report.json" "$smoke_directory/app.stdout" <<'PY'
import json
import pathlib
import sys
for filename in sys.argv[1:]:
    report = json.loads(pathlib.Path(filename).read_text())
    if report['session'] != {'otherX11': {}}:
        raise SystemExit('Self-test did not detect the X11 session')
    if not any(item['backend'] == 'xdotool' and item['status'] == {'pasted': {}}
               for item in report['results']):
        raise SystemExit('Self-test did not verify text receipt through xdotool')
print('CLI and D-Bus self-test reports verified xdotool receipt.')
PY

timeout "$smoke_call_timeout" gapplication action "$smoke_app_id" quit
wait_for 'the resident app to exit' app_exited
wait "$smoke_app_pid"
smoke_app_pid=

# A standalone diagnostic on GNOME must not run the shortcut installer.
mkdir "$smoke_directory/diagnostic-tools"
cat >"$smoke_directory/diagnostic-tools/gsettings" <<'SH'
#!/bin/sh
printf 'called\n' >> "$MONKEYSPAW_SMOKE_GSETTINGS_LOG"
exit 1
SH
chmod +x "$smoke_directory/diagnostic-tools/gsettings"
env PATH="$smoke_directory/diagnostic-tools:$PATH" XDG_CURRENT_DESKTOP=GNOME \
    MONKEYSPAW_SMOKE_GSETTINGS_LOG="$smoke_directory/gsettings.calls" \
    timeout 20 "$smoke_binary" --selftest >"$smoke_directory/standalone.json" 2>"$smoke_directory/cli.stderr"
if [[ -e "$smoke_directory/gsettings.calls" ]]; then
    printf 'The standalone diagnostic called the GNOME shortcut installer.\n' >&2
    exit 1
fi
python3 - "$smoke_directory/standalone.json" <<'PY'
import json
import pathlib
import sys
report = json.loads(pathlib.Path(sys.argv[1]).read_text())
if report['session'] != {'gnomeX11': {}}:
    raise SystemExit('Standalone diagnostic did not detect GNOME X11')
print('Standalone diagnostic returned JSON without installing shortcuts.')
PY
