#!/bin/sh
# Build the SMB server pieces for the KVM on the dev machine:
#
#   * ksmbd.ko, cifs_arc4.ko, cifs_md4.ko -- from the kernel tree, against
#     the build directory the kernel image came from (Module.symvers must
#     match, see docs/dev-machine.md)
#   * ksmbd.tools -- ksmbd-tools 3.5.2 (one multi-call binary that acts as
#     ksmbd.mountd/adduser/control depending on its name), built statically
#     against musl with Buildroot (it drags glib2 and libnl in)
#
#   sh scripts/build-ksmbd.sh <kernel-src> <kernel-build-dir> <out-dir>
#
# Output: the four files in <out-dir> plus their sha256, ready to upload as
# release assets and to paste into install-smb.sh.
set -eu

SRC=${1:?kernel source tree}
BUILD=${2:?kernel build dir (with .config and Module.symvers)}
OUT=${3:?output dir}
BR_VERSION=2024.02.11
JOBS=$(nproc 2>/dev/null || echo 4)

export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
mkdir -p "$OUT"

# ---------------------------------------------------------------- modules
echo "==> ksmbd modules"
cp "$BUILD/.config" "$BUILD/.config.pre-ksmbd"
"$SRC/scripts/config" --file "$BUILD/.config" \
    --enable NETWORK_FILESYSTEMS --module SMB_SERVER \
    --disable SMB_SERVER_SMBDIRECT --enable SMB_SERVER_CHECK_CAP_NET_ADMIN \
    --disable SMB_SERVER_KERBEROS5 --disable CIFS --disable NFS_FS --disable NFSD \
    --disable CEPH_FS --disable 9P_FS --disable AFS_FS --disable CODA_FS --disable ORANGEFS_FS
make -s -C "$SRC" O="$BUILD" olddefconfig
make -j"$JOBS" -C "$SRC" O="$BUILD" modules
for f in fs/smb/server/ksmbd.ko fs/smb/common/cifs_arc4.ko fs/smb/common/cifs_md4.ko; do
    ${CROSS_COMPILE}strip --strip-debug "$BUILD/$f" -o "$OUT/$(basename "$f")"
done

# ------------------------------------------------------------ ksmbd-tools
echo "==> ksmbd-tools (Buildroot $BR_VERSION, static musl)"
BR=$OUT/.buildroot
mkdir -p "$BR"; cd "$BR"
[ -f "buildroot-$BR_VERSION.tar.gz" ] || wget -q "https://buildroot.org/downloads/buildroot-$BR_VERSION.tar.gz"
[ -d "buildroot-$BR_VERSION" ] || tar xzf "buildroot-$BR_VERSION.tar.gz"
cd "buildroot-$BR_VERSION"
cat > configs/ksmbd_static_defconfig <<'CFG'
BR2_aarch64=y
BR2_cortex_a53=y
BR2_TOOLCHAIN_EXTERNAL=y
BR2_TOOLCHAIN_EXTERNAL_BOOTLIN=y
BR2_TOOLCHAIN_EXTERNAL_BOOTLIN_AARCH64_MUSL_STABLE=y
BR2_STATIC_LIBS=y
BR2_INIT_NONE=y
BR2_SYSTEM_BIN_SH_NONE=y
# BR2_PACKAGE_BUSYBOX is not set
# BR2_TARGET_ROOTFS_TAR is not set
BR2_PACKAGE_KSMBD_TOOLS=y
CFG
make ksmbd_static_defconfig >/dev/null
make -j"$JOBS" ksmbd-tools
# one multi-call binary; the device gets symlinks ksmbd.{mountd,adduser,control}
output/host/bin/aarch64-linux-strip output/target/usr/libexec/ksmbd.tools -o "$OUT/ksmbd.tools"

cd "$OUT"
echo "==> done"
sha256sum ksmbd.ko cifs_arc4.ko cifs_md4.ko ksmbd.tools
