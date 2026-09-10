# Legal

I am not a lawyer. This is how the repository is put together and why.

No GL.iNet binaries are redistributed here. The patches are written against
their published GPL sources.

The release does contain binaries we built ourselves, from upstream sources at
pinned commits: `hostapd` and `wpa_supplicant` (BSD-3-Clause), `dnsmasq`
(GPL-2.0) and the `8188eu` driver module (GPL-2.0), the first three linked
statically against libnl (LGPL-2.1) and glibc. Static linking against an LGPL
library carries a relinking obligation, so `scripts/build-userland.sh` and
`scripts/build-8188eu.sh` are in the tree with the exact commits, versions and
flags. Anyone can rebuild them or substitute their own. Nobody has to take the
shipped ones. `build-fit.sh` reads the device tree and the
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
