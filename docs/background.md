# Background: status, why this exists, what is planned

## Status

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
