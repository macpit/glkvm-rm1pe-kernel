#!/bin/sh
# Build the RTL8188EU driver module for the GL-RM1PE.
#
#     scripts/build-8188eu.sh /path/to/kernel-tree [OUTDIR]
#
# Runs on the build machine. Produces 8188eu.ko in OUTDIR (default ./out-8188eu).
#
# This is the piece that makes the USB stick appear as wlan0. Without it the
# kernel enumerates the device and then nothing happens -- no wlan0, no access
# point, no client mode. The in-tree r8188eu driver exists but does not do AP
# mode, which is the whole point here.
#
# The module is tied to the kernel it was built against: a module whose
# vermagic does not match the running kernel is refused by insmod. So this
# cannot be built once and shipped forever -- it has to be rebuilt whenever the
# kernel version changes, against the same tree scripts/build-fit.sh used.
set -eu

KSRC="${1:-}"
OUT=$(cd "$(dirname "${2:-.}")" 2>/dev/null && pwd)/$(basename "${2:-out-8188eu}")
CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
WORK="${WORK:-$(pwd)/.8188eu-build}"

DRIVER_URL="https://github.com/aircrack-ng/rtl8188eus.git"
DRIVER_COMMIT="af3bf004458f76b7aec33e9ba552cd382ed1f5c3"

say() { printf '%s\n' "$*"; }
die() { printf 'build-8188eu: %s\n' "$*" >&2; exit 1; }

[ -n "$KSRC" ] || die "usage: build-8188eu.sh /path/to/kernel-tree [OUTDIR]

The kernel tree is the one you built the kernel from -- see docs/build.md.
It must be configured and built already; this needs its Module.symvers."

KSRC=$(cd "$KSRC" 2>/dev/null && pwd) || die "no such directory: $1"
[ -f "$KSRC/Module.symvers" ] \
    || die "$KSRC has no Module.symvers -- build the kernel there first,
otherwise the module gets built without symbol versions and insmod will
refuse it on the device."

command -v "${CROSS}gcc" >/dev/null \
    || die "${CROSS}gcc not found. See docs/dev-machine.md, or set CROSS_COMPILE."
command -v git >/dev/null || die "git not found"

mkdir -p "$WORK" "$OUT"

if [ ! -d "$WORK/rtl8188eus/.git" ]; then
    say "==> cloning rtl8188eus"
    git clone -q "$DRIVER_URL" "$WORK/rtl8188eus" || die "clone failed"
fi
( cd "$WORK/rtl8188eus"
  git fetch -q origin "$DRIVER_COMMIT" 2>/dev/null || git fetch -q origin
  git checkout -q "$DRIVER_COMMIT" || die "commit $DRIVER_COMMIT not found"
)

say "==> building 8188eu.ko against $KSRC"
# The Makefile defaults to CONFIG_PLATFORM_I386_PC, which sets ARCH and KSRC
# for a host build. Command-line variables win over assignments in the file,
# so passing them here is enough -- no need to edit the Makefile.
make -C "$WORK/rtl8188eus" clean >/dev/null 2>&1 || true
make -C "$WORK/rtl8188eus" \
     ARCH=arm64 CROSS_COMPILE="$CROSS" KSRC="$KSRC" \
     -j"$(nproc)" >"$WORK/8188eu-make.log" 2>&1 \
    || { tail -40 "$WORK/8188eu-make.log"; die "module build failed"; }

[ -f "$WORK/rtl8188eus/8188eu.ko" ] || die "build produced no 8188eu.ko"
cp "$WORK/rtl8188eus/8188eu.ko" "$OUT/8188eu.ko"

VERMAGIC=$(strings "$OUT/8188eu.ko" | sed -n 's/^vermagic=//p' | head -1)
[ -n "$VERMAGIC" ] || die "the module has no vermagic; that build is not usable"

say ""
say "    $OUT/8188eu.ko"
say "    $(stat -c%s "$OUT/8188eu.ko") bytes  $(sha256sum "$OUT/8188eu.ko" | cut -d' ' -f1)"
say "    vermagic: $VERMAGIC"
say ""
say "This module only loads on a kernel whose vermagic matches exactly."
say "Copy it to /userdata/wlan-modules/ on the device."
say "Intermediate files are in $WORK; delete it when you are done."
