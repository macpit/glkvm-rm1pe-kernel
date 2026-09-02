#!/bin/sh
# Install, list and roll back kernels on a GL-RM1PE, from the device itself.
#
# No build machine, no cross toolchain, no SSH from elsewhere. Fetch it once
# and keep it, so rolling back later needs no network:
#
#     curl -sSLo install.sh https://raw.githubusercontent.com/macpit/glkvm-rm1pe-kernel/main/install.sh
#     sh install.sh                  # install the pinned release kernel
#     sh install.sh --list           # what can be rolled back to
#     sh install.sh --revert FILE    # put one of those back
#
# It swaps the kernel inside the FIT already in your boot partition, keeping
# your device tree and the Rockchip resource blob. It backs the partition up
# before writing, verifies by reading back, and restores the backup itself if
# that fails. It never reboots.
#
# It also installs everything the WLAN needs: the 8188eu driver module, hostapd,
# dnsmasq, wpa_supplicant, the menu, the captive portal and the autostart hook.
# The kernel alone only gets the stick enumerated -- without the driver there is
# no wlan0 at all. That part is additive: an existing hostapd.conf is never
# touched, an ap-start.sh that is not one of ours is left alone, the nginx
# change is reverted if nginx does not accept it, and any failure there leaves
# the kernel install untouched. --no-wlan skips all of it.
#
# Read this before piping it into a shell. It overwrites a boot partition.
set -eu

REPO="macpit/glkvm-rm1pe-kernel"
TAG="${TAG:-v25}"
KERNEL_NAME="Image-6.1.141-${TAG}"
KERNEL_SHA="d96cd811f8cf3888a5185b9c69f5e379f36888527584842a0135092a850581fd"
PATCHER_SHA="dd7564615e1301e2cea804eadedd60bb1e03c6538cb74951510569406ce2a004"

# The WLAN helper. Binaries and the driver module come from the release,
# scripts and configs from the branch, all pinned the same way as the kernel.
WPA_SHA="a402b6fdb369e0346e1a190ed9d936b46410091b17580eaadd47828235af914e"
WPA_CLI_SHA="f362004682622b6147ff624ccc659ddddbc1e1d85fcb7776b3af6c69eac7ce8a"
HOSTAPD_SHA="abf7148d86310e0ac4f45b00ef09eb6c6eafdc5ac792333423698e920f768cc4"
DNSMASQ_SHA="358d7f82c708180cf39ff17baafec93410e3c284262fc84a86a9c26bbde6587c"
MODULE_SHA="88514328082425ad1758071204f87e001e4066b936882c9aff39838598d30118"
MENU_SHA="d36db14b2033e15a6e454405504abb86e4db876764259e39cb47f128a5136fe9"
APPLY_SHA="ad3cc09f618f9331213a31bdc6ae299636d7b9cfc39f3ae89439d2f0b1f57eb6"
APSTART_SHA="60c2966ca72b52f22fb3a3f45b4c334e0e81f1f1e2057b019b1c350768896048"
INITD_SHA="f542bb3045a7aee5014ecfcfcebb83065a263c08a33245237bd4925ecb94d29e"
CAPTIVE_SHA="dfe117c040e2e7de6d0297e345068f883bf85d80a1c7db99fbb36ef585a19a4e"
DNSMASQ_CONF_SHA="901a7b17f19c4440f6ccf141d087264cc3da1a773ab874095c1e716ee9ea9694"
RESTARTCAP_SHA="e733fb8373522519c2085339ab1dd2049036b8293221b0e475d931ed84ad80bc"
HOSTAPD_EXAMPLE_SHA="44302b7be29653a04021490ce527bb1861a149c304898d57c9947307ba377c46"
NGINX_BLOCK_SHA="856ee394674c2254e413aa3a0f5e7b4eccb952b0a85ab7d5dee301eb840d8a7c"
PORTAL_SHA="c0dc9a3b0f70054e85332a30985bb41ca8f65ad4729c06f0b6f66d7fa64342e6"

