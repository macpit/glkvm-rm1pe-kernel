#!/bin/sh
# Install a prebuilt kernel into the boot partition of a GL-RM1PE.
#
# Runs ON THE DEVICE:
#     curl -sSL https://raw.githubusercontent.com/macpit/glkvm-rm1pe-kernel/main/install.sh | sh
#
# It backs up the current boot partition, swaps the kernel inside the existing
# FIT (keeping YOUR device tree and resource blob), writes it back and verifies
# the result. It never reboots. Every failure aborts before anything is written.
#
# Read this before piping it into a shell. It overwrites a boot partition.
set -eu

REPO="macpit/glkvm-rm1pe-kernel"
TAG="${TAG:-v23}"
KERNEL_NAME="Image-6.1.141-${TAG}"
KERNEL_SHA="d96cd811f8cf3888a5185b9c69f5e379f36888527584842a0135092a850581fd"
PATCHER_SHA="4ed17024287a457625a20fa4c42848feade06baa5e6b7006ca0b238e8dc47c4e"

REL="https://github.com/${REPO}/releases/download/${TAG}"
RAW="https://raw.githubusercontent.com/${REPO}/main"
BOOT="/dev/block/by-name/boot"
BACKUP_DIR="/userdata/kernel-backup"
WORK="/userdata/.glkvm-install"
NEED_KB=81920                      # kernel + patched image + 32 MiB backup

say()  { printf '%s\n' "$*"; }
die()  { printf 'install: %s\n' "$*" >&2; exit 1; }

# Offline / testing: point these at local files to skip the downloads.
KERNEL_FILE="${KERNEL_FILE:-}"
PATCHER_FILE="${PATCHER_FILE:-}"

[ "$(id -u)" = 0 ] || die "must run as root"

say "==> checking the device"
MODEL=$(cat /proc/gl-hw-info/model 2>/dev/null || echo unknown)
[ "$MODEL" = "rm1pe" ] || die "this device reports model '$MODEL', not 'rm1pe'. Refusing.
Everything here is built for the GL-RM1PE (Comet PoE) only."
[ -b "$BOOT" ] || die "no boot partition at $BOOT"
command -v python3 >/dev/null || die "python3 not found"
PART_BYTES=$(( $(cat "/sys/class/block/$(basename "$(readlink -f "$BOOT")")/size") * 512 ))
say "    model rm1pe, boot partition $PART_BYTES bytes"

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

say "==> building the new image"
python3 "$WORK/patch-fit.py" "$BOOT" "$WORK/kernel" "$WORK/new.img" \
    || die "patching failed, nothing written"
NEW_BYTES=$(stat -c%s "$WORK/new.img")
[ "$NEW_BYTES" -le "$PART_BYTES" ] \
    || die "new image is $NEW_BYTES bytes, larger than the $PART_BYTES byte partition"
NEW_SHA=$(sha256sum "$WORK/new.img" | cut -d' ' -f1)

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$BACKUP_DIR/boot-backup-$STAMP.img"
say "==> backing up the current boot partition to $BACKUP"
cat "$BOOT" > "$BACKUP"
[ "$(stat -c%s "$BACKUP")" = "$PART_BYTES" ] || die "backup is short, aborting"

say "==> writing"
cat "$WORK/new.img" > "$BOOT"
sync
sleep 1
BACK=$(head -c "$NEW_BYTES" "$BOOT" | sha256sum | cut -d' ' -f1)
if [ "$BACK" != "$NEW_SHA" ]; then
    say "    MISMATCH after write, restoring the backup"
    cat "$BACKUP" > "$BOOT"; sync
    die "write verification failed; the old partition has been restored"
fi

say ""
say "    written and verified: $NEW_SHA"
say ""
say "The device still runs the old kernel from RAM. Nothing has rebooted."
say "Power-cycle it when you are ready -- pull the power rather than rebooting"
say "warm, since only a cold start exercises the HDMI bridge properly."
say ""
say "To go back:  cat $BACKUP > $BOOT && sync"
say "If it does not come back, see docs/recovery.md (serial console + U-Boot)."
