#!/bin/bash
# Build a bootable FIT image for the GL-RM1PE from your own kernel.
#
# The boot partition holds a FIT with three parts: the kernel, the board device
# tree and a Rockchip resource blob. Only the kernel is ours. The device tree
# and the resource blob are taken from YOUR device, so you always boot with the
# DTB that matches your own hardware revision, and nothing proprietary needs to
# be redistributed.
#
# Runs on your build machine. Needs u-boot-tools (mkimage),
# device-tree-compiler (fdtget), ssh and dd.
set -eu

DEV=${1:-}
IMAGE=${2:-}
OUT=${3:-boot-custom.img}
SSH_USER=${SSH_USER:-root}

if [ -z "$DEV" ] || [ -z "$IMAGE" ]; then
    echo "usage: $0 <device-ip> <path-to-arch/arm64/boot/Image> [output.img]" >&2
    exit 1
fi

for t in mkimage fdtget ssh dd; do
    command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done
[ -f "$IMAGE" ] || { echo "no such kernel image: $IMAGE" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> reading the current boot partition from $DEV"
ssh "$SSH_USER@$DEV" \
    'dd if=/dev/block/by-name/boot bs=1M count=32 2>/dev/null' \
    > "$WORK/boot-original.img"
[ -s "$WORK/boot-original.img" ] || { echo "read failed" >&2; exit 1; }

echo "==> unpacking device tree and resource blob"
get() { fdtget -t x "$WORK/boot-original.img" "/images/$1" "$2" | tr -d ' \n'; }
for part in fdt resource; do
    pos=$((16#$(get "$part" data-position)))
    len=$((16#$(get "$part" data-size)))
    [ "$len" -gt 0 ] || { echo "$part: empty, refusing" >&2; exit 1; }
    dd if="$WORK/boot-original.img" of="$WORK/$part" bs=1 \
       skip="$pos" count="$len" status=none
    printf '    %-9s %8d bytes\n' "$part" "$len"
done
cp "$IMAGE" "$WORK/kernel"
printf '    %-9s %8d bytes (yours)\n' kernel "$(stat -c%s "$WORK/kernel")"

cat > "$WORK/boot.its" << 'ITS'
/dts-v1/;
/ {
    description = "FIT image with Linux kernel, FDT blob and resource";
    images {
        fdt {
            data = /incbin/("fdt");
            type = "flat_dt";
            arch = "arm64";
            compression = "none";
            load = <0xffffff00>;
            hash { algo = "sha256"; };
        };
        kernel {
            data = /incbin/("kernel");
            type = "kernel";
            arch = "arm64";
            os = "linux";
            compression = "none";
            entry = <0xffffff01>;
            load = <0xffffff01>;
            hash { algo = "sha256"; };
        };
        resource {
            data = /incbin/("resource");
            type = "multi";
            arch = "arm64";
            compression = "none";
            hash { algo = "sha256"; };
        };
    };
    configurations {
        default = "conf";
        conf {
            rollback-index = <0x00>;
            fdt = "fdt";
            kernel = "kernel";
            multi = "resource";
        };
    };
};
ITS

echo "==> packing the FIT"
# -E keeps the payloads outside the header, -p places them at 0x800, matching
# the original layout. A FIT with embedded data is NOT accepted by this
# U-Boot: it fails with "FIT: No fit blob".
#
# mkimage stamps the header with the current time, which is the only thing that
# differs between two builds of the same inputs. Set SOURCE_DATE_EPOCH to pin
# it and the output becomes reproducible byte for byte.
( cd "$WORK" && mkimage -f boot.its -E -p 0x800 -B 0x200 out.img >/dev/null )

fdtget -p "$WORK/out.img" /images/kernel | grep -q data-position || {
    echo "sanity check failed: payloads are not external" >&2; exit 1; }

cp "$WORK/out.img" "$OUT"
echo
echo "    $OUT"
echo "    $(stat -c%s "$OUT") bytes"
echo "    $(sha256sum "$OUT" | cut -d' ' -f1)"
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    echo
    echo "    (the header carries a build timestamp, so two runs of this script"
    echo "     differ in three bytes. Set SOURCE_DATE_EPOCH to pin it.)"
fi
echo
echo "Next: scripts/install-kernel.sh $DEV $OUT"