# Every ap-start.sh we have ever shipped, newest first. Anything not in this
# list is treated as yours and left alone.
AP_START_KNOWN="60c2966ca72b52f22fb3a3f45b4c334e0e81f1f1e2057b019b1c350768896048
e9b74312e0602d4ad337ed4dcc5f15d53b27655ec01a36792a03b93f156bb16e
08f1f22aa921e601de9864fdc1e53b33539f0020f15553f1f3b57866dd0c2984"

ISSUES="https://github.com/${REPO}/issues"

# Stock firmware versions this has actually been run on. Anything else is
# refused: the boot partition layout and /etc/init.d/S23hdmi are what we key
# off, and neither is guaranteed across GL.iNet releases.
TESTED_FIRMWARE="V1.9.1 release1"

REL="https://github.com/${REPO}/releases/download/${TAG}"
RAW="https://raw.githubusercontent.com/${REPO}/main"
BOOT="/dev/block/by-name/boot"
BACKUP_DIR="/userdata/kernel-backup"
WORK="/userdata/.glkvm-install"
WLAN_DIR="/userdata/wlan-ap"
MOD_DIR="/userdata/wlan-modules"
NGINX_CONF="/etc/kvmd/nginx-kvmd.conf"
NEED_KB=90112                      # kernel + patched image + 32 MiB backup
                                   # + ~7.5 MiB of driver, daemons and helper

# Offline / testing: point these at local files to skip the downloads.
KERNEL_FILE="${KERNEL_FILE:-}"
PATCHER_FILE="${PATCHER_FILE:-}"

say()  { printf '%s\n' "$*"; }
die()  { printf 'install: %s\n' "$*" >&2; exit 1; }

# Piped into a shell, $0 is "sh", so it is useless for telling the user how to
# run this again. SELF is empty in that case and the messages say so.
if [ -f "$0" ]; then SELF="sh $0"; else SELF=""; fi

usage() {
    cat <<USAGE
usage:
  install.sh                  install the pinned release kernel ($TAG)
  install.sh --list           list images in $BACKUP_DIR
  install.sh --revert FILE    write FILE back into the boot partition
  -y, --yes                   do not ask for confirmation
      --no-wlan               do not install the WLAN helper

When piped straight into a shell, pass arguments after -s --, e.g.
  curl -sSL <url> | sh -s -- --list
USAGE
}

MODE=install
PICK=""
ASSUME_YES=0
WANT_WLAN=1
WLAN_OK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list)      MODE=list ;;
        --revert)    MODE=revert; PICK="${2:-}"; shift
                     [ -n "$PICK" ] || die "--revert needs a file; try --list" ;;
        -y|--yes)    ASSUME_YES=1 ;;
        --no-wlan)   WANT_WLAN=0 ;;
        -h|--help)   usage; exit 0 ;;
        *)           usage >&2; exit 1 ;;
    esac
    shift
done

# Piped into a shell, stdin is the script itself, so the prompt has to come
# from the terminal directly.
confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    # Two traps here. Testing -r is not enough: /dev/tty exists and looks
    # readable even with no controlling terminal, and only opening it fails.
    # And the open has to happen in a subshell -- a failed redirection on a
    # compound command terminates a non-interactive shell outright, so the
    # obvious { : < /dev/tty; } would exit silently instead of taking the
    # else branch.
    if ( exec < /dev/tty ) 2>/dev/null; then
        printf 'Type yes to continue: '
        read -r _reply < /dev/tty || _reply=""
        [ "$_reply" = "yes" ] || die "aborted, nothing written"
    else
        die "no terminal to confirm on (running non-interactively?).
Re-run with --yes if you are sure, or run it from a shell on the device."
    fi
}

# ---------------------------------------------------------------- device check
[ "$(id -u)" = 0 ] || die "must run as root"

# Three independent sources, because one of them being right by accident is
# not the same as being on the right device. gl-hw-info is a kernel module and
# can be absent; /etc/version is the vendor's own record; the device tree comes
# from the boot partition itself.
GL_MODEL=$(cat /proc/gl-hw-info/model 2>/dev/null || echo "")
RK_MODEL=$(sed -n 's/^RK_MODEL=//p' /etc/version 2>/dev/null | head -1)
DT_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "")
RK_VERSION=$(sed -n 's/^RK_VERSION=//p' /etc/version 2>/dev/null | head -1)

