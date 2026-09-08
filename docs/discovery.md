# Finding the device on the network

With DHCP, the annoying part of owning several of these is not operating them,
it is finding them. This page covers the three mechanisms that make that
unnecessary.

## mDNS -- already there, nothing to do

GL.iNet ships Apple's mDNSResponder on the device, so every KVM already
announces itself as `_glinet._tcp` on port 443 and answers to its hostname
under `.local`. Open `https://<hostname>.local/` instead of an IP and the
address stops mattering.

To see what is on your wire (`dns-sd` is preinstalled on macOS; on Linux use
`avahi-browse -rt _glinet._tcp`):

```sh
dns-sd -B _glinet._tcp            # a live list of devices
dns-sd -Z _glinet._tcp local      # a dump with hostnames, ports and TXT
```

The `.local` name follows the hostname, which the WLAN menu changes under
option 4. Give the devices names you will still recognise in six months --
three boxes called `glkvm` are no better than three IP addresses.

The instance name (`GL-RM1PE-c80`) is a different thing: it comes from
`/etc/mDNSResponder.conf`, is derived from the MAC, and the GL mobile app very
likely finds devices by it. Leave that one alone.

## Bonjour / macOS Finder

The mDNS name alone is enough to reach the device by URL, but the Finder
sidebar under "Network" only shows services it recognises.  `_glinet._tcp` is
GL's proprietary type, so the Finder ignores it.

`S99discovery` therefore also registers `_http._tcp` via the on-device `dns-sd`
tool.  This makes the KVM show up in the Finder (and in any Bonjour browser) as
a web service.  A double-click opens Safari at `https://<hostname>.local/`.

The TXT record carries `path=/` and `model=RM1PE` (read from `/etc/version`).
The registration is a single background `dns-sd -R` process managed alongside
`ssdp.py` by the same init script.

To check from a Mac:

```sh
dns-sd -B _http._tcp              # live list -- the KVM should appear
```

## SSDP -- what Windows actually uses

Explorer's "Network -> Other devices" list is not built from mDNS. It is fed by
SSDP/UPnP, through the SSDP Discovery and Function Discovery Provider Host
services. A device can therefore be perfectly visible to every Bonjour browser
and still be missing from Explorer, which is exactly what happened here: a
Synology NAS on the same wire showed up, the KVMs did not.

`discovery/ssdp.py` closes that gap. It answers `M-SEARCH`, sends the periodic
alive notifications, and serves a minimal UPnP device description on port 1901.
Windows shows the device under its hostname and model, and a double-click opens
`presentationURL` -- the KVM web interface.

### Installing it on its own

This part has nothing to do with the custom kernel, so it is installed
separately and works on any GL KVM with Python 3 -- an RM1, an RM1 v2, a device
on stock firmware you have no intention of reflashing. On the device:

```sh
curl -sSLo /tmp/d.sh https://raw.githubusercontent.com/macpit/glkvm-rm1pe-kernel/main/install-discovery.sh
sh /tmp/d.sh
```

It writes `/userdata/discovery/ssdp.py` and `/etc/init.d/S99discovery`, adds one
line to a firmware init script so it survives a reboot, and starts it. Nothing
else is touched: no kernel, no boot partition, no firmware binary.

To remove it again, including the planted line:

```sh
sh /tmp/d.sh --uninstall
```

`install.sh` from this repository runs the same script as its last step, so a
kernel install gets it too. There is one implementation, not two.

A firmware update replaces the init script that carries the boot call, so the
service will stop coming up on its own. Running the installer again puts the
line back.

Notes worth having:

* **The UDN is derived from the MAC**, not random. A restart therefore reuses
  the same identity instead of leaving a second phantom entry behind in
  Explorer.
* **Model and version come from `/etc/version`**, the same file the vendor mDNS
  record uses. Reading the version from anywhere else gets you a number that
  disagrees with every other tool on the network.
* **The description is served over plain HTTP** on port 1901, while
  `presentationURL` points at port 80, which redirects to HTTPS. Windows fetches
  the description itself and would have to be taught to trust a self-signed
  certificate to do that over TLS; the browser, which handles the redirect, is
  already equipped for it.
* **No dependencies.** Plain sockets and `http.server`, because the device has
  no package manager.

## Checking it yourself

Ask the network directly, without any tooling:

```sh
python3 - <<'PY'
import socket, time
msg = "\r\n".join(['M-SEARCH * HTTP/1.1', 'HOST: 239.255.255.250:1900',
                   'MAN: "ssdp:discover"', 'MX: 2', 'ST: ssdp:all', '', '']).encode()
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
s.settimeout(4)
s.sendto(msg, ("239.255.255.250", 1900))
t = time.time()
while time.time() - t < 4:
    try:
        data, addr = s.recvfrom(65507)
    except socket.timeout:
        break
    for line in data.decode("latin-1").split("\r\n"):
        if line.upper().startswith("LOCATION"):
            print(addr[0], line)
PY
```

## Where both stop

Neither is a scan. Both show you what announces itself, and nothing else -- a
printer, a switch or a camera that stays quiet remains invisible. `nmap -sn`
tells you what is there; these tell you what it is and what it is called.

Both are also link-local. The packets do not cross a router, so a Mac or PC in
a different VLAN sees nothing until the gateway reflects mDNS and SSDP. In
UniFi that is a per-network setting.

And both are unauthenticated and readable by anyone on the segment: hostnames,
models, firmware versions, serial numbers. Harmless on a home LAN, worth a
thought before you put a device on a guest network.
