#!/usr/bin/env python3
"""WLAN helper for the GL-RM1 PoE (marv-kvm).

Switches wlan0 between access-point and client mode, scans for networks,
and changes the hostname and the AP credentials. Runs over SSH and over
the serial console - plain curses, no external dependencies.

The actual mode switching is done by wlan-apply.sh, which is started
detached. That matters: if you switch from AP to client while connected
over the AP, your session dies mid-switch. wlan-apply.sh finishes anyway
and falls back to AP mode if the new network does not come up.
"""

import curses
import os
import re
import subprocess
import sys
import time

D = "/userdata/wlan-ap"
MODE_FILE = os.path.join(D, "mode")
STATE_FILE = os.path.join(D, "state")
CLIENT_CONF = os.path.join(D, "wifi-client.conf")
HOSTAPD_CONF = os.path.join(D, "hostapd.conf")
APPLY = os.path.join(D, "wlan-apply.sh")
WPA_SUPPLICANT = os.path.join(D, "wpa_supplicant")

IFACE = "wlan0"
ETH = "eth0"


# ------------------------------------------------------------------ shell


def sh(cmd, timeout=20):
    """Run a shell command, return (rc, stdout+stderr)."""
    try:
        p = subprocess.run(
            cmd,
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
        return p.returncode, p.stdout.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return 124, ""


def read_file(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def write_file(path, text, mode=0o600):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)


# ----------------------------------------------------------------- status


def iface_ip(iface):
    _, out = sh("ip -4 addr show %s 2>/dev/null" % iface)
    m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", out)
    return m.group(1) if m else ""


def eth_status():
    _, out = sh("ip -o link show %s 2>/dev/null" % ETH)
    if not out.strip():
        return "absent", ""
    up = "state UP" in out or "LOWER_UP" in out
    ip = iface_ip(ETH)
    if up and ip:
        return "up", ip
    if up:
        return "up", "no address"
    return "down", ""


def link_info():
    """SSID and signal in client mode."""
    _, out = sh("iw dev %s link 2>/dev/null" % IFACE)
    if "Not connected" in out or not out.strip():
        return "", ""
    ssid = re.search(r"SSID: (.+)", out)
    sig = re.search(r"signal: (-?\d+) dBm", out)
    return (ssid.group(1).strip() if ssid else ""), (sig.group(1) if sig else "")


def ap_ssid():
    conf = read_file(HOSTAPD_CONF)
    m = re.search(r"^ssid=(.*)$", conf, re.M)
    return m.group(1) if m else "?"


def current_mode():
    return read_file(MODE_FILE, "ap") or "ap"


def current_state():
    return read_file(STATE_FILE, "unknown") or "unknown"


def gather_status():
    mode = current_mode()
    state = current_state()
    ip = iface_ip(IFACE)
    ssid, signal = link_info()
    eth_state, eth_ip = eth_status()
    return {
        "mode": mode,
        "state": state,
        "ip": ip or "-",
        "ssid": ssid or (ap_ssid() if mode == "ap" else "-"),
        "signal": signal,
        "eth_state": eth_state,
        "eth_ip": eth_ip,
        "host": read_file("/proc/sys/kernel/hostname", "?"),
    }


# ------------------------------------------------------------------- scan


def scan_networks():
    """Scan for networks. Returns (list_of_dicts, error_string)."""
    sh("ip link set %s up 2>/dev/null" % IFACE)
    rc, out = sh("iw dev %s scan 2>&1" % IFACE, timeout=30)
    if rc != 0:
        if "Device or resource busy" in out or "Operation not supported" in out:
            return [], "busy"
        return [], out.strip().splitlines()[0] if out.strip() else "scan failed"

    nets = {}
    cur = None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("BSS "):
            cur = {"ssid": "", "signal": -100, "enc": "open"}
        elif cur is None:
            continue
        elif line.startswith("signal:"):
            m = re.search(r"(-?\d+\.?\d*) dBm", line)
            if m:
                cur["signal"] = int(float(m.group(1)))
        elif line.startswith("SSID:"):
            cur["ssid"] = line[5:].strip()
            if cur["ssid"]:
                prev = nets.get(cur["ssid"])
                if prev is None or cur["signal"] > prev["signal"]:
                    nets[cur["ssid"]] = cur
        elif line.startswith("RSN:"):
            cur["enc"] = "WPA2"
        elif line.startswith("WPA:") and cur["enc"] == "open":
            cur["enc"] = "WPA"

    result = sorted(nets.values(), key=lambda n: -n["signal"])
    return result, ""


# ------------------------------------------------------------- config I/O


def write_client_conf(ssid, psk):
    lines = ["ctrl_interface=/var/run/wpa_supplicant", "network={",
             '\tssid="%s"' % ssid]
    if psk:
        lines.append('\tpsk="%s"' % psk)
    else:
        lines.append("\tkey_mgmt=NONE")
    lines.append("}")
    write_file(CLIENT_CONF, "\n".join(lines) + "\n")


def set_ap_credentials(ssid, passphrase):
    conf = read_file(HOSTAPD_CONF)
    if ssid:
        conf = re.sub(r"^ssid=.*$", "ssid=" + ssid, conf, flags=re.M)
    if passphrase:
        conf = re.sub(r"^wpa_passphrase=.*$", "wpa_passphrase=" + passphrase,
                      conf, flags=re.M)
    write_file(HOSTAPD_CONF, conf + "\n")


def set_hostname(name):
    write_file("/etc/hostname", name + "\n", 0o644)
    sh("hostname %s" % name)


def apply_mode(mode):
    """Write the mode file and start wlan-apply.sh detached."""
    write_file(MODE_FILE, mode + "\n", 0o644)
    write_file(STATE_FILE, "applying\n", 0o644)
    sh("setsid %s >>/var/log/wlan-ap.log 2>&1 &" % APPLY, timeout=5)


# --------------------------------------------------------------------- UI

C_FRAME = 1
C_TITLE = 2
C_ITEM = 3
C_SEL = 4
C_KEYS = 5
C_WARN = 6
C_OK = 7
C_DIM = 8


def init_colors():
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(C_FRAME, curses.COLOR_CYAN, curses.COLOR_BLUE)
    curses.init_pair(C_TITLE, curses.COLOR_YELLOW, curses.COLOR_BLUE)
    curses.init_pair(C_ITEM, curses.COLOR_WHITE, curses.COLOR_BLUE)
    curses.init_pair(C_SEL, curses.COLOR_BLACK, curses.COLOR_CYAN)
    curses.init_pair(C_KEYS, curses.COLOR_BLACK, curses.COLOR_CYAN)
    curses.init_pair(C_WARN, curses.COLOR_RED, curses.COLOR_BLUE)
    curses.init_pair(C_OK, curses.COLOR_GREEN, curses.COLOR_BLUE)
    curses.init_pair(C_DIM, curses.COLOR_CYAN, curses.COLOR_BLUE)


def box(win, y, x, h, w, title=""):
    """Frame in Norton style.

    Drawn with the curses alternate character set rather than literal
    box-drawing characters. The device has no locales installed, so the
    terminal encoding can be plain ASCII - writing U+2554 and friends
    into it raises UnicodeEncodeError. ACS_* leaves the choice to
    terminfo and degrades to +-| where the terminal cannot do better.
    """
    a = curses.color_pair(C_FRAME)
    try:
        win.addch(y, x, curses.ACS_ULCORNER, a)
        win.hline(y, x + 1, curses.ACS_HLINE, w - 2, a)
        win.addch(y, x + w - 1, curses.ACS_URCORNER, a)
        for i in range(1, h - 1):
            win.addch(y + i, x, curses.ACS_VLINE, a)
            win.addch(y + i, x + w - 1, curses.ACS_VLINE, a)
        win.addch(y + h - 1, x, curses.ACS_LLCORNER, a)
        win.hline(y + h - 1, x + 1, curses.ACS_HLINE, w - 2, a)
        win.addch(y + h - 1, x + w - 1, curses.ACS_LRCORNER, a)
        if title:
            t = " " + title + " "
            win.addstr(y, x + (w - len(t)) // 2, t,
                       curses.color_pair(C_TITLE) | curses.A_BOLD)
    except curses.error:
        pass


def read_key(win):
    """getch() that tells arrow keys and a real Esc apart.

    keypad(True) covers terminals that honour smkx and then send the
    application-mode sequence (ESC O B). Terminals that ignore smkx keep
    sending ESC [ B, which ncurses does not translate - the bare 27
    arrives first and looks exactly like Esc. So on 27 we peek briefly:
    if a sequence follows, it was an arrow key, otherwise it was Esc.
    """
    c = win.getch()
    if c != 27:
        return c
    win.timeout(60)
    try:
        c2 = win.getch()
        if c2 == -1:
            return 27
        c3 = win.getch()
    finally:
        win.timeout(-1)
    if c2 in (ord("["), ord("O")):
        return {ord("A"): curses.KEY_UP,
                ord("B"): curses.KEY_DOWN,
                ord("H"): curses.KEY_HOME,
                ord("F"): curses.KEY_END}.get(c3, 27)
    return 27


def safe_addstr(win, y, x, text, attr=0):
    """addstr that never takes the program down.

    Besides the usual curses.error at the screen edge this also has to
    survive text the terminal cannot encode - an SSID with an umlaut or
    an emoji is entirely normal and must not crash the menu.
    """
    try:
        win.addstr(y, x, text, attr)
        return
    except curses.error:
        return
    except (UnicodeEncodeError, UnicodeError, ValueError):
        pass
    try:
        win.addstr(y, x, text.encode("ascii", "replace").decode("ascii"), attr)
    except (curses.error, UnicodeError, ValueError):
        pass


def draw_header(win, w, st):
    box(win, 0, 0, 6, w, "%s  WLAN" % st["host"])
    mode_txt = "ACCESS POINT" if st["mode"] == "ap" else "CLIENT"
    mode_col = C_OK if st["state"] in ("ap", "client") else C_WARN

    safe_addstr(win, 1, 3, "Mode   :", curses.color_pair(C_DIM))
    safe_addstr(win, 1, 12, mode_txt,
                curses.color_pair(mode_col) | curses.A_BOLD)
    safe_addstr(win, 1, 32, "State :", curses.color_pair(C_DIM))
    safe_addstr(win, 1, 40, st["state"], curses.color_pair(mode_col))

    sig = ("  %s dBm" % st["signal"]) if st["signal"] else ""
    safe_addstr(win, 2, 3, "wlan0  :", curses.color_pair(C_DIM))
    safe_addstr(win, 2, 12, "%-18s %s%s" % (st["ip"], st["ssid"], sig),
                curses.color_pair(C_ITEM))

    if st["eth_state"] == "up" and st["eth_ip"] not in ("", "no address"):
        eth_txt, eth_col = "%s  (you cannot lock yourself out)" % st["eth_ip"], C_OK
    elif st["eth_state"] == "up":
        eth_txt, eth_col = "up, no address", C_WARN
    else:
        eth_txt, eth_col = "DOWN - wireless is your only way in", C_WARN
    safe_addstr(win, 3, 3, "eth0   :", curses.color_pair(C_DIM))
    safe_addstr(win, 3, 12, eth_txt, curses.color_pair(eth_col))

    safe_addstr(win, 4, 3, "Host   :", curses.color_pair(C_DIM))
    safe_addstr(win, 4, 12, st["host"], curses.color_pair(C_ITEM))


def draw_keys(win, h, w, keys):
    line = "  ".join("%s %s" % (k, lbl) for k, lbl in keys)
    safe_addstr(win, h - 1, 0, line.ljust(w - 1),
                curses.color_pair(C_KEYS) | curses.A_BOLD)


def popup(stdscr, title, lines, keys="  Press any key  "):
    h, w = stdscr.getmaxyx()
    width = max(len(l) for l in lines + [title, keys]) + 6
    width = min(width, w - 4)
    height = len(lines) + 4
    y, x = max(0, (h - height) // 2), max(0, (w - width) // 2)
    win = curses.newwin(height, width, y, x)
    # Without this, getch() hands back the raw escape sequence of the
    # arrow keys, whose first byte is 27 - indistinguishable from Esc.
    # curses.wrapper only enables keypad mode on stdscr, never on
    # windows we create ourselves.
    win.keypad(True)
    win.bkgd(" ", curses.color_pair(C_ITEM))
    box(win, 0, 0, height, width, title)
    for i, l in enumerate(lines):
        safe_addstr(win, 1 + i, 3, l[: width - 6], curses.color_pair(C_ITEM))
    safe_addstr(win, height - 2, 3, keys, curses.color_pair(C_DIM))
    win.refresh()
    return win


def message(stdscr, title, lines):
    win = popup(stdscr, title, lines)
    win.getch()
    del win
    stdscr.touchwin()
    stdscr.refresh()


def confirm(stdscr, title, lines):
    win = popup(stdscr, title, lines, "  Y = yes    N / Esc = no  ")
    while True:
        c = read_key(win)
        if c in (ord("y"), ord("Y")):
            ok = True
            break
        if c in (ord("n"), ord("N"), 27):
            ok = False
            break
    del win
    stdscr.touchwin()
    stdscr.refresh()
    return ok


def prompt(stdscr, title, label, hidden=False, default=""):
    h, w = stdscr.getmaxyx()
    width = min(64, w - 4)
    height = 6
    y, x = (h - height) // 2, (w - width) // 2
    win = curses.newwin(height, width, y, x)
    # Without this, getch() hands back the raw escape sequence of the
    # arrow keys, whose first byte is 27 - indistinguishable from Esc.
    # curses.wrapper only enables keypad mode on stdscr, never on
    # windows we create ourselves.
    win.keypad(True)
    win.bkgd(" ", curses.color_pair(C_ITEM))
    box(win, 0, 0, height, width, title)
    safe_addstr(win, 1, 3, label, curses.color_pair(C_DIM))
    safe_addstr(win, height - 2, 3, "  Enter = ok    Esc = cancel  ",
                curses.color_pair(C_DIM))

    buf = list(default)
    field_y, field_x, field_w = 2, 3, width - 6
    curses.curs_set(1)
    while True:
        shown = ("*" * len(buf)) if hidden else "".join(buf)
        shown = shown[-field_w:]
        safe_addstr(win, field_y, field_x, shown.ljust(field_w),
                    curses.color_pair(C_SEL))
        win.move(field_y, field_x + min(len(shown), field_w - 1))
        win.refresh()
        c = read_key(win)
        if c == 27:
            buf = None
            break
        if c in (10, 13, curses.KEY_ENTER):
            break
        if c in (curses.KEY_BACKSPACE, 127, 8):
            if buf:
                buf.pop()
        elif 32 <= c < 127:
            buf.append(chr(c))
    curses.curs_set(0)
    del win
    stdscr.touchwin()
    stdscr.refresh()
    return None if buf is None else "".join(buf)


def pick_network(stdscr, nets):
    h, w = stdscr.getmaxyx()
    width = min(66, w - 4)
    height = min(len(nets) + 6, h - 4)
    rows = height - 6
    y, x = (h - height) // 2, (w - width) // 2
    win = curses.newwin(height, width, y, x)
    # Without this, getch() hands back the raw escape sequence of the
    # arrow keys, whose first byte is 27 - indistinguishable from Esc.
    # curses.wrapper only enables keypad mode on stdscr, never on
    # windows we create ourselves.
    win.keypad(True)
    win.bkgd(" ", curses.color_pair(C_ITEM))
    sel, top = 0, 0

    while True:
        win.erase()
        box(win, 0, 0, height, width, "Networks in range")
        safe_addstr(win, 1, 3,
                    "%-32s %-8s %s" % ("SSID", "SIGNAL", "SECURITY"),
                    curses.color_pair(C_DIM))
        for i in range(rows):
            idx = top + i
            if idx >= len(nets):
                break
            n = nets[idx]
            txt = "%-32s %-8s %s" % (n["ssid"][:32], "%d dBm" % n["signal"],
                                     n["enc"])
            attr = curses.color_pair(C_SEL) if idx == sel \
                else curses.color_pair(C_ITEM)
            safe_addstr(win, 2 + i, 3, txt.ljust(width - 6), attr)
        safe_addstr(win, height - 2, 3,
                    "  Enter = select    Esc = cancel  ",
                    curses.color_pair(C_DIM))
        win.refresh()

        c = read_key(win)
        if c == 27:
            sel = None
            break
        if c in (10, 13, curses.KEY_ENTER):
            break
        if c == curses.KEY_UP and sel > 0:
            sel -= 1
        elif c == curses.KEY_DOWN and sel < len(nets) - 1:
            sel += 1
        if sel is not None:
            if sel < top:
                top = sel
            elif sel >= top + rows:
                top = sel - rows + 1

    del win
    stdscr.touchwin()
    stdscr.refresh()
    return None if sel is None else nets[sel]


def wait_for_apply(stdscr, expect, timeout=90):
    """Poll the state file while wlan-apply.sh does its work."""
    win = popup(stdscr, "Working",
                ["Applying %s mode..." % expect,
                 "",
                 "If you are connected over the access point,",
                 "this session will drop. The device falls back",
                 "to AP mode on its own if the new network",
                 "does not come up."],
                "  please wait  ")
    start = time.time()
    while time.time() - start < timeout:
        st = current_state()
        if st in ("ap", "client"):
            result = st
            break
        if st.startswith("failed:"):
            result = st
            break
        safe_addstr(win, 1, 3, "Applying %s mode... %ds"
                    % (expect, int(time.time() - start)),
                    curses.color_pair(C_ITEM))
        win.refresh()
        time.sleep(1)
    else:
        result = "timeout"
    del win
    stdscr.touchwin()
    stdscr.refresh()
    return result


def report_result(stdscr, result):
    reasons = {
        "failed:no-wpa_supplicant":
            ["wpa_supplicant is not installed on this device.",
             "Client mode needs it. Build it statically for",
             "aarch64 and drop it into %s." % D],
        "failed:no-config": ["No network configured yet."],
        "failed:no-association":
            ["Could not associate.", "Wrong passphrase, or the network is out of range.",
             "Fell back to AP mode."],
        "failed:no-lease":
            ["Associated, but no DHCP lease.", "Fell back to AP mode."],
        "failed:supplicant": ["wpa_supplicant refused to start."],
        "failed:hostapd": ["hostapd refused to start.",
                           "Check the passphrase - it needs 8 characters or more."],
        "failed:no-device": ["wlan0 never appeared.",
                             "Is the adapter plugged in?"],
        "timeout": ["Timed out waiting for the switch to finish.",
                    "Check /var/log/wlan-ap.log."],
    }
    if result == "ap":
        message(stdscr, "Done", ["Access point is up.",
                                 "SSID %s on 192.192.193.1" % ap_ssid()])
    elif result == "client":
        message(stdscr, "Done", ["Connected.",
                                 "wlan0 has %s" % (iface_ip(IFACE) or "?")])
    else:
        message(stdscr, "Failed", reasons.get(result, [result]))


# ------------------------------------------------------------------ actions


def action_scan_connect(stdscr, st):
    # Deliberately no wpa_supplicant check here. Scanning is a pure
    # nl80211 operation and works without it; only connecting needs the
    # binary. Blocking the scan would take away the one thing that is
    # useful while the supplicant is still missing.
    if st["mode"] == "ap":
        if not confirm(stdscr, "Scanning stops the access point",
                       ["wlan0 cannot scan while it serves the AP.",
                        "The AP goes down for the scan.",
                        "",
                        "Anyone connected over the AP loses the link.",
                        "Continue?"]):
            return
        sh("killall hostapd 2>/dev/null")
        time.sleep(1)
        sh("iw dev %s set type managed 2>/dev/null" % IFACE)

    win = popup(stdscr, "Scanning", ["Looking for networks..."], "  please wait  ")
    nets, err = scan_networks()
    del win
    stdscr.touchwin()
    stdscr.refresh()

    if err == "busy":
        message(stdscr, "Scan failed",
                ["wlan0 is busy. Stop the AP first."])
        return
    if err:
        message(stdscr, "Scan failed", [err])
        return
    if not nets:
        message(stdscr, "Nothing found",
                ["No networks in range.",
                 "Use 'Enter SSID manually' for a hidden network."])
        return

    net = pick_network(stdscr, nets)
    if net is None:
        return

    if not os.path.exists(WPA_SUPPLICANT):
        message(stdscr, "Cannot connect yet",
                ["%s is in range at %d dBm."
                 % (net["ssid"][:40], net["signal"]),
                 "",
                 "Connecting needs wpa_supplicant, which is not",
                 "installed. Build it statically for aarch64 and",
                 "place it at:",
                 "  %s" % WPA_SUPPLICANT])
        return

    psk = ""
    if net["enc"] != "open":
        psk = prompt(stdscr, "Passphrase", "Passphrase for %s" % net["ssid"],
                     hidden=True)
        if psk is None:
            return
        if len(psk) < 8:
            message(stdscr, "Too short",
                    ["WPA passphrases need 8 characters or more."])
            return

    connect(stdscr, st, net["ssid"], psk)


def action_manual_ssid(stdscr, st):
    if not os.path.exists(WPA_SUPPLICANT):
        message(stdscr, "Not available",
                ["wpa_supplicant is not installed on this device."])
        return
    ssid = prompt(stdscr, "Network", "SSID")
    if not ssid:
        return
    psk = prompt(stdscr, "Passphrase", "Passphrase (empty = open network)",
                 hidden=True)
    if psk is None:
        return
    if psk and len(psk) < 8:
        message(stdscr, "Too short",
                ["WPA passphrases need 8 characters or more."])
        return
    connect(stdscr, st, ssid, psk)


def connect(stdscr, st, ssid, psk):
    warn = ["Switching wlan0 to client mode.", ""]
    if st["eth_state"] == "up" and st["eth_ip"] not in ("", "no address"):
        warn += ["eth0 is up on %s, so you keep a way in" % st["eth_ip"],
                 "whatever happens.", ""]
    else:
        warn += ["eth0 is DOWN. If the passphrase is wrong you",
                 "lose contact until the watchdog restores the AP",
                 "(about a minute).", ""]
    warn.append("Connect to %s?" % ssid)
    if not confirm(stdscr, "Confirm", warn):
        return
    write_client_conf(ssid, psk)
    apply_mode("client")
    report_result(stdscr, wait_for_apply(stdscr, "client"))


def action_switch_ap(stdscr, st):
    if st["mode"] == "ap" and st["state"] == "ap":
        if not confirm(stdscr, "Restart access point",
                       ["The access point is running.",
                        "Restarting drops anyone connected over it.",
                        "",
                        "Restart now?"]):
            return
    apply_mode("ap")
    report_result(stdscr, wait_for_apply(stdscr, "ap"))


def action_hostname(stdscr, st):
    name = prompt(stdscr, "Hostname", "New hostname", default=st["host"])
    if not name:
        return
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9-]{0,62}$", name):
        message(stdscr, "Invalid",
                ["Letters, digits and hyphens only,",
                 "and it may not start with a hyphen."])
        return
    set_hostname(name)
    message(stdscr, "Done",
            ["Hostname is now %s." % name,
             "Some services only pick it up after a reboot."])


def action_ap_credentials(stdscr, st):
    ssid = prompt(stdscr, "AP SSID", "Access point SSID", default=ap_ssid())
    if ssid is None:
        return
    passphrase = prompt(stdscr, "AP passphrase",
                        "New passphrase (empty = keep current)", hidden=True)
    if passphrase is None:
        return
    if passphrase and len(passphrase) < 8:
        message(stdscr, "Too short",
                ["hostapd refuses to start with a passphrase",
                 "shorter than 8 characters."])
        return
    set_ap_credentials(ssid, passphrase)
    if st["mode"] == "ap":
        if confirm(stdscr, "Restart access point",
                   ["Saved. The AP must restart to pick this up.",
                    "Anyone connected over it loses the link.",
                    "",
                    "Restart now?"]):
            apply_mode("ap")
            report_result(stdscr, wait_for_apply(stdscr, "ap"))
        else:
            message(stdscr, "Saved",
                    ["Takes effect the next time the AP starts."])
    else:
        message(stdscr, "Saved",
                ["Takes effect the next time you switch to AP mode."])


def label_switch_ap(st):
    if st["mode"] == "ap" and st["state"] == "ap":
        return "Restart access point"
    return "Switch to access point mode"


def why_not_client(st):
    if not os.path.exists(WPA_SUPPLICANT):
        return ["wpa_supplicant is not installed on this device.",
                "",
                "Client mode needs it. Build it statically for",
                "aarch64 and place it at:",
                "  %s" % WPA_SUPPLICANT]
    return None


# (label, action, guard). The label may be a plain string or a function
# of the status, for items whose meaning depends on the current mode.
# guard returns None when the item is available, or the lines explaining
# why it is not. Unavailable items are drawn dimmed and say why when
# picked, rather than failing after the fact.
MENU = [
    ("Scan networks and connect", action_scan_connect, None),
    ("Enter SSID manually", action_manual_ssid, why_not_client),
    (label_switch_ap, action_switch_ap, None),
    ("Change hostname", action_hostname, None),
    ("Change AP SSID and passphrase", action_ap_credentials, None),
]


def item_label(entry, st):
    label = entry[0]
    return label(st) if callable(label) else label


def run_item(stdscr, sel, st):
    _, action, guard = MENU[sel]
    reason = guard(st) if guard else None
    if reason:
        message(stdscr, "Not available", reason)
        return
    action(stdscr, st)


def main(stdscr):
    init_colors()
    curses.curs_set(0)
    stdscr.bkgd(" ", curses.color_pair(C_ITEM))
    sel = 0
    last_status = 0
    st = gather_status()

    while True:
        if time.time() - last_status > 3:
            st = gather_status()
            last_status = time.time()

        h, w = stdscr.getmaxyx()
        stdscr.erase()
        draw_header(stdscr, w, st)

        box(stdscr, 6, 0, len(MENU) + 4, w, "Actions")
        for i, entry in enumerate(MENU):
            guard = entry[2]
            blocked = guard is not None and guard(st) is not None
            if i == sel and blocked:
                attr = curses.color_pair(C_SEL) | curses.A_DIM
            elif i == sel:
                attr = curses.color_pair(C_SEL) | curses.A_BOLD
            elif blocked:
                attr = curses.color_pair(C_DIM) | curses.A_DIM
            else:
                attr = curses.color_pair(C_ITEM)
            safe_addstr(stdscr, 8 + i, 3,
                        (" %d  %s" % (i + 1, item_label(entry, st)))
                        .ljust(w - 6), attr)

        draw_keys(stdscr, h, w, [("Up/Dn", "Move"), ("Enter", "Run"),
                                 ("R", "Refresh"), ("Q", "Quit")])
        stdscr.refresh()

        stdscr.timeout(1000)
        c = stdscr.getch()
        if c == -1:
            continue
        if c in (ord("q"), ord("Q")):
            break
        if c in (ord("r"), ord("R")):
            last_status = 0
            continue
        if c == curses.KEY_UP:
            sel = (sel - 1) % len(MENU)
        elif c == curses.KEY_DOWN:
            sel = (sel + 1) % len(MENU)
        elif ord("1") <= c <= ord("0") + len(MENU):
            sel = c - ord("1")
            stdscr.timeout(-1)
            run_item(stdscr, sel, st)
            last_status = 0
        elif c in (10, 13, curses.KEY_ENTER):
            stdscr.timeout(-1)
            run_item(stdscr, sel, st)
            last_status = 0


if __name__ == "__main__":
    if os.geteuid() != 0:
        sys.stderr.write("wlan-menu must run as root\n")
        sys.exit(1)
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        pass
