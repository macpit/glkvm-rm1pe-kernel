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
    echo "Backups on the device, newest first:"
    ssh "$SSH_USER@$DEV" "ls -1t $BACKUP_DIR/boot-backup-*.img 2>/dev/null" || {
        echo "  none found. If the device no longer boots: docs/recovery.md" >&2
        exit 1
    }
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
