#!/bin/sh
# Cross-build a static wpa_supplicant for the GL-RM1PE.
#
#     scripts/build-wpa-supplicant.sh [OUTDIR]
#
# Runs on the build machine, not on the KVM. Produces two stripped, statically
# linked aarch64 binaries in OUTDIR (default ./out-wpa):
#
#     wpa_supplicant    what client mode needs
#     wpa_cli           not required, but the only sane way to debug a link
#
# Copy both to /userdata/wlan-ap/ on the device. The release ships the same
# binaries; this script exists so you do not have to take our word for what is
# in them, and so the LGPL parts stay relinkable.
#
# Why static: the RM1PE rootfs has no libnl and no package manager. A dynamic
# build would mean shipping shared objects and an LD_LIBRARY_PATH, which is
# more moving parts on a device where a failed WLAN switch costs you the link.
#
# Why no OpenSSL: CONFIG_TLS=internal drops the whole TLS and PKI stack. WPA2
# and WPA3 personal need none of it -- that is EAP territory, and the RM1PE is
# not going to join an enterprise network with a certificate. It also takes the
# binary from something that needs a cross-built OpenSSL to something that
# needs nothing but a toolchain.
set -eu

OUT=$(cd "$(dirname "${1:-.}")" 2>/dev/null && pwd)/$(basename "${1:-out-wpa}")
CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
WORK="${WORK:-$(pwd)/.wpa-build}"

WPA_VER=2.11
WPA_TAR="wpa_supplicant-${WPA_VER}.tar.gz"
WPA_URL="https://w1.fi/releases/${WPA_TAR}"
WPA_SHA="912ea06f74e30a8e36fbb68064d6cdff218d8d591db0fc5d75dee6c81ac7fc0a"

NL_VER=3.7.0
NL_TAR="libnl-${NL_VER}.tar.gz"
NL_URL="https://github.com/thom311/libnl/releases/download/libnl3_7_0/${NL_TAR}"
NL_SHA="9fe43ccbeeea72c653bdcf8c93332583135cda46a79507bfd0a483bb57f65939"

say() { printf '%s\n' "$*"; }
die() { printf 'build-wpa-supplicant: %s\n' "$*" >&2; exit 1; }

command -v "${CROSS}gcc" >/dev/null \
    || die "${CROSS}gcc not found. See docs/dev-machine.md, or set CROSS_COMPILE."
for t in curl tar make sha256sum pkg-config; do
    command -v "$t" >/dev/null || die "$t not found"
done

fetch() {  # fetch <url> <file> <sha256>
    if [ ! -f "$WORK/$2" ]; then
        say "==> fetching $2"
        curl -fsSL -o "$WORK/$2.part" "$1" || die "download failed: $1"
        mv "$WORK/$2.part" "$WORK/$2"
    fi
    got=$(sha256sum "$WORK/$2" | cut -d' ' -f1)
    [ "$got" = "$3" ] || die "$2 checksum mismatch
  expected $3
  got      $got"
}

mkdir -p "$WORK" "$OUT"
fetch "$WPA_URL" "$WPA_TAR" "$WPA_SHA"
fetch "$NL_URL"  "$NL_TAR"  "$NL_SHA"

SYSROOT="$WORK/sysroot"

# ------------------------------------------------------------------- libnl
if [ ! -f "$SYSROOT/lib/libnl-genl-3.a" ]; then
    say "==> building libnl $NL_VER"
    rm -rf "$WORK/libnl-$NL_VER"
    tar -C "$WORK" -xf "$WORK/$NL_TAR"
    ( cd "$WORK/libnl-$NL_VER"
      ./configure --host="${CROSS%-}" --prefix="$SYSROOT" \
                  --disable-shared --enable-static --disable-cli \
                  CC="${CROSS}gcc" >"$WORK/libnl-configure.log" 2>&1 \
          || { tail -20 "$WORK/libnl-configure.log"; die "libnl configure failed"; }
      make -j"$(nproc)" >"$WORK/libnl-make.log" 2>&1 \
          || { tail -30 "$WORK/libnl-make.log"; die "libnl build failed"; }
      make install >/dev/null 2>&1
    )
fi

# ----------------------------------------------------------- wpa_supplicant
say "==> building wpa_supplicant $WPA_VER"
rm -rf "$WORK/wpa_supplicant-$WPA_VER"
tar -C "$WORK" -xf "$WORK/$WPA_TAR"
SRC="$WORK/wpa_supplicant-$WPA_VER/wpa_supplicant"

cat > "$SRC/.config" <<'EOF'
# Minimal build for the GL-RM1PE: WPA2/WPA3 personal over nl80211.
# No EAP, no OpenSSL -- CONFIG_TLS=internal keeps the TLS and PKI stack out,
# which is what makes a static binary practical here.
CONFIG_DRIVER_NL80211=y
CONFIG_LIBNL32=y
CONFIG_CTRL_IFACE=y
CONFIG_BACKEND=file
CONFIG_TLS=internal
CONFIG_INTERNAL_LIBTOMMATH=y
CONFIG_DEBUG_FILE=y
CONFIG_IEEE80211W=y
EOF

# pkg-config finds our libnl through PKG_CONFIG_LIBDIR, but it emits only
# -lnl-3 without a search path, so -L has to go in by hand or the link fails
# with "cannot find -lnl-3".
PKG_CONFIG_PATH="$SYSROOT/lib/pkgconfig" \
PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig" \
make -C "$SRC" CC="${CROSS}gcc" LDFLAGS="-static -L$SYSROOT/lib" \
     -j"$(nproc)" wpa_supplicant wpa_cli >"$WORK/wpa-make.log" 2>&1 \
    || { tail -30 "$WORK/wpa-make.log"; die "wpa_supplicant build failed"; }

# ------------------------------------------------------------------ verify
for b in wpa_supplicant wpa_cli; do
    "${CROSS}strip" -o "$OUT/$b" "$SRC/$b"
    if "${CROSS}readelf" -d "$OUT/$b" 2>/dev/null | grep -qi needed; then
        die "$b came out dynamically linked; it will not run on the device"
    fi
done

say ""
say "    $OUT/wpa_supplicant"
say "    $(stat -c%s "$OUT/wpa_supplicant") bytes  $(sha256sum "$OUT/wpa_supplicant" | cut -d' ' -f1)"
say "    $OUT/wpa_cli"
say "    $(stat -c%s "$OUT/wpa_cli") bytes  $(sha256sum "$OUT/wpa_cli" | cut -d' ' -f1)"
say ""
say "Copy both to /userdata/wlan-ap/ on the device and chmod 700 them."
say "Intermediate files are in $WORK; delete it when you are done."
