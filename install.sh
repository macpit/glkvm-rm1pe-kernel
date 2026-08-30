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
# Read this before piping it into a shell. It overwrites a boot partition.
set -eu

REPO="macpit/glkvm-rm1pe-kernel"
TAG="${TAG:-v23}"
KERNEL_NAME="Image-6.1.141-${TAG}"
KERNEL_SHA="d96cd811f8cf3888a5185b9c69f5e379f36888527584842a0135092a850581fd"
PATCHER_SHA="4ed17024287a457625a20fa4c42848feade06baa5e6b7006ca0b238e8dc47c4e"

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
NEED_KB=81920                      # kernel + patched image + 32 MiB backup

# Offline / testing: point these at local files to skip the downloads.
KERNEL_FILE="${KERNEL_FILE:-}"
PATCHER_FILE="${PATCHER_FILE:-}"

say()  { printf '%s\n' "$*"; }
die()  { printf 'install: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<USAGE
usage:
  $0                  install the pinned release kernel ($TAG)
  $0 --list           list images in $BACKUP_DIR
  $0 --revert FILE    write FILE back into the boot partition
  -y, --yes           do not ask for confirmation

When piped straight into a shell, pass arguments after -s --, e.g.
  curl -sSL <url> | sh -s -- --list
USAGE
}

MODE=install
PICK=""
ASSUME_YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list)      MODE=list ;;
        --revert)    MODE=revert; PICK="${2:-}"; shift
                     [ -n "$PICK" ] || die "--revert needs a file; try --list" ;;
        -y|--yes)    ASSUME_YES=1 ;;
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
    cat "$1" > "$BOOT"
    sync
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
    say "Roll back with: $0 --revert <file>"
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
[ "$(stat -c%s "$BACKUP")" = "$PART_BYTES" ] || die "backup is short, aborting"

if ! write_and_verify "$WORK/new.img" "the new image"; then
    say "    MISMATCH after write, restoring the backup"
    cat "$BACKUP" > "$BOOT"; sync
    die "write verification failed; the old partition has been restored"
fi

epilogue
say ""
say "To go back:  $0 --revert $BACKUP"
say "             (or without this script: cat $BACKUP > $BOOT && sync)"
say "If it does not come back, see docs/recovery.md (serial console + U-Boot)."
