#!/bin/sh
# Make a GL.iNet KVM visible in the Windows network view. Runs on the device.
#
#     curl -sSLo /tmp/d.sh https://raw.githubusercontent.com/macpit/glkvm-rm1pe-kernel/main/install-discovery.sh
#     sh /tmp/d.sh
#
# and to undo it completely:
#
#     sh /tmp/d.sh --uninstall
#
# This installs nothing but a small Python daemon and one init script. It does
# not touch the kernel, the boot partition or any firmware binary, and it works
# on any GL KVM with Python 3 -- you do not need the custom kernel from this
# repository for it. Everything it writes lives under /userdata, plus one line
# added to an existing init script and one file in /etc/init.d.
#
# Why this exists: Explorer's "Network -> Other devices" list is fed by
# SSDP/UPnP, not by mDNS. The KVMs already announce themselves over mDNS -- GL
# ships mDNSResponder, so <hostname>.local works out of the box -- but Windows
# does not use that for this list. A Synology NAS on the same wire shows up and
# the KVM does not. This closes that gap.
#
# See docs/discovery.md for what it announces and how to verify it.
set -eu

REPO="macpit/glkvm-rm1pe-kernel"
BRANCH="${BRANCH:-main}"
RAW="https://raw.githubusercontent.com/$REPO/$BRANCH"

SSDP_SHA="587d82f4e922a54e6d2e0d679f63d7a2a77c42648711b328e5a9407d6fdc7555"
INITD_SHA="67957b21fc43272df417ba95f8d4c57349b83e33aaa24f16a333637012d71ff8"

DIR="/userdata/discovery"
INITD="/etc/init.d/S99discovery"
MARKER="S99discovery start"

