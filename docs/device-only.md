# Doing everything from the KVM itself

You do not need a build machine, a cross toolchain or SSH from another computer
to run this kernel. Installing and rolling back both work from a shell on the
KVM. This page is that route, start to finish.

What you cannot do here is **build**. The device has 986 MB of RAM, a ~1 GB
writable overlay and no compiler (`make` exists, `gcc` does not). The kernel
comes prebuilt from the release; if you want to change it, you need
[dev-machine.md](dev-machine.md).

## Get a shell

SSH in as `root`. On stock firmware the password is `admin`:

```sh
ssh root@<device-ip>
```

The IP is the one the KVM's web interface is on.

## Fetch the installer once, and keep it

```sh
cd /userdata
curl -sSLo install.sh https://raw.githubusercontent.com/macpit/glkvm-rm1pe-kernel/main/install.sh
less install.sh          # a few hundred lines, and it overwrites a boot partition
```

Keeping the file rather than piping it matters: **rolling back later then needs
no network**, which is exactly the situation you are in if something went wrong.

## Install

```sh
sh install.sh
```

It refuses to do anything unless all of this holds:

| Check | Why |
| --- | --- |
| `gl-hw-info`, `RK_MODEL` and the device tree all say RM1PE | one source being right by accident is not the same as being on the right board |
| stock firmware is a version we have tested | the FIT layout and `S23hdmi` are what this keys off, and GL.iNet does not promise those stay put |
| the boot partition already holds a readable FIT | otherwise there is nothing to patch |
| you type `yes` | `--yes` skips it |

A kernel for the wrong board does not boot, and on this hardware that costs you
a serial console and a soldering iron. Hence the paranoia.

If your firmware is not on the tested list the script says so and asks you to
open an issue with the output of `cat /etc/version`. That is not a brush-off --
it is usually a quick answer, and it is how the list grows.

Then it downloads the release kernel and `patch-fit.py`, verifies both against
checksums pinned in the script, swaps the kernel inside the FIT already in your
boot partition, backs that partition up, writes, and reads back to compare. If
the read-back disagrees it puts the backup straight back. It never reboots.

Your device tree and the Rockchip resource blob are not touched -- only the
kernel payload inside the FIT is replaced. Nothing proprietary is downloaded.

Then **pull the power**. Do not reboot warm: only a cold start takes the HDMI
bridge through the reset sequence that this kernel depends on.

## Roll back

```sh
sh install.sh --list
sh install.sh --revert /userdata/kernel-backup/boot-backup-<stamp>.img
```

`--list` shows every image in `/userdata/kernel-backup`, newest first, with
sizes. `--revert` refuses anything that is larger than the partition or does not
start with the FIT magic, writes it, and verifies by reading back.

If you no longer have the script, the same thing by hand:

```sh
cat /userdata/kernel-backup/boot-backup-<stamp>.img > /dev/block/by-name/boot
sync
```

Then pull the power again.

## Disk space

Each backup is a full copy of the 32 MiB boot partition, and `/userdata` is
about 1 GB shared with everything else you keep there. The installer refuses to
start below 80 MB free. Old backups are just files -- delete the ones you no
longer want.

## What this route cannot rescue

Everything above needs a device that still boots far enough to give you a shell.
If it does not, no amount of `/userdata` gets you back in: you need a serial
console and U-Boot, which on the RM1PE means opening the case and soldering to
the RX pad. That is [recovery.md](recovery.md).

This is the honest trade of the device-only route. It is genuinely simpler, and
it is one bad flash away from needing a soldering iron. The installer verifies
what it writes before and after precisely because that is the only line of
defence it has.
