# glkvm-rm1pe-kernel

A self-built kernel for the **GL.iNet GL-RM1PE** (Comet PoE) that does what the
stock one does, plus the things it does not: USB WLAN with a working access
point, and an HDMI capture path that survives a cold start.

Everything here is built from public sources: GL.iNet's
[kernel-6.1](https://github.com/gl-inet/kernel-6.1), the upstream stable
patches, and the changes in `patches/`. No vendor binaries are redistributed.

> ### Before you start
>
> Follow the instructions as written. If you skip steps or improvise, you will
> be recovering the device rather than using it.
>
> If the device stops booting, a serial console is what gets it back. The
> vendor's web and USB recovery routes do not work here -- see
> [docs/recovery.md](docs/recovery.md) for why, so you do not waste an evening
> discovering it yourself.
>
> Installing the prebuilt kernel is the safe route: it checks your device and
> firmware, backs the boot partition up and verifies everything it writes.
> **Building your own kernel has one hazard that can damage the HDMI bridge**
> -- read [docs/build.md](docs/build.md) first, all of it.

### Status

First release. It works on the device I have and has never touched anyone
else's hardware.

The install and revert paths run on the KVM itself and need nothing else. The
build route needs a cross toolchain and someone comfortable reading a boot log.
Either way, both only help while the device still boots far enough for a shell.
After that you are into recovery, and the honest answer is that the vendor's
failsafe routes did not work here at all -- every documented reset combination
was tried on a device that would not boot, and none of them brought it back.
Get a serial cable before you start if you do not have one. On the RM1PE that
also means opening the case and soldering to the RX pad, which is not broken
out.

Everything short of that is reversible: the boot partition is backed up and
verified before anything is written, and put back if the write does not
verify.

## What works

| | |
| --- | --- |
| HDMI capture | 2560x1440@60, 4K30, 1080p, and anything else the chip accepts |
| Cold start | Picture is up ~90 ms after the driver probes, without any manual step |
| USB WLAN | Realtek RTL8188EU (`0bda:8179`), station and access point |
| Access point | hostapd + dnsmasq + a captive portal that shows the KVM address |
| Client mode | Join an existing WLAN, with a menu to switch and a watchdog that puts the AP back if it fails |
| Vendor modules | All six load: `kmpp`, `kmpp_smart`, `rockit*`, `gl-hw-info` |
| Streaming | Unchanged: kvmd, ustreamer, WebRTC over the vendor pipeline |

## Tested with

| | |
| --- | --- |
| Device | GL.iNet **GL-RM1PE** (Comet PoE), `/proc/gl-hw-info/model` = `rm1pe` |
| Board | Rockchip RV1126B-P, device tree `Rockchip RV1126B-P EVB V14 Board` |
| Stock firmware | **V1.9.1 release1** (`RK_VERSION` in `/etc/version`) |
| HDMI bridge | LT6911C, chip firmware 49.25.3.3.1 |
| Kernel | 6.1.141, release `v23` |
| Sources tested | 2560x1440@60, 3840x2160@30, 1920x1080@60, 1920x1280@60 |
| WLAN stick | Realtek RTL8188EU (`0bda:8179`) |

`install.sh` **refuses to run on anything else.** If your firmware is newer,
that is not a bug report about your device -- open an issue with
`cat /etc/version` and it gets added once it has been checked.

Two honest limits. This has run on **one** device, which has been through every
version of this kernel; a factory-fresh unit is not the same test. And there is
no long-term data yet -- days of uptime, not weeks.

If you are on a different firmware or an RM10 and want to help, that is exactly
the gap: an issue with your `/etc/version` is a useful contribution.

## Two ways in

**Just run the kernel.** Everything happens in a shell on the KVM: no build
machine, no toolchain, no SSH from anywhere else. Install and roll back are both
covered in [docs/device-only.md](docs/device-only.md), and the short version is
the [one-liner](#install-without-building) below.

**Change the kernel.** Then you need a build machine.
[docs/dev-machine.md](docs/dev-machine.md) lists exactly what to install on a
Debian 12 box, and the quick start below is the build itself.

## Quick start

You need a build machine with an aarch64 cross toolchain, `u-boot-tools` and
`device-tree-compiler`, plus SSH access to the KVM. Full package list and setup:
[docs/dev-machine.md](docs/dev-machine.md).

The scripts in `scripts/` run on that build machine, not on the KVM: they call
`mkimage` and `fdtget`, which the device does not have. They also assume
key-based SSH, so run `ssh-copy-id root@<device>` first -- otherwise every step
stops to ask for the dropbear password.

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

`mkimage` stamps the FIT header with the build time, so two runs over the same
inputs differ in three bytes. Set `SOURCE_DATE_EPOCH` to pin it and the output
is reproducible byte for byte:

```sh
SOURCE_DATE_EPOCH=1788075901 scripts/build-fit.sh 192.168.1.10 ../build/arch/arm64/boot/Image out.img
```

## Install without building

If you only want the release kernel and not a build environment, this runs on
the KVM itself:

```sh
curl -sSL https://raw.githubusercontent.com/macpit/glkvm-rm1pe-kernel/main/install.sh | sh
```

Before it touches anything it makes sure this is the right device and a
firmware we have actually run on:

* the model has to agree across three independent sources -- `gl-hw-info`,
  `RK_MODEL` in `/etc/version`, and the device tree
* the stock firmware version has to be one we have tested. Anything else is
  refused with a pointer to open an issue, because the boot partition layout
  and `S23hdmi` are what this keys off and neither is guaranteed across
  GL.iNet releases
* the boot partition has to already contain a FIT we can read
* and it asks you to type `yes` before writing (`--yes` skips it)

Then it downloads the release kernel and `scripts/patch-fit.py` and verifies
both against checksums pinned in the script, and swaps the kernel inside the
FIT already in your boot partition.

It also installs the WLAN helper into `/userdata/wlan-ap/`: the menu, the mode
switcher and a static `wpa_supplicant`. The kernel is what makes a USB WLAN
stick work, and without those files you can only run an access point with it.
That step is additive -- an existing `hostapd.conf` is never touched, and an
`ap-start.sh` that is not byte-for-byte one of ours is left alone -- and a
failure there does not affect the kernel. `--no-wlan` skips it entirely.

Nothing is written until that image exists and is checked. The FIT already in
your partition has to match its own recorded checksums before its device tree
and resource blob are reused -- a damaged partition is refused rather than
copied forward. The backup is compared against the partition it came from, and
the install aborts if it does not match, because a backup nobody verified is
not a way back. After writing, the partition is read back and compared; if that
fails the backup goes straight back in. It never reboots.

The same script rolls back, which is why it is worth keeping on the device
rather than piping it -- a rollback then needs no network:

```sh
sh install.sh --list                                   # what you can go back to
sh install.sh --revert /userdata/kernel-backup/boot-backup-....img
```

Piped straight into a shell, arguments go after `-s --`:

```sh
curl -sSL https://raw.githubusercontent.com/macpit/glkvm-rm1pe-kernel/main/install.sh | sh -s -- --list
```

The one thing no script can protect you from is losing power in the middle of
the write. It takes a couple of seconds; do it on mains or PoE you trust, not
on a device someone might unplug. A dropped SSH session is handled -- the write
ignores hangups so it finishes either way.

> **This overwrites a boot partition from a shell pipeline.** Read the script
> before you run it -- it is a few hundred lines and does nothing clever.
> `curl | sh`
> means trusting GitHub to serve you the right file; the script cannot verify
> itself, only what it downloads afterwards. If that trade is not acceptable,
> download it, read it, then run it. The safer path is still the build route
> above with a serial console attached.

The full walkthrough, including what this route cannot rescue you from, is in
[docs/device-only.md](docs/device-only.md).

Nothing proprietary is downloaded: your device tree and the Rockchip resource
blob stay in place, only the kernel payload is replaced. The way back is
printed at the end and needs no network.

`patch-fit.py` rewrites the FIT header in place rather than rebuilding it. The
fields that change are fixed width -- `data-size` and `data-position` are 32
bits, the SHA256 in each hash node is 32 bytes -- so no `mkimage`, no `dtc` and
no libfdt are needed on the device. Only `python3`, which is already there. It
also works standalone:

```sh
patch-fit.py --info /dev/block/by-name/boot     # show the layout
patch-fit.py /dev/block/by-name/boot Image out.img
```

It always writes to a separate file and never to a block device on its own.

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
install.sh  one-line installer, runs on the device itself
patches/    the four patches, in order
scripts/    build the FIT, install it, roll it back -- all over SSH
            patch-fit.py swaps the kernel inside an existing FIT, on the device
            build-wpa-supplicant.sh cross-builds the static wpa_supplicant
wlan-ap/    access point, client mode and captive portal, ready to drop into
            /userdata -- wlan-menu.py is the thing you actually run
docs/       dev-machine, device-only, build, recovery, the LT6911C driver,
            WLAN
```

## Planned

* **A tool to patch a firmware image you downloaded yourself.** Right now you
  build a kernel and install it onto a running device. Easier would be a script
  that takes an official OTA image you fetched from GL.iNet's download page,
  swaps in our kernel, and hands the file back for the normal update mechanism.
  No cross toolchain, no SSH surgery on a live system, and the way back is to
  reinstall the stock image.

  We would ship the tool, not an image. The script runs on a file that is
  already on your machine and the result stays there. The RKFW/RKAF container
  unpacks and repacks well enough already; missing are the tooling and a second
  device to test on.

* **Audio.** The sample rate is still hardcoded to 48 kHz upstream of us
  ([glkvm#136](https://github.com/gl-inet/glkvm/issues/136)); non-48 kHz sources
  come through pitch-shifted. Untouched so far.
* **The measurement bug from the forum**, where the chip reports the active
  resolution one or two pixels off. Present on stock firmware too, and not
  fixed in 1.10.x.
* **More WLAN sticks**, once someone reports what works.

## Contributing

Bug reports and patches welcome, especially from anyone with a different HDMI
source, a different WLAN stick, or an RM10. The LT6911C sits in several devices
and the driver situation is much the same on all of them.

If you have a source that shows a picture on the stock firmware but not here,
open an issue with `dmesg | grep lt6911` and the output of
`cat /sys/bus/i2c/devices/1-002b/resolution`.

## Legal

I am not a lawyer. This is how the repository is put together and why.

No GL.iNet binaries are redistributed here. The patches are written against
their published GPL sources.

The release does contain one binary we built ourselves: a static
`wpa_supplicant` 2.11 (BSD-3-Clause) linked against libnl (LGPL-2.1) and glibc.
Static linking against an LGPL library carries a relinking obligation, so
`scripts/build-wpa-supplicant.sh` is in the tree with the exact versions,
checksums and flags. Anyone can reproduce the binary or build a different one
and drop it in. Nobody has to take the shipped one. `build-fit.sh` reads the device tree and the
Rockchip resource blob off your own device instead of shipping copies, and the
planned image tool will work on a file you downloaded yourself.

Changing the firmware on hardware you own is not the same as distributing it.
Copyright covers copying and distribution. Swiss and EU law give a lawful
acquirer the right to correct errors in software they bought, and terms of use
cannot take that away.

The kernel is GPL-2.0. Section 6 forbids adding restrictions for downstream
recipients, so a vendor's terms cannot narrow the licence on the parts this
repository patches.

There is no secure boot to bypass. The boot log says `Verified-boot: 0`, the
U-Boot control FDT has no `/signature` node, and unsigned FIT images boot
normally.

Expect your warranty to be void, and do not count on vendor support for a
modified device.

Not affiliated with GL.iNet.

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
