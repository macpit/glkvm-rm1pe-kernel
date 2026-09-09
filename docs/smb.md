# SMB share of the ISO storage

`install-smb.sh` turns the KVM's media partition (`/userdata/media`, the
place kvmd takes ISO images from for the virtual drive) into an SMB share.
The idea: copy an ISO onto the KVM from the Finder or Explorer instead of
uploading it through the web GUI, and have the device show up in the
Finder's Network list, which only lists SMB/AFP hosts.

```sh
curl -sSLo /tmp/s.sh https://raw.githubusercontent.com/macpit/glkvm-rm1pe-kernel/main/install-smb.sh
sh /tmp/s.sh
```

Needs the custom kernel from this repository (see below for why), so run
`install.sh` first.  `sh /tmp/s.sh --uninstall` removes everything again.

## What is shared and who may do what

| share            | path             | guest      | user `admin` |
|------------------|------------------|------------|--------------|
| `media`          | `/userdata/media`| read       | read + write |

* **Guests** connect without any password.  On macOS click the device in the
  Finder's Network list, or `smb://<hostname>.local/media`.  Windows 11
  refuses guest logons to SMB shares by default (`AllowInsecureGuestAuth`);
  connect as `admin` there, or allow insecure guest logons in the group
  policy / registry.
* **`admin`** may write.  The installer creates the user with a random
  password and prints it once.  Change it any time on the device with

  ```sh
  sh /userdata/smb/set-smb-password.sh
  ```

  (prompts twice; pass the password as the first argument for a script).
  The database is `/userdata/smb/ksmbdpwd.db`, mode 600; it survives
  firmware updates because it lives in `/userdata`.

The share carries an `index.html` that `S99smb` rewrites at every start.
It links to `https://<hostname>.local/` (the name is stable, the DHCP
address is not) and to the address as of that boot as a fallback, and
redirects to the web GUI after three seconds.  Opening it from the share is
the "double-click the device, land in the GUI" experience the Finder does
not offer for plain web services.

## How it is built

The server is **ksmbd**, the SMB3 server inside the Linux kernel, not
Samba.  Samba would have to be built statically for aarch64 with its own
waf/Python build system and would weigh some 40 MB; ksmbd is a 300 kB
kernel module plus three small userspace tools.

* `ksmbd.ko`, `cifs_arc4.ko`, `cifs_md4.ko` are built from the kernel tree
  in this repository with `CONFIG_SMB_SERVER=m`, plus
  `patches/ksmbd-unknown-rpc-pipe.patch` (an unimplemented named pipe is
  answered with `OBJECT_NAME_NOT_FOUND` rather than `INVALID_PARAMETER`, the
  way Samba does it -- macOS asks for the Spotlight pipe `mdssvc` on every
  connection) -- nothing else in the
  config changes, the kernel image is untouched.  Like `8188eu.ko` they are
  bound to the kernel version through `vermagic`; `install-smb.sh` and
  `S99smb` both check that before loading.  A new kernel version means
  rebuilding the modules (`scripts/build-ksmbd.sh`).
