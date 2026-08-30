#!/bin/bash
# Roll the boot partition back to a backup made by install-kernel.sh.
#
# Works as long as the device still boots far enough for SSH. If it does not,
# use the U-Boot route in docs/recovery.md instead, which needs a serial cable
# but no working userspace.
set -eu

DEV=${1:-}
PICK=${2:-}
SSH_USER=${SSH_USER:-root}
BACKUP_DIR=/userdata/kernel-backup

[ -n "$DEV" ] || { echo "usage: $0 <device-ip> [backup-file]" >&2; exit 1; }

if [ -z "$PICK" ]; then
    # boot-*.img, not just boot-backup-*.img: images put there by hand are just
    # as valid a target, and a stock device has none of either until the first
    # install-kernel.sh run.
    LIST=$(ssh "$SSH_USER@$DEV" "ls -1t $BACKUP_DIR/boot-*.img 2>/dev/null || true") || {
        echo "cannot reach $DEV over SSH." >&2
        echo "If the device no longer boots at all, use the U-Boot route in docs/recovery.md" >&2
        exit 1
    }
    if [ -z "$LIST" ]; then
        echo "No images in $BACKUP_DIR on $DEV." >&2
        echo "install-kernel.sh puts one there before it writes, so there is" >&2
        echo "nothing to roll back to yet." >&2
        exit 1
    fi
    echo "Images on the device, newest first:"
    echo "$LIST"
    echo
    echo "Pick one: $0 $DEV <file>"
    exit 0
fi

echo "==> restoring $PICK"
ssh "$SSH_USER@$DEV" "test -s $PICK" || { echo "no such backup on device" >&2; exit 1; }
ssh "$SSH_USER@$DEV" "SIZE=\$(stat -c%s $PICK); \
    cat $PICK > /dev/block/by-name/boot && sync && sleep 1 && \
    A=\$(sha256sum $PICK | cut -d' ' -f1); \
    B=\$(head -c \$SIZE /dev/block/by-name/boot | sha256sum | cut -d' ' -f1); \
    if [ \"\$A\" = \"\$B\" ]; then echo \"    restored and verified: \$A\"; \
    else echo '    MISMATCH, use the U-Boot recovery in docs/recovery.md'; exit 1; fi"
echo
echo "Power-cycle the device to boot the restored kernel."
