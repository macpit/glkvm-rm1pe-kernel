#!/bin/bash
# Install a FIT image into the boot partition of a GL-RM1PE, over SSH.
#
# Backs up the partition that is currently installed, writes the new image,
# reads it back and compares hashes. It never reboots: that is left to you,
# ideally with a serial console attached so you can watch the first boot.
set -eu

DEV=${1:-}
IMAGE=${2:-}
SSH_USER=${SSH_USER:-root}
BACKUP_DIR=/userdata/kernel-backup

if [ -z "$DEV" ] || [ -z "$IMAGE" ]; then
    echo "usage: $0 <device-ip> <boot-image>" >&2
    exit 1
fi
[ -f "$IMAGE" ] || { echo "no such image: $IMAGE" >&2; exit 1; }

SIZE=$(stat -c%s "$IMAGE")
HASH=$(sha256sum "$IMAGE" | cut -d' ' -f1)
NAME=$(basename "$IMAGE")

echo "==> checking the target device"
MODEL=$(ssh "$SSH_USER@$DEV" 'cat /proc/gl-hw-info/model 2>/dev/null || echo unknown')
if [ "$MODEL" != "rm1pe" ]; then
    echo "This device reports model '$MODEL', not 'rm1pe'. Refusing." >&2
    echo "Everything here is built for the GL-RM1PE (Comet PoE) only." >&2
    exit 1
fi
echo "    model rm1pe, ok"

echo "==> backing up the current boot partition"
STAMP=$(date +%Y%m%d-%H%M%S)
ssh "$SSH_USER@$DEV" "mkdir -p $BACKUP_DIR && \
    dd if=/dev/block/by-name/boot of=$BACKUP_DIR/boot-backup-$STAMP.img \
       bs=1M count=32 status=none && sync && \
    ls -l $BACKUP_DIR/boot-backup-$STAMP.img"

echo "==> transferring"
ssh "$SSH_USER@$DEV" "cat > $BACKUP_DIR/$NAME" < "$IMAGE"
REMOTE_HASH=$(ssh "$SSH_USER@$DEV" "sha256sum $BACKUP_DIR/$NAME | cut -d' ' -f1")
[ "$REMOTE_HASH" = "$HASH" ] || { echo "transfer corrupted, aborting" >&2; exit 1; }

echo "==> writing the boot partition"
ssh "$SSH_USER@$DEV" "cat $BACKUP_DIR/$NAME > /dev/block/by-name/boot && sync"
sleep 1
WRITTEN=$(ssh "$SSH_USER@$DEV" \
    "head -c $SIZE /dev/block/by-name/boot | sha256sum | cut -d' ' -f1")

echo
if [ "$WRITTEN" = "$HASH" ]; then
    echo "    written and verified: $HASH"
    echo
    echo "The device still runs the old kernel from RAM. Power-cycle it when"
    echo "you are ready. Pull the power rather than rebooting warm: a cold"
    echo "start is the only thing that exercises the HDMI bridge properly."
    echo "If it does not come back, see docs/recovery.md"
else
    echo "    MISMATCH, do not reboot" >&2
    echo "    expected $HASH" >&2
    echo "    found    $WRITTEN" >&2
    echo "    roll back with: scripts/revert-kernel.sh $DEV" >&2
    exit 1
fi
