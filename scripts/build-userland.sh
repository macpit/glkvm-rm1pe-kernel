#!/bin/sh
# Cross-build the WLAN userland for the GL-RM1PE.
#
#     scripts/build-userland.sh [OUTDIR]
#
# Runs on the build machine, not on the KVM. Produces four stripped, statically
# linked aarch64 binaries in OUTDIR (default ./out-userland):
#
#     hostapd           access point mode
#     dnsmasq           DHCP and the wildcard DNS the captive portal needs
#     wpa_supplicant    client mode
#     wpa_cli           not required, but the only sane way to debug a link
#
# The release ships all four. This script exists so you do not have to take our
# word for what is in them, and so the LGPL parts stay relinkable.
#
# Not built here: the 8188eu driver module. It has to match your kernel build,
# so it lives in scripts/build-8188eu.sh instead.
#
# Why static: the RM1PE rootfs has no libnl and no package manager. A dynamic
# build would mean shipping shared objects and an LD_LIBRARY_PATH, which is
# more moving parts on a device where a failed WLAN switch costs you the link.
#
# Why no OpenSSL: CONFIG_TLS=internal drops the whole TLS and PKI stack. WPA2
# and WPA3 personal need none of it -- that is EAP territory, and the RM1PE is
# not going to join an enterprise network with a certificate. It also takes the
# build from something that needs a cross-compiled OpenSSL to something that
# needs nothing but a toolchain.
set -eu

OUT=$(cd "$(dirname "${1:-.}")" 2>/dev/null && pwd)/$(basename "${1:-out-userland}")
CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
WORK="${WORK:-$(pwd)/.userland-build}"

NL_VER=3.7.0
NL_TAR="libnl-${NL_VER}.tar.gz"
NL_URL="https://github.com/thom311/libnl/releases/download/libnl3_7_0/${NL_TAR}"
NL_SHA="9fe43ccbeeea72c653bdcf8c93332583135cda46a79507bfd0a483bb57f65939"

WPA_VER=2.11
WPA_TAR="wpa_supplicant-${WPA_VER}.tar.gz"
WPA_URL="https://w1.fi/releases/${WPA_TAR}"
WPA_SHA="912ea06f74e30a8e36fbb68064d6cdff218d8d591db0fc5d75dee6c81ac7fc0a"

# hostapd and dnsmasq come from git at a pinned commit. hostapd because the
# 2.11 release predates fixes we want; dnsmasq because upstream has no tarball
# newer than 2.90 and we are on master.
HOSTAP_URL="https://w1.fi/hostap.git"
HOSTAP_COMMIT="168f9755d9d0b90eb0f31147330c4d8a1fc7f4d6"

DNSMASQ_URL="https://thekelleys.org.uk/git/dnsmasq.git"
DNSMASQ_COMMIT="cf9c9c74e047b9203222d46e9df81d72f103cc7f"

say() { printf '%s\n' "$*"; }
die() { printf 'build-userland: %s\n' "$*" >&2; exit 1; }

command -v "${CROSS}gcc" >/dev/null \
    || die "${CROSS}gcc not found. See docs/dev-machine.md, or set CROSS_COMPILE."
for t in curl git tar make sha256sum pkg-config; do
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

clone_at() {  # clone_at <url> <dir> <commit>
    if [ ! -d "$WORK/$2/.git" ]; then
        say "==> cloning $2"
        git clone -q "$1" "$WORK/$2" || die "clone failed: $1"
    fi
    ( cd "$WORK/$2"
      git fetch -q origin "$3" 2>/dev/null || git fetch -q origin
      git checkout -q "$3" || die "commit $3 not found in $2"
    )
    got=$(cd "$WORK/$2" && git rev-parse HEAD)
    [ "$got" = "$3" ] || die "$2 is at $got, expected $3"
}

mkdir -p "$WORK" "$OUT"
SYSROOT="$WORK/sysroot"

# ------------------------------------------------------------------- libnl
# Shared by hostapd and wpa_supplicant; both talk to the kernel over nl80211.
fetch "$NL_URL" "$NL_TAR" "$NL_SHA"
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

