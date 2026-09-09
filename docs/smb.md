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
  in this repository with `CONFIG_SMB_SERVER=m` -- nothing else in the
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
