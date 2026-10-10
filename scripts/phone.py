#!/usr/bin/env python3
"""Drive the app on the iPhone from the Mac: the phone driver of FLEX builds (Diagnostics/Driver.m).

    scripts/phone.py tree                              # the visible screen's view tree, as make trees records it
    scripts/phone.py state                             # now playing, the top controller, what is presented, menu up
    scripts/phone.py find --class UILabel              # every match with its index, frame (screen points), id, label, text
    scripts/phone.py tap --id X | --label X | --text X | --class C [--index N] | --at X,Y
    scripts/phone.py longpress --id X [--duration 1]
    scripts/phone.py swipe --from X,Y --to X,Y [--duration 0.2]     # or a view and --by DX,DY; a quick one flings
    scripts/phone.py swipe --id X --by 0,-300 --drag 1              # a slow drag held still before letting go
    scripts/phone.py scroll [--id X | --at X,Y] --by 0,400 [--animated 1]   # the page's list when no view is named
    scripts/phone.py type "some text"                  # into the first responder (tap a field first)
    scripts/phone.py player.open | player.close | player.more
    scripts/phone.py menu.pick "Sleep timer"
    scripts/phone.py play | pause | next
    scripts/phone.py seek 42
    scripts/phone.py tab 0 | tab Search
    scripts/phone.py settings.open
    scripts/phone.py settings.page "Appearance"
    scripts/phone.py pref --key spotifyglass.font --value 6     # a setting, as a whole number (--text for a string, --remove 1)
    scripts/phone.py wait --id X [--gone 1] [--timeout 5]
    scripts/phone.py wait --menu 1 [--gone 1]
    scripts/phone.py wait --log "system menu: the player's menu is up" --timeout 3
    scripts/phone.py log [--since N]                   # the app's last SGLog lines; each has a seq
    scripts/phone.py screenshot out.png [--scale 1]

Every command prints the app's JSON answer, {"ok": true, ...} or {"ok": false, "error": ...}, and exits 1
when it is not ok. --label and --text match whole and ignore case; --contains 1 matches a part. Points are
screen points, the frame `find` prints. A log wait looks at the lines since the last command that did
something began, so `player.more` then `wait --log ...` sees a line that came before the wait.

The server listens on the phone's loopback only, port 8085, so this goes through iproxy over USB: it uses
whatever already answers on 127.0.0.1:8085 (an iproxy left running, or the simulator, whose apps share the
Mac's loopback) and otherwise starts iproxy and leaves it running for the next call. PHONE_PORT changes the
port. Over Tailscale: PHONE_HOST=100.71.6.75 scripts/phone.py state (PHONE_TOKEN, or the token from the
device log; FLEX builds listen on the phone's Tailscale address too, token required). Needs a FLEX build (make install FLEX=1) open in the foreground: iOS suspends it in the background.
"""
import base64
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PORT = int(os.environ.get("PHONE_PORT", "8085"))
# Over Tailscale instead of the cable: the phone's tailnet address and the token the app logs at launch
# ("driver: tailnet listener on 100.x.y.z:8085, token ..."), read from the device log when not given.
HOST = os.environ.get("PHONE_HOST")
LOG = "/tmp/claude-501/device.log"


def token():
    if os.environ.get("PHONE_TOKEN"):
        return os.environ["PHONE_TOKEN"]
    try:
        with open(LOG, errors="replace") as f:
            found = re.findall(r"driver: tailnet listener on \S+, token ([0-9a-f]{32})", f.read())
    except OSError:
        found = []
    if not found:
        sys.exit(f"no PHONE_TOKEN and no token in {LOG}: run once over the cable, or read it from the app's log")
    return found[-1]
# The argument a command takes without a flag.
POSITIONAL = {"type": "text", "menu.pick": "title", "seek": "seconds", "tab": "arg", "settings.page": "title"}


def port_open():
    try:
        with socket.create_connection(("127.0.0.1", PORT), timeout=0.5):
            return True
    except OSError:
        return False


def ensure_tunnel():
    if port_open():
        return
    if not shutil.which("iproxy"):
        sys.exit(f"nothing answers on 127.0.0.1:{PORT} and there is no iproxy (brew install libimobiledevice)")
    subprocess.Popen(["iproxy", f"{PORT}:{PORT}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    for _ in range(30):
        if port_open():
            return
        time.sleep(0.1)
    sys.exit(f"iproxy did not open 127.0.0.1:{PORT}: is the iPhone plugged in and trusted?")


def fetch(path, timeout):
    # The header the app asks of a driver command, which a web page on the phone cannot send.
    headers = {"X-Phone-Driver": "1"}
    if HOST:
        headers["X-Phone-Token"] = token()
        url = f"http://{HOST}:{PORT}/{path}"
    else:
        ensure_tunnel()
        url = f"http://127.0.0.1:{PORT}/{path}"
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return e.read().decode("utf-8", "replace")
    except (urllib.error.URLError, ConnectionError, socket.timeout) as e:
        sys.exit(f"the app did not answer ({e}): is a FLEX build open in the foreground?")


def parse(args):
    """`cmd --key value ... [positional]` into the command and its query items."""
    params, rest = {}, list(args)
    while rest:
        arg = rest.pop(0)
        if arg.startswith("--") and len(arg) > 2:
            key = arg[2:]
            params[key] = rest.pop(0) if rest and not rest[0].startswith("--") else "1"
        else:
            params.setdefault("arg", arg)
    return params


def run(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    command, params = argv[0], parse(argv[1:])
    if command == "tree":
        print(fetch("tree", 15), end="")
        return 0
    out = None
    if command == "screenshot":
        out = params.pop("arg", None)
        if not out:
            sys.exit("screenshot takes the path to save the PNG to")
    if "arg" in params and command in POSITIONAL:
        params[POSITIONAL[command]] = params.pop("arg")
    timeout = float(params.get("timeout", 5)) + float(params.get("duration", 0)) + 15
    text = fetch(f"{urllib.parse.quote(command)}?{urllib.parse.urlencode(params, quote_via=urllib.parse.quote)}", timeout)
    try:
        answer = json.loads(text)
    except ValueError:
        sys.exit(f"not a driver answer (a build without the driver serves only the tree):\n{text[:300]}")
    if out and answer.get("ok"):
        with open(out, "wb") as f:
            f.write(base64.b64decode(answer.pop("png")))
        answer["saved"] = os.path.abspath(out)
    print(json.dumps(answer, indent=1, ensure_ascii=False, sort_keys=True))
    return 0 if answer.get("ok") else 1


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:]))