wrong_device() {
    die "this does not look like a GL-RM1PE (Comet PoE), and $1.

    /proc/gl-hw-info/model   ${GL_MODEL:-<missing>}     expected rm1pe
    RK_MODEL in /etc/version ${RK_MODEL:-<missing>}     expected RM1PE
    /proc/device-tree/model  ${DT_MODEL:-<missing>}     expected to contain RV1126B-P

Everything in this repository is built for the RM1PE only. A kernel for the
wrong board will not boot, and on this hardware that means a serial console
and a soldering iron to get back.

If you believe this IS an RM1PE, please open an issue with the three lines
above: $ISSUES"
}

[ "$GL_MODEL" = "rm1pe" ] || wrong_device "the model does not match"
[ "$RK_MODEL" = "RM1PE" ] || wrong_device "the vendor version file disagrees"
case "$DT_MODEL" in *RV1126B-P*) ;; *) wrong_device "the device tree disagrees" ;; esac

# Only refuse on firmware we have not seen. The list is short on purpose.
printf '%s\n' "$TESTED_FIRMWARE" | grep -Fxq "$RK_VERSION" || die \
"this device runs stock firmware '${RK_VERSION:-<unknown>}', which has not been
tested with this kernel. Tested so far:

$(printf '    %s\n' "$TESTED_FIRMWARE")

Refusing rather than guessing. What we rely on -- the FIT layout of the boot
partition and /etc/init.d/S23hdmi -- is not guaranteed to be the same across
GL.iNet releases, and getting it wrong costs you a serial console.

Please open an issue with the output of:

    cat /etc/version
    cat /proc/gl-hw-info/model

at $ISSUES and we will check that firmware. It is usually a quick answer."

[ -b "$BOOT" ] || die "no boot partition at $BOOT"
PART_BYTES=$(( $(cat "/sys/class/block/$(basename "$(readlink -f "$BOOT")")/size") * 512 ))

# A FIT starts with the flattened-device-tree magic. Anything else in the boot
# partition would not boot, so refuse to write it.
is_fit() {
    [ "$(od -An -tx1 -N4 "$1" | tr -d ' \n')" = "d00dfeed" ]
}

write_and_verify() {  # write_and_verify <file> <label>
    _size=$(stat -c%s "$1")
    _sha=$(sha256sum "$1" | cut -d' ' -f1)
    [ "$_size" -le "$PART_BYTES" ] \
        || die "$2 is $_size bytes, larger than the $PART_BYTES byte partition"
    is_fit "$1" || die "$2 does not start with the FIT magic; refusing to write it"
    say "==> writing"
    # From here to the end of sync, an interrupted write leaves a boot
    # partition that is neither the old nor the new image -- which on this
    # hardware means a serial console to recover. A dropped SSH session is
    # the likely way that happens, so refuse to die halfway through.
    trap '' HUP INT TERM QUIT
    cat "$1" > "$BOOT"
    sync
    trap - HUP INT TERM QUIT
    sleep 1
    _back=$(head -c "$_size" "$BOOT" | sha256sum | cut -d' ' -f1)
    [ "$_back" = "$_sha" ] || return 1
    say ""
    say "    written and verified: $_sha"
    return 0
}

epilogue() {
    say ""
    say "The device still runs the old kernel from RAM. Nothing has rebooted."
    say "Power-cycle it when you are ready -- pull the power rather than"
    say "rebooting warm, since only a cold start exercises the HDMI bridge."
}

# ------------------------------------------------------------------------ wlan
# The module only loads on the kernel it was built against. Saying so here
# beats an insmod that fails at boot with "invalid module format".
check_module_vermagic() {
    vm=$(python3 -c "
import re, sys
d = open(sys.argv[1], 'rb').read()
m = re.search(rb'vermagic=([^\x00]*)', d)
print(m.group(1).decode() if m else '')
" "$MOD_DIR/8188eu.ko" 2>/dev/null) || return 0
    [ -n "$vm" ] || return 0
    case "$vm" in
        "$(uname -r)"*) return 0 ;;
    esac
    say "    warning: the driver was built for '$vm' but this kernel is"
    say "    '$(uname -r)'. It will not load. Rebuild it with"
    say "    scripts/build-8188eu.sh against the tree you built the kernel from."
}

