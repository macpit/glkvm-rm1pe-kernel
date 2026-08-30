# WLAN access point

The RM1PE has a USB port and no wireless of its own. With the kernel from this
repository and a supported stick it can run as an access point, so you can
reach the KVM without touching the network it is plugged into. Useful when the
machine you are rescuing *is* the router.

## The stick we use

**Realtek RTL8188EU**, USB ID `0bda:8179`. Cheap, tiny, and it enumerates on the
built-in EHCI without a powered hub.

Two things to know about it:

* The in-kernel staging driver `r8188eu` is a **WEXT** driver. `iw` and
  everything else built on nl80211 will not talk to it; use `iwconfig` and
  `iwlist`, and `wpa_supplicant -D wext`. It also no longer has a usable AP
  interface, since `RTL_IOCTL_HOSTAPD` was removed.
* For access-point mode we therefore use the out-of-tree
  [aircrack-ng/rtl8188eus](https://github.com/aircrack-ng/rtl8188eus) driver,
  which registers through cfg80211 and works with hostapd.
* Firmware `rtlwifi/rtl8188eufw.bin` is not on the device. Take it from
  linux-firmware and put it in the overlay under `/lib/firmware/rtlwifi/`.

Module load order matters: `lib80211`, `lib80211_crypt_wep`,
`lib80211_crypt_ccmp`, then the driver.

## Using a different stick

Nothing here is specific to Realtek beyond the driver choice. To add another
chipset:

1. Enable its driver in the defconfig, built in or as a module. `patches/0003`
   already enables `CONFIG_ATH9K_HTC` and `CONFIG_MT7601U` next to the Realtek
   staging driver, so an Atheros AR9271 or a MediaTek MT7601U stick should come
   up without a rebuild.
2. Put any firmware it needs into `/lib/firmware/` in the overlay.
3. If you build it as an out-of-tree module, mind the vermagic: it must be
   `6.1.141 SMP mod_unload aarch64` exactly, and every kernel symbol it uses has
   to be exported. See the symbol check in [build.md](build.md).
4. Check whether the driver speaks nl80211 or only WEXT before you plan on AP
   mode.

Reports about other chipsets are welcome — open an issue and say what worked.

## Access point

Files in `wlan-ap/`, meant to be copied to `/userdata/wlan-ap/` on the device.
`hostapd` and `dnsmasq` are static builds we keep next to them; the RM1PE
rootfs ships neither.

```
ap-start.sh        loads the driver, brings up wlan0, starts everything
hostapd.conf.example   copy to hostapd.conf and set your own SSID and passphrase
dnsmasq.conf       DHCP, wildcard DNS, captive-portal options
captive.py         the state service behind the portal
portal/index.html  the page itself
nginx-ap-block.conf    the two server blocks to add to nginx
restart-cap.sh     restart the state service
```

The AP lives on `192.192.193.1/24` and hands out `.100` to `.150`.

### Autostart, and a trap worth knowing

`/etc/init.d/rcS` expands its `for i in /etc/init.d/S??*` glob **once, at
start** — which is before `S08overlayfs` does its `pivot_root`. A script that
exists only in the overlay is invisible at that moment and is never started.
`rcK` re-globs at shutdown, when the overlay is active, so such a script gets
`stop` calls and never a `start`, which is a confusing thing to debug.

The fix is to hook into a script that exists in the lower filesystem. We call
`ap-start.sh` from the `start)` branch of `/etc/init.d/S99zerotier`, whose
contents are read from the overlay at execution time.

**Overlay-only init scripts never start on their own on this device.** Anything
you add needs the same treatment.

## Captive portal

The point is modest: when you join the network, the address of the KVM appears
on its own, so you do not have to remember `192.192.193.1`.

How it fits together:

```
client joins
  -> dnsmasq: DHCP with router and DNS, wildcard DNS resolves every name to us
  -> the OS probes captive.apple.com (or gstatic, msftconnecttest, ...)
  -> nginx matches those hostnames and proxies to captive.py
  -> unknown client   -> 302 to /portal/?cna=1
     released client  -> the success answer that OS expects
  -> the portal shows the address and a copy button
```

`captive.py` keeps released clients in memory only, with a six-hour expiry, so
a rebooted AP shows the portal again and a recycled DHCP lease does not inherit
someone else's release.

nginx needs the two server blocks from `nginx-ap-block.conf` added to
`/etc/kvmd/nginx-kvmd.conf`. They bind `listen 192.192.193.1:80`, which is more
specific than the existing `listen 80` and therefore only affects clients on
the AP. Over Ethernet everything stays as it was, including the redirect to
HTTPS.

That file is static: the init script starts nginx with `-c` on it and never
regenerates it from the Mako template, so edits survive reboots. Back it up
before you touch it anyway.

### Plain HTTP on the AP, on purpose

The block for AP clients serves the KVM interface over plain HTTP. The device's
certificate is self-signed (`CN=localhost`), and a certificate warning inside
the captive-portal browser is a dead end for most people. The air link is
WPA2-encrypted and Ethernet keeps its HTTPS redirect. If you would rather not,
drop the second server block and accept the warning.

### What macOS will and will not do

Worth writing down, because it cost us an afternoon:

* You **cannot** open a real browser from the captive window. `window.open` and
  `target="_blank"` stay inside it. Foreign URL schemes are handed to
  LaunchServices, so any app with its own scheme can be launched — but
  `x-safari-http://` is blocked from there, at least on current macOS.
* The **user agent is not a reliable signal**. The system prober identifies as
  `CaptiveNetworkSupport-...`, but the web view inside the same window sends an
  ordinary Safari string. That is why `captive.py` marks the redirect with
  `?cna=1` and the page keys off that instead.
* The window **will not close on command**. Neither the release nor navigating
  to `captive.apple.com/hotspot-detect.html` (which then visibly says
  "Success") convinces macOS to dismiss it. The page therefore says plainly
  that the window can be closed.
* Once a network has been logged into successfully, macOS **stops showing the
  assistant** on later joins, whatever the server answers. To test the first-
  contact experience again you have to forget the network.

The result on a Mac: join, the window appears with the address, one click
copies it and marks you released, close the window, paste in a browser. Later
joins are silent. On iOS and Android the same flow works, with the usual
"use without internet" prompt.
