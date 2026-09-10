# Installing the release kernel

**Just run the kernel.** Everything happens in a shell on the KVM: no build
machine, no toolchain, no SSH from anywhere else. Install and roll back are both
covered in [docs/device-only.md](docs/device-only.md), and the short version is
the [one-liner](#the-one-liner) below.

**Change the kernel.** Then you need a build machine.
[docs/dev-machine.md](docs/dev-machine.md) lists exactly what to install on a
Debian 12 box, and the quick start below is the build itself.

## The one-liner

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

It also installs everything the WLAN needs: the `8188eu` driver module,
`hostapd`, `dnsmasq`, `wpa_supplicant`, the menu, the captive portal and the
autostart hook. The kernel alone only gets the stick enumerated -- without the
driver there is no `wlan0` at all.

That step is additive. An existing `hostapd.conf` is never touched; on a fresh
device the SSID is derived from the hostname and the passphrase is generated
and printed, because an access point whose key is in a public repository is not
an access point with a key. An `ap-start.sh` that is not byte-for-byte one of
ours is left alone. The nginx change -- two server blocks for the captive
portal -- is backed up, tested, and reverted if nginx does not accept it.
Nothing in this step can reach the boot partition, so a failure there leaves
the kernel install intact. `--no-wlan` skips all of it.

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