say() { printf '%s\n' "$*"; }
die() { printf '\ninstall-discovery: %s\n\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ uninstall

uninstall() {
    say "==> removing the discovery service"
    pkill -f "$DIR/ssdp.py" 2>/dev/null || true

    for h in /etc/init.d/S99zerotier /etc/init.d/S99tailscale \
             /etc/init.d/S99netbird /etc/init.d/S99rtty; do
        [ -f "$h" ] || continue
        if grep -q "$MARKER" "$h" 2>/dev/null; then
            if [ -f "$DIR/backup/$(basename "$h").orig" ]; then
                cp "$DIR/backup/$(basename "$h").orig" "$h"
                say "    restored $h from the backup taken at install time"
            else
                grep -v "$MARKER" "$h" > /tmp/.h.$$ && cat /tmp/.h.$$ > "$h"
                rm -f /tmp/.h.$$
                say "    removed the boot call from $h"
            fi
        fi
    done

    rm -f "$INITD"
    rm -rf "$DIR"
    say "    removed $INITD and $DIR"
    say ""
    say "Gone. The device keeps announcing itself over mDNS as before -- that"
    say "part is the vendor's and was never touched."
    exit 0
}

[ "${1:-}" = "--uninstall" ] && uninstall

# --------------------------------------------------------------- sanity check

for t in python3 curl sha256sum; do
    command -v "$t" >/dev/null || die "$t not found on this device."
done
python3 -c 'import http.server, socket, uuid' 2>/dev/null \
    || die "this Python 3 is missing modules the daemon needs."
[ -d /userdata ] || die "no /userdata here. This does not look like a GL KVM."
[ -w /etc/init.d ] || die "/etc/init.d is not writable; run this as root."

MODEL=$(sed -n 's/^RK_MODEL=//p' /etc/version 2>/dev/null | head -1)
VERSION=$(sed -n 's/^RK_VERSION=//p' /etc/version 2>/dev/null | head -1)
HOST=$(hostname 2>/dev/null || echo "?")
say "==> $HOST${MODEL:+, model $MODEL}${VERSION:+, firmware $VERSION}"

# Deliberately no model check. The daemon reads whatever /etc/version says and
# announces that; there is nothing model-specific in it, so refusing to run on
# an RM1 v2 or anything else GL ships would be gatekeeping for its own sake.
[ -n "$MODEL" ] || say "    (no /etc/version -- the announcement will be generic)"

# ------------------------------------------------------------------- fetch

WORK=$(mktemp -d /userdata/.discovery.XXXXXX) || die "cannot create a work directory"
trap 'rm -rf "$WORK"' EXIT

fetch() {  # fetch <url> <dest> <sha256>
    curl -sSL --fail -o "$2" "$1" || die "download failed: $1"
    got=$(sha256sum "$2" | cut -d' ' -f1)
    [ "$got" = "$3" ] || die "checksum mismatch for $(basename "$2")
    expected $3
    got      $got"
}

say "==> fetching"
fetch "$RAW/discovery/ssdp.py"      "$WORK/ssdp.py"      "$SSDP_SHA"
fetch "$RAW/discovery/S99discovery" "$WORK/S99discovery" "$INITD_SHA"
say "    checksums ok"

# ------------------------------------------------------------------ install

mkdir -p "$DIR/backup"
cp "$WORK/ssdp.py" "$DIR/ssdp.py"
chmod 700 "$DIR/ssdp.py"
cp "$WORK/S99discovery" "$INITD"
chmod 755 "$INITD"
say "==> installed $DIR/ssdp.py and $INITD"

# --------------------------------------------------------------- boot call
#
# rcS expands /etc/init.d/S??* before the overlay is mounted. Everything we
# write lands in the overlay upper layer, so the glob never sees it and our
# init script would simply never run. Scripts the firmware ships are in the
# lower layer, get globbed, and by the time they execute the overlay is up --
# so the call has to go inside one of theirs.

plant_boot_call() {
    for h in S99zerotier S99tailscale S99netbird S99rtty; do
        host="/etc/init.d/$h"
        [ -f "$host" ] || continue

        if grep -q "$MARKER" "$host" 2>/dev/null; then
            say "    boot call already present in $host"
            return 0
        fi

        cp "$host" "$DIR/backup/$h.orig"
        if python3 - "$host" <<'PY'
import re, sys
path = sys.argv[1]
lines = open(path).read().split("\n")
call = ("        /etc/init.d/S99discovery start"
        "  # planted by install-discovery.sh: rcS globs before pivot_root,"
        " so an overlay-only init script is never seen")
for i, line in enumerate(lines):
    if re.match(r"^\s*start\)\s*$", line):
        lines.insert(i + 1, call)
        open(path, "w").write("\n".join(lines))
        sys.exit(0)
sys.exit(1)
PY
        then
            if sh -n "$host" 2>/dev/null; then
                say "    boot call planted in $host"
                return 0
            fi
            cp "$DIR/backup/$h.orig" "$host"
            say "    $host would not parse with the call added; restored"
        fi
    done
    return 1
}

if ! plant_boot_call; then
    say ""
    say "    Could not plant the boot call in any firmware init script."
    say "    The service is installed and will be started now, but it will not"
    say "    come back after a reboot. Add this line inside the start) case of"
    say "    a script the firmware ships:"
    say "        /etc/init.d/S99discovery start"
    say ""
fi

# --------------------------------------------------------------------- start

pkill -f "$DIR/ssdp.py" 2>/dev/null || true
sleep 1
"$INITD" start
sleep 2

if pgrep -f "$DIR/ssdp.py" >/dev/null; then
    say "==> running"
else
    die "the daemon did not stay up. See /var/log/ssdp.log."
fi

IP=$(ip -4 addr show eth0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
NAME=$(curl -s --max-time 5 "http://127.0.0.1:1901/desc.xml" \
       | sed -n 's:.*<friendlyName>\(.*\)</friendlyName>.*:\1:p')

say ""
say "    announcing as: ${NAME:-?}"
say "    opens:         http://${IP:-<this device>}/"
say ""
say "In Windows: Explorer -> Network, then F5. If nothing appears, the network"
say "profile has to be Private and network discovery switched on; Explorer can"
say "also take a minute. On macOS and Linux nothing changes -- the device was"
say "already reachable as $(hostname 2>/dev/null || echo '<hostname>').local"
say "over the vendor's mDNS."
say ""
say "To undo: sh $0 --uninstall"