# Never overwrite credentials that already exist. On a fresh device, generate
# them rather than shipping a default: an access point with a passphrase out of
# a public repository is not an access point with a passphrase.
install_hostapd_conf() {
    [ -f "$WLAN_DIR/hostapd.conf" ] && return 0
    ssid="$(hostname 2>/dev/null || echo kvm)-ap"
    pass=$(tr -dc 'a-hj-km-np-z2-9' < /dev/urandom 2>/dev/null | head -c 12)
    [ ${#pass} -eq 12 ] || pass="kvm-$(date +%s | tail -c 9)"
    sed -e "s/^ssid=.*/ssid=$ssid/" \
        -e "s/^wpa_passphrase=.*/wpa_passphrase=$pass/" \
        "$WORK/hostapd.conf.example" > "$WLAN_DIR/hostapd.conf"
    chmod 600 "$WLAN_DIR/hostapd.conf"
    say ""
    say "    access point:  SSID $ssid"
    say "                   passphrase $pass"
    say "    Write that down. Menu option 5 changes both."
    say ""
}

install_initd() {
    hook=/etc/init.d/S99wlan-ap
    if [ -f "$hook" ] && ! grep -q "ap-start.sh" "$hook" 2>/dev/null; then
        say "    $hook exists and is not ours, left alone"
        return 0
    fi
    cp "$WORK/S99wlan-ap" "$hook" && chmod 755 "$hook" \
        || { say "    could not install $hook; the WLAN will not start at boot"
             return 0; }
    plant_boot_call
}

# rcS expands /etc/init.d/S??* before the overlay is mounted, so the script we
# just wrote -- which exists only in the overlay upper layer -- is invisible to
# that glob and never runs at boot. Scripts the firmware ships are in the lower
# layer, so the glob finds them, and by the time they execute the overlay is up
# and our file is reachable. So the call goes inside one of theirs.
#
# Found the hard way on a second device: the helper was installed, the menu
# worked, and the access point simply never came up after a reboot.
plant_boot_call() {
    for h in S99zerotier S99tailscale S99netbird S99rtty; do
        host="/etc/init.d/$h"
        [ -f "$host" ] || continue

        if grep -q "S99wlan-ap start" "$host" 2>/dev/null; then
            say "    boot call already present in $host"
            return 0
        fi

        cp "$host" "$WLAN_DIR/backup/$h.orig" 2>/dev/null || continue
        if python3 - "$host" <<'PY'
import re, sys
path = sys.argv[1]
lines = open(path).read().split("\n")
call = ("        /etc/init.d/S99wlan-ap start"
        "  # planted by glkvm-rm1pe-kernel: rcS globs before pivot_root,"
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
            cp "$WLAN_DIR/backup/$h.orig" "$host"
            say "    $host would not parse with the boot call; restored"
        fi
    done

    say ""
    say "    Could not plant the boot call in any firmware init script."
    say "    The access point will not come up on its own after a reboot."
    say "    Add this line inside the start) case of one of them by hand:"
    say "        /etc/init.d/S99wlan-ap start"
    say "    Writing /etc/init.d/S99wlan-ap alone is not enough -- see"
    say "    docs/wlan-ap.md for why."
    say ""
}

# The captive portal needs two server blocks in the kvmd nginx config. This is
# the only part of the install that edits a file the firmware owns, so it backs
# up first, tests, and puts the original back if nginx does not accept it.
install_nginx_block() {
    [ -f "$NGINX_CONF" ] || { say "    no $NGINX_CONF, portal blocks skipped"; return 0; }
    if grep -q "192.192.193.1" "$NGINX_CONF" 2>/dev/null; then
        say "    portal blocks already present"
        return 0
    fi
    cp "$NGINX_CONF" "$WLAN_DIR/backup/nginx-kvmd.conf.orig" || return 0
    python3 - "$NGINX_CONF" "$WORK/nginx-ap-block.conf" <<'PY' || return 0
import sys
conf, block = sys.argv[1], sys.argv[2]
text = open(conf).read()
body = open(block).read().strip("\n")
cut = text.rstrip().rfind("}")
open(conf, "w").write(text[:cut] + "\n" + body + "\n}\n")
PY
    # Not a bare "nginx -t": that tests /etc/nginx/nginx.conf, which is not the
    # config in use and fails for unrelated reasons.
    if nginx -p /etc/kvmd/nginx -c "$NGINX_CONF" -t >/dev/null 2>&1; then
        pid=$(cat /run/kvmd/nginx.pid 2>/dev/null)
        [ -n "$pid" ] && kill -HUP "$pid" 2>/dev/null
        say "    portal blocks added, nginx reloaded"
    else
        cp "$WLAN_DIR/backup/nginx-kvmd.conf.orig" "$NGINX_CONF"
        say "    nginx rejected the portal blocks; your config was restored"
    fi
}

is_known_ap_start() {
    for _h in $AP_START_KNOWN; do
        [ "$1" = "$_h" ] && return 0
    done
    return 1
}

# Runs after the kernel is in place. Nothing here touches the boot partition,
# so every failure is a warning: you end up with the kernel you asked for and
# without the helper, which is recoverable by copying five files.
install_wlan() {
    [ "$WANT_WLAN" = 1 ] || return 0
    if [ "$WLAN_OK" != 1 ]; then
        say ""
        say "The WLAN helper was not installed. The kernel is in place; you can"
        say "add the helper later from wlan-ap/ in the repository."
        return 0
    fi

    say "==> installing the WLAN helper into $WLAN_DIR"
    mkdir -p "$WLAN_DIR" 2>/dev/null \
        || { say "    cannot create $WLAN_DIR, skipped"; return 0; }

    mkdir -p "$MOD_DIR" "$WLAN_DIR/portal" "$WLAN_DIR/backup" 2>/dev/null \
        || { say "    cannot create the WLAN directories, skipped"; return 0; }

    # The driver. Without this the stick enumerates and nothing else happens:
    # no wlan0, no access point, no client mode.
    cp "$WORK/8188eu.ko" "$MOD_DIR/8188eu.ko" \
        || { say "    could not write the driver module, skipped"; return 0; }
    chmod 600 "$MOD_DIR/8188eu.ko"
    check_module_vermagic

    for f in wpa_supplicant wpa_cli hostapd dnsmasq wlan-menu.py wlan-apply.sh \
             captive.py restart-cap.sh; do
        cp "$WORK/$f" "$WLAN_DIR/$f" && chmod 700 "$WLAN_DIR/$f" \
            || { say "    could not write $f, skipped"; return 0; }
    done
    cp "$WORK/dnsmasq.conf" "$WLAN_DIR/dnsmasq.conf" && chmod 600 "$WLAN_DIR/dnsmasq.conf"
    cp "$WORK/portal-index.html" "$WLAN_DIR/portal/index.html" && chmod 644 "$WLAN_DIR/portal/index.html"

    install_hostapd_conf
    install_initd
    install_nginx_block

    # ap-start.sh is the one file here that might be yours: it is what the
    # autostart hook calls, and people edit it. Replaced only when it is
    # byte-for-byte something we shipped.
    # Written as an if: under set -e a bare "[ -f x ] && y" is a failing
    # command when x is absent, which is the normal first-install case.
    cur=""
    if [ -f "$WLAN_DIR/ap-start.sh" ]; then
        cur=$(sha256sum "$WLAN_DIR/ap-start.sh" | cut -d' ' -f1)
    fi
    if [ -z "$cur" ] || is_known_ap_start "$cur"; then
        cp "$WORK/ap-start.sh" "$WLAN_DIR/ap-start.sh"
        chmod 700 "$WLAN_DIR/ap-start.sh"
    else
        say "    $WLAN_DIR/ap-start.sh is not one of ours, left untouched."
        say "    Client mode at boot needs it to call wlan-apply.sh --"
        say "    see docs/wlan-ap.md."
    fi

    # Absent a mode file, wlan-apply.sh starts the access point, which is what
    # this device did before. Writing it makes that explicit rather than
    # implicit, and never overrides a mode you already chose.
    [ -f "$WLAN_DIR/mode" ] || echo ap > "$WLAN_DIR/mode"

    say "    run $WLAN_DIR/wlan-menu.py to switch between access point and client"
    say "    the access point starts by itself at the next boot"
}

# ------------------------------------------------------------------------ list
if [ "$MODE" = list ]; then
    # boot-*.img, not just boot-backup-*.img: images put there by hand are just
    # as valid a target.
    found=$(ls -1t "$BACKUP_DIR"/boot-*.img 2>/dev/null || true)
    [ -n "$found" ] || die "no images in $BACKUP_DIR yet.
An install puts one there before it writes, so there is nothing to roll back to."
    say "Images in $BACKUP_DIR, newest first:"
    for f in $found; do
        printf '    %10d  %s\n' "$(stat -c%s "$f")" "$f"
    done
    say ""
    if [ -n "$SELF" ]; then
        say "Roll back with: $SELF --revert <file>"
    else
        say "Roll back with: cat <file> > $BOOT && sync"
    fi
    exit 0
fi

# ---------------------------------------------------------------------- revert
if [ "$MODE" = revert ]; then
    [ -f "$PICK" ] || die "no such file: $PICK"
    [ -s "$PICK" ] || die "$PICK is empty"
    say "About to overwrite the boot partition of this device with"
    say "  $PICK"
    confirm
    say "==> reverting to $PICK"
    write_and_verify "$PICK" "$PICK" || die "write verification failed.
The partition is now in an unknown state. Do not power-cycle. Retry, or use
the U-Boot route in docs/recovery.md with a serial console."
    epilogue
    exit 0
fi

# --------------------------------------------------------------------- install
say "==> checking the device"
command -v python3 >/dev/null || die "python3 not found"
is_fit "$BOOT" || die "the boot partition does not start with the FIT magic.
This is not a layout we know how to patch. Please open an issue at $ISSUES"
say "    RM1PE, stock firmware $RK_VERSION, boot partition $PART_BYTES bytes"

FREE_KB=$(df -P /userdata | awk 'NR==2 {print $4}')
[ "$FREE_KB" -ge "$NEED_KB" ] || die "only ${FREE_KB} kB free on /userdata, need ${NEED_KB} kB"

rm -rf "$WORK"; mkdir -p "$WORK" "$BACKUP_DIR"
trap 'rm -rf "$WORK"' EXIT

fetch() {  # fetch <url> <dest> <expected-sha256>
    curl -sSL --fail -o "$2" "$1" || die "download failed: $1"
    got=$(sha256sum "$2" | cut -d' ' -f1)
    [ "$got" = "$3" ] || die "checksum mismatch for $(basename "$2")
    expected $3
    got      $got"
}

try_fetch() {  # same, but a failure is reported and survivable
    curl -sSL --fail -o "$2" "$1" 2>/dev/null \
        || { say "    download failed: $1"; return 1; }
    got=$(sha256sum "$2" | cut -d' ' -f1)
    [ "$got" = "$3" ] && return 0
    say "    checksum mismatch for $(basename "$2")"
    return 1
}

if [ -n "$KERNEL_FILE" ]; then
    say "==> using local kernel $KERNEL_FILE"
    cp "$KERNEL_FILE" "$WORK/kernel"
    got=$(sha256sum "$WORK/kernel" | cut -d' ' -f1)
    [ "$got" = "$KERNEL_SHA" ] || die "local kernel does not match the pinned checksum"
else
    say "==> fetching $KERNEL_NAME"
    fetch "$REL/$KERNEL_NAME" "$WORK/kernel" "$KERNEL_SHA"
fi
if [ -n "$PATCHER_FILE" ]; then
    cp "$PATCHER_FILE" "$WORK/patch-fit.py"
    got=$(sha256sum "$WORK/patch-fit.py" | cut -d' ' -f1)
    [ "$got" = "$PATCHER_SHA" ] || die "local patcher does not match the pinned checksum"
else
    fetch "$RAW/scripts/patch-fit.py" "$WORK/patch-fit.py" "$PATCHER_SHA"
fi
say "    checksums ok"

# Fetched now so a network problem shows up before anything is written, but
# kept out of the way of the kernel install if it fails.
if [ "$WANT_WLAN" = 1 ]; then
    say "==> fetching the WLAN files"
    if try_fetch "$REL/8188eu.ko"                 "$WORK/8188eu.ko"          "$MODULE_SHA" \
    && try_fetch "$REL/hostapd"                   "$WORK/hostapd"            "$HOSTAPD_SHA" \
    && try_fetch "$REL/dnsmasq"                   "$WORK/dnsmasq"            "$DNSMASQ_SHA" \
    && try_fetch "$REL/wpa_supplicant"            "$WORK/wpa_supplicant"     "$WPA_SHA" \
    && try_fetch "$REL/wpa_cli"                   "$WORK/wpa_cli"            "$WPA_CLI_SHA" \
    && try_fetch "$RAW/wlan-ap/wlan-menu.py"      "$WORK/wlan-menu.py"       "$MENU_SHA" \
    && try_fetch "$RAW/wlan-ap/wlan-apply.sh"     "$WORK/wlan-apply.sh"      "$APPLY_SHA" \
    && try_fetch "$RAW/wlan-ap/ap-start.sh"       "$WORK/ap-start.sh"        "$APSTART_SHA" \
    && try_fetch "$RAW/wlan-ap/S99wlan-ap"        "$WORK/S99wlan-ap"         "$INITD_SHA" \
    && try_fetch "$RAW/wlan-ap/captive.py"        "$WORK/captive.py"         "$CAPTIVE_SHA" \
    && try_fetch "$RAW/wlan-ap/dnsmasq.conf"      "$WORK/dnsmasq.conf"       "$DNSMASQ_CONF_SHA" \
    && try_fetch "$RAW/wlan-ap/restart-cap.sh"    "$WORK/restart-cap.sh"     "$RESTARTCAP_SHA" \
    && try_fetch "$RAW/wlan-ap/hostapd.conf.example" "$WORK/hostapd.conf.example" "$HOSTAPD_EXAMPLE_SHA" \
    && try_fetch "$RAW/wlan-ap/nginx-ap-block.conf"  "$WORK/nginx-ap-block.conf"  "$NGINX_BLOCK_SHA" \
    && try_fetch "$RAW/wlan-ap/portal/index.html" "$WORK/portal-index.html"  "$PORTAL_SHA"
    then
        WLAN_OK=1
        say "    checksums ok"
    else
        say "    the kernel install continues without it"
    fi
fi

# Build first: nothing is written anywhere until the image is known good.
say "==> building the new image"
python3 "$WORK/patch-fit.py" "$BOOT" "$WORK/kernel" "$WORK/new.img" \
    || die "patching failed, nothing written"
NEW_BYTES=$(stat -c%s "$WORK/new.img")
[ "$NEW_BYTES" -le "$PART_BYTES" ] \
    || die "new image is $NEW_BYTES bytes, larger than the $PART_BYTES byte partition"

say ""
say "About to overwrite the boot partition of this device with kernel $TAG."
say "A backup of the current partition is written first, and nothing reboots."
confirm

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$BACKUP_DIR/boot-backup-$STAMP.img"
say "==> backing up the current boot partition to $BACKUP"
cat "$BOOT" > "$BACKUP"
sync
[ "$(stat -c%s "$BACKUP")" = "$PART_BYTES" ] || die "backup is short, aborting"
# This backup is the way back, and the user is told so at the end. A size
# check does not prove it was copied correctly, so compare the content.
if [ "$(sha256sum "$BACKUP" | cut -d' ' -f1)" \
   != "$(head -c "$PART_BYTES" "$BOOT" | sha256sum | cut -d' ' -f1)" ]; then
    rm -f "$BACKUP"
    die "the backup does not match the partition it was copied from.
Refusing to continue: without a good backup there is no way back.
Check free space and the health of /userdata, then try again."
fi
say "    backup verified"

if ! write_and_verify "$WORK/new.img" "the new image"; then
    say "    MISMATCH after write, restoring the backup"
    cat "$BACKUP" > "$BOOT"; sync
    die "write verification failed; the old partition has been restored"
fi

install_wlan

epilogue
say ""
if [ -n "$SELF" ]; then
    say "To go back:  $SELF --revert $BACKUP"
    say "             (or without this script: cat $BACKUP > $BOOT && sync)"
else
    say "To go back:  cat $BACKUP > $BOOT && sync"
    say "             then power-cycle. Keeping a copy of install.sh on the"
    say "             device gives you --list and --revert instead."
fi
say "If it does not come back, see docs/recovery.md (serial console + U-Boot)."
