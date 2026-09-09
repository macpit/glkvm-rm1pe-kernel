#!/bin/sh
# Share the KVM's ISO storage (/userdata/media) over SMB. Runs on the device.
#
#     curl -sSLo /tmp/s.sh https://raw.githubusercontent.com/macpit/glkvm-rm1pe-kernel/main/install-smb.sh
#     sh /tmp/s.sh
#
# and to undo it completely:
#
#     sh /tmp/s.sh --uninstall
#
# What you get: the share \\<hostname>\media (smb://<hostname>.local/media).
# Guests can read it without a password and see an index.html that links to
# the web GUI; the user "admin" can write to it.  The device also appears in
# the macOS Finder under Network, since that list is fed by _smb._tcp.
#
# Unlike install-discovery.sh this needs the custom kernel from this
# repository: the SMB server is the in-kernel ksmbd, shipped here as modules
# built against exactly that kernel.  The installer checks the kernel
# version and refuses on anything else.
#
# See docs/smb.md for details and the caveat about kvmd's virtual-drive mode.
set -eu

REPO="macpit/glkvm-rm1pe-kernel"
BRANCH="${BRANCH:-main}"
TAG="${TAG:-v30}"
RAW="https://raw.githubusercontent.com/$REPO/$BRANCH"
REL="https://github.com/$REPO/releases/download/$TAG"

# Release assets (binaries built for the kernel in this release)
KSMBD_SHA="50cab73e0b412afefeaf013b21a12cdc163f7e4f41097cf7558556ab35f9133e"
ARC4_SHA="e99a8f3671c9c38e6dfa678dc8fb4cd765e902488eb98d594c31999f6ca1d438"
MD4_SHA="96adb3e3fdee262bb92fb0f159b8e9b00513dae733bde67e85924a9dab0db103"
TOOLS_SHA="9b3d457ee8538f6f04ff72ef90dfe2f07bd9703fa7a5c955425a6f0b033a1460"
# Scripts (from the branch)
INITD_SHA="1eaf92dae21d5f79d0c17b6636feaf3c99be3a3f5ad3b03fda47ec4751b48338"
SETPW_SHA="ccbb240741584e508c305b3f00a23f2353210d6eac05f7b3009d0857c7de3f6a"
WSDD_SHA="54eca646850654301c89dfef78dc42ef07b98d28487fee51c93688d06a470be6"
LLMNRD_SHA="a9f03fbe3950266727699e2169bb013b29ca6ee1ef86ca6b067d0c0d9becdb3f"

KVER="6.1.141"
DIR="/userdata/smb"
INITD="/etc/init.d/S99smb"
MARKER="S99smb start"