* `ksmbd.tools` is [ksmbd-tools](https://github.com/cifsd-team/ksmbd-tools)
  3.5.2: one static multi-call binary (1.2 MB, musl) that behaves as
  `ksmbd.mountd`, `ksmbd.adduser` or `ksmbd.control` depending on the name
  it is called by -- the installer creates those symlinks.  Built with
  Buildroot (`scripts/build-ksmbd.sh`), because it pulls glib2 and libnl in
  and a hand build of static glib2 is not worth anyone's evening.

Everything lives in `/userdata/smb/`.  `/etc/init.d/S99smb` loads the
modules, generates `/var/run/ksmbd.conf` from the hostname, writes the
`index.html`, starts `ksmbd.mountd` and registers `_smb._tcp` and
`_device-info._tcp` over mDNS with the vendor's `dns-sd`, so the Finder
lists the device.  The boot call is planted into a firmware init script for
the reason explained in `install-discovery.sh`.

The exFAT partition is mounted with `fmask=0022`, everything on it is owned
by root.  The share therefore uses `force user = root`; the SMB user
`admin` is only a name in ksmbd's own database and needs no system account.

## The AFP record that has to go (macOS Finder)

Every GL KVM runs a second mDNS daemon whose only job is to publish
`<hostname>.local`:

```
mDNSResponder -b -n <hostname> -P /var/run/mDNSResponder-system.pid
```

That binary is Apple's `mDNSResponderPosix`, and its own usage text gives the
game away:

```
-t uses 'type' as the service type (default is '_afpovertcp._tcp.')
```

With no `-t`, it advertises an **AFP server on port 548 that does not exist**.
The Finder prefers AFP over SMB for a host offering both, connects to 548,
gets nothing, and reports "Connection Failed" -- without ever trying port 445.
Nothing reaches ksmbd, so its log stays empty during every failed attempt,
while `mount_smbfs`, `smbutil` and `smbclient`, which speak SMB directly, work
perfectly.  That combination is what makes this so confusing to debug: the
server is healthy and the client is healthy, but the Finder never introduces
them.

`S99smb` therefore restarts that instance with an explicit
`-t _smb._tcp -p 445`.  The hostname keeps resolving, the bogus AFP record is
replaced by the share we actually serve, and `S99smb stop` puts the firmware's
original invocation back.  The firmware starts it again with the AFP default
on every boot, which is why this lives in `start` rather than in the installer.

Do **not** advertise `_device-info._tcp` with a `model=` hint alongside: it
makes the Finder classify the box as a Mac, which is another way to end up on
the AFP path.

To check from a Mac -- the KVMs must appear under `_smb._tcp` and *not* under
`_afpovertcp._tcp`:

```sh
dns-sd -B _smb._tcp
dns-sd -B _afpovertcp._tcp
```

## Windows: "Computer" vs "Other Devices"

Two different discovery protocols feed the Explorer's network view, and they
land in different sections:

* **Other Devices** comes from the SSDP responder of `install-discovery.sh`.
  Its payload is a `presentationURL`, so a click there opens the web GUI.
  That is all SSDP can do -- it says nothing about file shares.
* **Computer** comes from **WSD** (Web Services Discovery, UDP 3702 /
  TCP 5357).  Windows only lists SMB hosts there, and only if they answer WSD
  probes.  NetBIOS browsing, the old alternative, is off by default on
  Windows 11.

`S99smb` therefore also runs [wsdd](https://github.com/christgau/wsdd) 0.9
(`smb/wsdd.py`, a single dependency-free Python file, MIT).  The KVM then
appears under Computer and a double-click opens the share.  wsdd is optional:
if the file is missing, everything else still works and the device is still
reachable as `\\<hostname>.local\media`.

Windows 11 refuses guest logons to SMB out of the box.  Either connect as
`admin`, or allow them:

```
reg add "HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" ^
    /v AllowInsecureGuestAuth /t REG_DWORD /d 1 /f
```

## Keeping index.html current

The page in the share links to `https://<hostname>.local/`, which never
changes, and shows the current address underneath as a fallback -- and that
one does change with a new DHCP lease.

`S99smb` starts a small watcher (`/userdata/smb/.smb-ipwatch`) that follows
`ip monitor address` and regenerates the page whenever the interface's
address list changes; it degrades to a 60-second poll if `ip monitor` is
unavailable.  The DHCP client on these devices is `connmand`, which has no
dispatcher scripts, and the `udhcpc` hook directories in the firmware are
unused -- watching the kernel's own events avoids depending on either.

## Caveat: kvmd's virtual-drive mode

kvmd has two mass-storage functions on the USB gadget.  One serves a single
ISO read-only.  The other hands the **whole media partition** to the
target PC read-write ("virtual drive" in the GUI): kvmd `umount`s
`/userdata/media` for that and exports `/dev/mmcblk0p10` raw, and formats
it on request.

A connected SMB client keeps that mount busy and the umount fails.  So:
disconnect SMB clients (or `S99smb stop`) before switching the GUI to
virtual-drive mode, and expect the share to be empty while the partition is
exported.  Uploading an ISO over SMB and mounting it as a CD image is
unaffected -- that path never umounts.

## Checking

```sh
/etc/init.d/S99smb status
tail /var/log/smb.log
dns-sd -B _smb._tcp                 # on a Mac: the KVM should be listed
smbclient -N -L //<hostname>.local  # Linux, guest listing
```
