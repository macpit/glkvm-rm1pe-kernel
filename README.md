# glkvm-rm1pe-kernel

A self-built kernel for the **GL.iNet Comet KVMs** (GL-RM1PE and GL-RM1 V2)
that does what the stock one does, plus the things it does not: a working USB
WLAN access point, an HDMI capture path that survives a cold start, an SMB
share for ISO images, and devices that show up in the macOS Finder and the
Windows network view.

Everything is built from public sources: GL.iNet's
[kernel-6.1](https://github.com/gl-inet/kernel-6.1), the upstream stable
patches, and the changes in `patches/`. No vendor binaries are redistributed.

If this saves you an evening, a star helps others find it.

## Tested devices

| Device | Model IDs | Board | eMMC | Stock firmware | Since |
| --- | --- | --- | --- | --- | --- |
| GL.iNet [**GL-RM1PE**](https://www.gl-inet.com/en-de/products/gl-rm1pe) (Comet PoE) | `rm1pe` / `RM1PE` | Rockchip RV1126B-P | 64 GB | V1.9.1 release1 | v23 |
| GL.iNet [**GL-RM1 V2**](https://www.gl-inet.com/en-de/products/gl-rm1) (Comet) | `rm1v2` / `RM1V2` | Rockchip RV1126B-P | 8 GB | V1.9.1 release1 | v32 |

Both share the vendor kernel 6.1.141, the device tree
`Rockchip RV1126B-P EVB V14 Board`, the LT6911C HDMI bridge (chip firmware
49.25.3.3.1) and the partition layout; the V2 only has a smaller eMMC and its
own DTB, which the installer keeps. Sources tested: 2560x1440@60,
3840x2160@30, 1920x1080@60, 1920x1280@60. WLAN stick: Realtek RTL8188EU
(`0bda:8179`).

`install.sh` **refuses to run on anything else**, and on any other firmware
version. If yours is newer, that is not a bug report about your device --
open an issue with `cat /etc/version` and it gets added once it has been
checked. Three units so far, one of them factory-fresh, days of uptime rather
than weeks.

## Features

| Feature | What you get | Details |
| --- | --- | --- |
| HDMI capture | 2560x1440@60, 4K30, 1080p and whatever else the chip accepts; picture ~90 ms after probe, also from a cold start | [docs/lt6911c.md](docs/lt6911c.md) |
| USB WLAN | RTL8188EU driver, station and access point | [docs/wlan-ap.md](docs/wlan-ap.md) |
| Access point | hostapd + dnsmasq + captive portal that shows the KVM address | [docs/wlan-ap.md](docs/wlan-ap.md) |
| Client mode | Join an existing WLAN; a menu to switch, a watchdog that brings the AP back | [docs/wlan-ap.md](docs/wlan-ap.md) |
| Menu | `wlan-menu.py`: WLAN mode, hostname, AP credentials, SMB password | [docs/wlan-ap.md](docs/wlan-ap.md) |
| Discovery | `<hostname>.local`, listed under *Other Devices* in the Windows network view (SSDP) | [docs/discovery.md](docs/discovery.md) |
| SMB share | `\\<hostname>\media` (the ISO storage): guests read, `admin` writes; listed by the macOS Finder and under *Computer* in the Windows Explorer (WSD + LLMNR) | [docs/smb.md](docs/smb.md) |
| Hostname changes | Picked up by SMB, mDNS, SSDP and WSD within ~15 s, no reboot | [docs/smb.md](docs/smb.md) |
| Kernel fixes | IGMP (`CONFIG_IP_MULTICAST`, missing in the vendor config) so multicast discovery survives IGMP-snooping switches | [docs/build.md](docs/build.md) |
| Vendor modules | All six load: `kmpp`, `kmpp_smart`, `rockit*`, `gl-hw-info` | |
| Streaming | Unchanged: kvmd, ustreamer, WebRTC over the vendor pipeline | |
| Safe install | Model and firmware check, verified backup of the boot partition, verified write, rollback with `--revert` | [docs/install.md](docs/install.md) |

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

## Install

On the KVM itself, nothing else needed:

```sh
curl -sSL https://raw.githubusercontent.com/macpit/glkvm-rm1pe-kernel/main/install.sh | sh
```

It checks the model and firmware, backs up and verifies the boot partition,
swaps the kernel inside the FIT that is already there, and installs the WLAN
helper, discovery and the SMB share (`--no-wlan`, `--no-smb` skip them). It
never reboots: power-cycle the device yourself, cold, because only a cold
start exercises the HDMI bridge.

To go back:

```sh
sh install.sh --list
sh install.sh --revert /userdata/kernel-backup/boot-backup-....img
```

> This overwrites a boot partition from a shell pipeline. Read the script
> first -- it is a few hundred lines and does nothing clever. Details, what it
> verifies and what it cannot rescue you from: [docs/install.md](docs/install.md)
> and [docs/device-only.md](docs/device-only.md).

## Build your own

Needs a Debian 12 box with an aarch64 cross toolchain --
[docs/dev-machine.md](docs/dev-machine.md) -- and the kernel build itself is in
[docs/build.md](docs/build.md), including the one step that is not optional
and the one hazard that is not recoverable.

## Documentation

| | |
| --- | --- |
| [docs/install.md](docs/install.md) | The installer: what it checks, verifies, and how to roll back |
| [docs/device-only.md](docs/device-only.md) | Doing everything from the KVM's own shell |
| [docs/dev-machine.md](docs/dev-machine.md) | Setting up a build machine |
| [docs/build.md](docs/build.md) | Building the kernel: 6.1.141, the missing defconfig options, the FIT |
| [docs/recovery.md](docs/recovery.md) | When it does not boot: what works (serial) and what does not (everything the vendor documents) |
| [docs/lt6911c.md](docs/lt6911c.md) | The HDMI bridge driver and the cold-start fix |
| [docs/wlan-ap.md](docs/wlan-ap.md) | WLAN: driver, access point, client mode, captive portal, menu |
| [docs/discovery.md](docs/discovery.md) | mDNS, Bonjour and SSDP: how the Finder and the Explorer find the device |
| [docs/smb.md](docs/smb.md) | The SMB share, ksmbd, and the Windows 11 24H2 guest-access situation |
| [docs/background.md](docs/background.md) | Status, why the stock source tree is not enough, what is planned, contributing |
| [docs/legal.md](docs/legal.md) | What is redistributed, what is not, and why this is allowed |

## Layout

```
install.sh            one-line installer, runs on the device itself
install-discovery.sh  standalone: SSDP + Bonjour for any GL KVM, no kernel needed
install-smb.sh        the SMB share; needs this kernel, install.sh runs it too
set-smb-password.sh   sets the password of the SMB user "admin", on the device
patches/              the kernel patches, in order
scripts/              build the FIT, install it, roll it back; patch-fit.py;
                      build-userland.sh, build-8188eu.sh, build-ksmbd.sh
wlan-ap/              access point, client mode, captive portal, wlan-menu.py
discovery/            the SSDP responder and its init script
smb/                  ksmbd init script, wsdd, llmnrd
docs/                 see above
```

## License

GPL-2.0. The driver changes are derived from Linux and the Rockchip BSP and are
GPL-2.0 by descent; the scripts and the portal are ours and released under the
same license so the whole tree stays under one set of terms. The legal
reasoning -- what is redistributed and what is not -- is in
[docs/legal.md](docs/legal.md). Not affiliated with GL.iNet.

## Credits

Built on GL.iNet's and Rockchip's published trees. The audio sample-rate
analysis in [glkvm#136](https://github.com/gl-inet/glkvm/issues/136) by
@tokoroten and the ZHAW
[LT6911UXC driver](https://github.com/InES-HPMM/Lontium_lt6911uxc) were useful
references for the chip family. wsdd by
[@christgau](https://github.com/christgau/wsdd) (MIT).