# pkg-config finds our libnl through PKG_CONFIG_LIBDIR, but it emits only
# -lnl-3 without a search path, so -L has to go in by hand or the link fails
# with "cannot find -lnl-3".
NL_ENV="PKG_CONFIG_PATH=$SYSROOT/lib/pkgconfig PKG_CONFIG_LIBDIR=$SYSROOT/lib/pkgconfig"
NL_LDFLAGS="-static -L$SYSROOT/lib"

# ----------------------------------------------------------- wpa_supplicant
fetch "$WPA_URL" "$WPA_TAR" "$WPA_SHA"
say "==> building wpa_supplicant $WPA_VER"
rm -rf "$WORK/wpa_supplicant-$WPA_VER"
tar -C "$WORK" -xf "$WORK/$WPA_TAR"
SRC="$WORK/wpa_supplicant-$WPA_VER/wpa_supplicant"

cat > "$SRC/.config" <<'EOF'
# Minimal build for the GL-RM1PE: WPA2/WPA3 personal over nl80211.
CONFIG_DRIVER_NL80211=y
CONFIG_LIBNL32=y
CONFIG_CTRL_IFACE=y
CONFIG_BACKEND=file
CONFIG_TLS=internal
CONFIG_INTERNAL_LIBTOMMATH=y
CONFIG_DEBUG_FILE=y
CONFIG_IEEE80211W=y
EOF

env $NL_ENV make -C "$SRC" CC="${CROSS}gcc" LDFLAGS="$NL_LDFLAGS" \
    -j"$(nproc)" wpa_supplicant wpa_cli >"$WORK/wpa-make.log" 2>&1 \
    || { tail -30 "$WORK/wpa-make.log"; die "wpa_supplicant build failed"; }
cp "$SRC/wpa_supplicant" "$SRC/wpa_cli" "$WORK/"

# ------------------------------------------------------------------ hostapd
clone_at "$HOSTAP_URL" hostap "$HOSTAP_COMMIT"
say "==> building hostapd"
HSRC="$WORK/hostap/hostapd"

cat > "$HSRC/.config" <<'EOF'
# Access point for the RM1PE: WPA2 personal over nl80211, internal crypto.
CONFIG_DRIVER_NL80211=y
CONFIG_LIBNL32=y
CONFIG_RSN_PREAUTH=y
CONFIG_TLS=internal
CONFIG_INTERNAL_LIBTOMMATH=y
CONFIG_IPV6=y
EOF

make -C "$HSRC" clean >/dev/null 2>&1 || true
env $NL_ENV make -C "$HSRC" CC="${CROSS}gcc" LDFLAGS="$NL_LDFLAGS" \
    -j"$(nproc)" hostapd >"$WORK/hostapd-make.log" 2>&1 \
    || { tail -30 "$WORK/hostapd-make.log"; die "hostapd build failed"; }
cp "$HSRC/hostapd" "$WORK/"

# ------------------------------------------------------------------ dnsmasq
clone_at "$DNSMASQ_URL" dnsmasq "$DNSMASQ_COMMIT"
say "==> building dnsmasq"
make -C "$WORK/dnsmasq" clean >/dev/null 2>&1 || true
make -C "$WORK/dnsmasq" CC="${CROSS}gcc" LDFLAGS="-static" \
    -j"$(nproc)" >"$WORK/dnsmasq-make.log" 2>&1 \
    || { tail -30 "$WORK/dnsmasq-make.log"; die "dnsmasq build failed"; }
cp "$WORK/dnsmasq/src/dnsmasq" "$WORK/"

# ------------------------------------------------------------------- verify
for b in hostapd dnsmasq wpa_supplicant wpa_cli; do
    "${CROSS}strip" -o "$OUT/$b" "$WORK/$b"
    if "${CROSS}readelf" -d "$OUT/$b" 2>/dev/null | grep -qi needed; then
        die "$b came out dynamically linked; it will not run on the device"
    fi
done

say ""
for b in hostapd dnsmasq wpa_supplicant wpa_cli; do
    say "    $(stat -c%s "$OUT/$b" | awk '{printf "%9d", $1}') bytes  $(sha256sum "$OUT/$b" | cut -d' ' -f1)  $b"
done
say ""
say "Copy all four to /userdata/wlan-ap/ on the device and chmod 700 them."
say "Intermediate files are in $WORK; delete it when you are done."