say() { printf '%s\n' "$*"; }
die() { printf '\ninstall-smb: %s\n\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ uninstall

uninstall() {
    say "==> removing the SMB share"
    [ -x "$INITD" ] && "$INITD" stop 2>/dev/null || true

    for h in /etc/init.d/S99zerotier /etc/init.d/S99tailscale \
             /etc/init.d/S99netbird /etc/init.d/S99rtty; do
        [ -f "$h" ] || continue
        if grep -q "$MARKER" "$h" 2>/dev/null; then
            grep -v "$MARKER" "$h" > /tmp/.h.$$ && cat /tmp/.h.$$ > "$h"
            rm -f /tmp/.h.$$
            say "    removed the boot call from $h"
        fi
    done

    rm -f "$INITD" /userdata/media/index.html
    rm -rf "$DIR"
    say "    removed $INITD and $DIR (the user database went with it)"
    exit 0
}

[ "${1:-}" = "--uninstall" ] && uninstall

# --------------------------------------------------------------- sanity check

for t in curl sha256sum insmod hostname; do
    command -v "$t" >/dev/null || die "$t not found on this device."
done
[ -d /userdata/media ] || die "no /userdata/media here. This does not look like a GL KVM."
[ -w /etc/init.d ] || die "/etc/init.d is not writable; run this as root."

RUNNING=$(uname -r)
[ "$RUNNING" = "$KVER" ] || die "kernel is $RUNNING, the ksmbd modules in $TAG are for $KVER.
    Install the kernel from this repository first (install.sh)."

HOST=$(hostname 2>/dev/null || echo "?")
say "==> $HOST, kernel $RUNNING"

# ------------------------------------------------------------------- fetch

WORK=$(mktemp -d /userdata/.smb.XXXXXX) || die "cannot create a work directory"
trap 'rm -rf "$WORK"' EXIT

fetch() {  # fetch <url> <dest> <sha256>
    curl -sSL --fail -o "$2" "$1" || die "download failed: $1"
    got=$(sha256sum "$2" | cut -d' ' -f1)
    [ "$got" = "$3" ] || die "checksum mismatch for $(basename "$2")
    expected $3
    got      $got"
}

say "==> fetching"
fetch "$REL/ksmbd.ko"           "$WORK/ksmbd.ko"        "$KSMBD_SHA"
fetch "$REL/cifs_arc4.ko"       "$WORK/cifs_arc4.ko"    "$ARC4_SHA"
fetch "$REL/cifs_md4.ko"        "$WORK/cifs_md4.ko"     "$MD4_SHA"
fetch "$REL/ksmbd.tools"        "$WORK/ksmbd.tools"     "$TOOLS_SHA"
fetch "$RAW/smb/S99smb"         "$WORK/S99smb"          "$INITD_SHA"
fetch "$RAW/set-smb-password.sh" "$WORK/set-smb-password.sh" "$SETPW_SHA"
fetch "$RAW/smb/wsdd.py"        "$WORK/wsdd.py"         "$WSDD_SHA"
fetch "$RAW/smb/llmnrd.py"      "$WORK/llmnrd.py"       "$LLMNRD_SHA"
say "    checksums ok"

strings "$WORK/ksmbd.ko" | grep -q "^vermagic=$RUNNING " \
    || die "ksmbd.ko in $TAG does not match the running kernel"

# ------------------------------------------------------------------ install

mkdir -p "$DIR"
# A running ksmbd.tools cannot be overwritten in place (ETXTBSY); stop the
# service first and replace files by rename.
[ -x "$INITD" ] && "$INITD" stop >/dev/null 2>&1 || true
put() {  # put <name> <mode>
    cp "$WORK/$1" "$DIR/.$1.new" && chmod "$2" "$DIR/.$1.new" && mv -f "$DIR/.$1.new" "$DIR/$1"
}
for f in ksmbd.ko cifs_arc4.ko cifs_md4.ko; do put "$f" 644; done
for f in ksmbd.tools set-smb-password.sh wsdd.py llmnrd.py; do put "$f" 755; done
# ksmbd-tools is a multi-call binary, dispatching on its name
for t in mountd adduser control; do ln -sf ksmbd.tools "$DIR/ksmbd.$t"; done
cp "$WORK/S99smb" "$INITD"
chmod 755 "$INITD"
say "==> installed $DIR and $INITD"

# ------------------------------------------------------------- admin user

# Guests log in as "guest" with an empty password (map to guest = never
# refuses unknown names, so the Windows Explorer shows a credential prompt
# instead of failing).  ksmbd matches names case-sensitively and macOS
# sends "Guest", so create the spellings clients actually use.
for g in guest Guest GUEST; do
    grep -q "^$g:" "$DIR/ksmbdpwd.db" 2>/dev/null \
        || "$DIR/ksmbd.adduser" -P "$DIR/ksmbdpwd.db" -p "" -a "$g" >/dev/null 2>&1
done

NEWPW=""
if ! grep -q "^admin:" "$DIR/ksmbdpwd.db" 2>/dev/null; then
    NEWPW=$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12)
    sh "$DIR/set-smb-password.sh" "$NEWPW" >/dev/null
    say "==> created SMB user admin"
else
    say "==> keeping the existing SMB user database"
fi

# --------------------------------------------------------------- boot call
#
# rcS expands /etc/init.d/S??* before the overlay is mounted, so a new init
# script is never globbed.  Plant the call in a firmware script instead --
# the same trick install-discovery.sh uses.

plant_boot_call() {
    for h in S99zerotier S99tailscale S99netbird S99rtty; do
        host="/etc/init.d/$h"
        [ -f "$host" ] || continue
        if grep -q "$MARKER" "$host" 2>/dev/null; then
            say "    boot call already present in $host"
            return 0
        fi
        cp "$host" "$WORK/$h.orig"
        if python3 - "$host" <<'PY'
import re, sys
path = sys.argv[1]
lines = open(path).read().split("\n")
call = ("        /etc/init.d/S99smb start"
        "  # planted by install-smb.sh: rcS globs before pivot_root,"
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
            cp "$WORK/$h.orig" "$host"
            say "    $host would not parse with the call added; restored"
        fi
    done
    return 1
}

if ! plant_boot_call; then
    say ""
    say "    Could not plant the boot call in any firmware init script."
    say "    The share is started now but will not come back after a reboot."
    say "    Add this line inside the start) case of a firmware init script:"
    say "        /etc/init.d/S99smb start"
    say ""
fi

# --------------------------------------------------------------------- start

"$INITD" restart
sleep 2
"$INITD" status >/dev/null || die "ksmbd did not start. See /var/log/smb.log."

say ""
say "==> share is up"
say "    macOS:    Finder -> Network -> $HOST   (or smb://$HOST.local/media)"
say "    Windows:  \\\\$HOST.local\\media   (guest read needs 'insecure guest"
say "              logons' allowed; otherwise log in as admin)"
say "    Linux:    smb://$HOST.local/media"
if [ -n "$NEWPW" ]; then
    say ""
    say "    write access:  user  admin"
    say "                   pass  $NEWPW"
    say "    (shown only now -- change it with: sh $DIR/set-smb-password.sh)"
fi
say ""
say "Before using kvmd's virtual-drive mode (whole partition to the target PC)"
say "disconnect SMB clients, or run: $INITD stop"
say ""
say "To undo: sh $0 --uninstall"
