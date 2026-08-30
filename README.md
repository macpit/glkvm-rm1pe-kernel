# glkvm-rm1pe-kernel

A self-built kernel for the **GL.iNet GL-RM1PE** (Comet PoE) that does what the
stock one does, plus the things it does not: USB WLAN with a working access
point, and an HDMI capture path that survives a cold start.

Everything here is built from public sources: GL.iNet's
[kernel-6.1](https://github.com/gl-inet/kernel-6.1), the upstream stable
patches, and the changes in `patches/`. No vendor binaries are redistributed.

> ### Read this before you flash anything
>
> **A kernel without the `version` sysfs attribute on the LT6911C will reflash
> the chip's firmware in a loop.** `/etc/init.d/S23hdmi` reads
> `/sys/bus/i2c/devices/1-002b/version` at every boot and, on a mismatch, runs
> `lt6911c_upgrade -f v3.bin`, which erases and rewrites the SPI flash inside
> the HDMI bridge, then reboots. Miss that attribute and the cycle repeats on
> every boot. Patch `0004` implements it. Do not drop it, and do not build a
> partial driver.
>
> If you see `>>> erase flash over` or `write firmware 286` on the serial
> console, pull the power immediately.
>
> A serial console is strongly recommended for the first flash. See
> [docs/recovery.md](docs/recovery.md).

### Status: first cut

This is release one. It runs well on the two devices we have, and it has not
been near anyone else's hardware yet. Treat it accordingly.

You should be comfortable with a cross-compiled kernel build, with reading a
boot log, and with the idea that the device may not come back on its own. The
install and revert scripts only help while the device still boots far enough
for SSH. **Once it does not, you need a serial console** — and on the RM1PE
that means opening the case and soldering a wire to the RX pad, because it is
not broken out. If that sentence gives you pause, wait for a later release or
get the cable ready before you start, not after.

Everything else here is reversible. `install-kernel.sh` backs up the running
boot partition before it writes, and `revert-kernel.sh` puts it back.

## What works

| | |
| --- | --- |
| HDMI capture | 2560x1440@60, 4K30, 1080p, and anything else the chip accepts |
| Cold start | Picture is up ~90 ms after the driver probes, without any manual step |
| USB WLAN | Realtek RTL8188EU (`0bda:8179`), station and access point |
| Access point | hostapd + dnsmasq + a captive portal that shows the KVM address |
| Vendor modules | All six load: `kmpp`, `kmpp_smart`, `rockit*`, `gl-hw-info` |
| Streaming | Unchanged: kvmd, ustreamer, WebRTC over the vendor pipeline |

Tested on GL-RM1PE with firmware V1.9.1 release1, kernel 6.1.141.

## Quick start

You need a build machine with an aarch64 cross toolchain, `u-boot-tools` and
`device-tree-compiler`, plus SSH access to the KVM.

```sh
git clone https://github.com/gl-inet/kernel-6.1 kernel && cd kernel
# 1. bring the tree to 6.1.141  -- see docs/build.md, this is required
# 2. apply our patches
for p in ../glkvm-rm1pe-kernel/patches/*.patch; do git apply "$p"; done
# 3. build
touch .scmversion
make ARCH=arm64 O=../build rv1126bp_gl_rm1_poe_defconfig
make ARCH=arm64 O=../build olddefconfig
make ARCH=arm64 O=../build CROSS_COMPILE="aarch64-linux-gnu-" -j"$(nproc)" \
     Image modules rockchip/rv1126bp-evb-v14.dtb
```

Then pack and install:

```sh
scripts/build-fit.sh 192.168.1.10 ../build/arch/arm64/boot/Image boot-custom.img
scripts/install-kernel.sh 192.168.1.10 boot-custom.img
# power-cycle the device yourself
```

`build-fit.sh` pulls the device tree and the Rockchip resource blob **from your
own device** and packs them with your kernel. You always boot the DTB that
matches your hardware, and nothing proprietary passes through this repository.

To go back:

```sh
scripts/revert-kernel.sh 192.168.1.10            # lists the backups
scripts/revert-kernel.sh 192.168.1.10 /userdata/kernel-backup/boot-backup-....img
```

`install-kernel.sh` backs up the running boot partition before it writes, so
the way back exists from the first run onwards.

## Why the stock source tree is not enough

The published `gl-inet/kernel-6.1` builds, but it is not the source of the
kernel that ships on the device:

* `drivers/media/i2c/lt6911c.c` is byte-identical to Rockchip's BSP (blob
  `6b2f33a1`) and identifies as version 00.01.00. The shipped driver is newer
  and behaves differently in ways that matter for locking to a source.
* The defconfig is missing `CONFIG_ROCKCHIP_DVBM`, `CONFIG_HWSPINLOCK` +
  `CONFIG_HWSPINLOCK_ROCKCHIP` and `CONFIG_VIDEO_LT6911C`. Without the second
  pair the kernel panics at about 25 seconds; see `docs/build.md`.
* There is no board device tree at all, only Rockchip EVBs.

We have asked GL.iNet for the complete corresponding source under GPLv2 §3 in
[glkvm#152](https://github.com/gl-inet/glkvm/issues/152). Until that lands,
this repository is the practical way to a kernel you can actually modify.

## Layout

```
patches/    the four patches, in order
scripts/    build the FIT, install it, roll it back -- all over SSH
wlan-ap/    access point and captive portal, ready to drop into /userdata
docs/       build, recovery, the LT6911C driver, the access point
```

## Planned

* **Patch GL.iNet's own firmware images.** Right now you build a kernel and
  install it onto a device that is already running. The nicer path is to take
  an official OTA image, replace the kernel inside it, and flash the result
  through the normal update mechanism — no cross toolchain, no SSH surgery, and
  a familiar way back by simply reinstalling the stock image. The RKFW/RKAF
  format is already understood well enough to unpack and repack; what is
  missing is the tooling and a second device to test it on without risking the
  working one. Note that this will always be a script you run on an image *you*
  downloaded: a pre-patched image would mean redistributing GL's binaries,
  which is exactly what we are asking them not to do to us.
* **Audio.** The sample rate is still hardcoded to 48 kHz upstream of us
  ([glkvm#136](https://github.com/gl-inet/glkvm/issues/136)); non-48 kHz sources
  come through pitch-shifted. Untouched so far.
* **The measurement bug from the forum**, where the chip reports the active
  resolution one or two pixels off. Present on stock firmware too, and not
  fixed in 1.10.x.
* **More WLAN sticks**, once someone reports what works.

## Contributing

Bug reports and patches are welcome, especially from anyone with a different
HDMI source, a different WLAN stick, or an RM10. The LT6911C is used on several
devices and the driver situation is the same everywhere.

If you have a source that shows a picture on the stock firmware but not here,
open an issue with `dmesg | grep lt6911` and the output of
`cat /sys/bus/i2c/devices/1-002b/resolution`.

## License

GPL-2.0. The driver changes are derived from Linux and the Rockchip BSP and are
GPL-2.0 by descent; the scripts and the portal are ours and released under the
same license so the whole tree stays under one set of terms.

## Credits

Built on GL.iNet's and Rockchip's published trees. The audio sample-rate
analysis in [glkvm#136](https://github.com/gl-inet/glkvm/issues/136) by
@tokoroten and the ZHAW
[LT6911UXC driver](https://github.com/InES-HPMM/Lontium_lt6911uxc) were useful
references for the chip family.
