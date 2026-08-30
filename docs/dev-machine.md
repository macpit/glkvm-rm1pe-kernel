# Setting up a build machine

Everything here was built on a plain **Debian 12** container: 6 cores, 8 GB RAM,
98 GB disk. Nothing about that is special. A VM, a container or a spare laptop
all work; 4 GB RAM and 30 GB of free disk are enough. The build takes about
seven minutes on six cores.

You do **not** need a build machine to install a prebuilt kernel. That runs on
the KVM itself -- see [device-only.md](device-only.md). This page is for
changing the kernel.

## Packages

```sh
sudo apt-get update
sudo apt-get install -y \
    build-essential git bc bison flex libssl-dev rsync unzip ccache \
    device-tree-compiler libncurses-dev python3-dev cpio file wget \
    libelf-dev kmod u-boot-tools pkg-config curl xz-utils
sudo apt-get install -y gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
```

What the less obvious ones are for:

| Package | Why |
| --- | --- |
| `u-boot-tools` | `mkimage`, which packs the FIT that goes into the boot partition |
| `device-tree-compiler` | `fdtget`, used by `build-fit.sh` to read the FIT layout |
| `libelf-dev`, `libssl-dev` | kernel build dependencies, missing them fails late and confusingly |
| `bison`, `flex` | kconfig and the device-tree parser |
| `cpio`, `kmod`, `bc`, `rsync` | used by the kernel build itself |
| `ccache` | optional, but a rebuild drops from minutes to seconds |
| `gcc-aarch64-linux-gnu` | the cross compiler; Debian 12 ships 12.2.0 |

Optional, only for specific jobs:

```sh
sudo apt-get install -y squashfs-tools    # unpacking vendor firmware images
sudo apt-get install -y sshpass           # only if you refuse to use SSH keys
```

## SSH to the device

`build-fit.sh`, `install-kernel.sh` and `revert-kernel.sh` all reach the KVM over
SSH and assume key-based login. Set that up once:

```sh
ssh-copy-id root@<device-ip>          # default password is 'admin'
ssh root@<device-ip> 'cat /proc/gl-hw-info/model'    # should print rm1pe
```

Without a key, every step stops to ask for the dropbear password.

## ccache

Worth configuring if you expect to build more than once:

```sh
ccache --max-size=20G
ccache --set-config=compiler_check=content
```

`compiler_check=content` matters here: the default checks the compiler's mtime,
which changes on a package upgrade even when the binary does not, throwing away
the whole cache for no reason.

## Toolchain notes

The vendor firmware was built with **ARM GNU Toolchain 10.3-2021.07**; we build
with Debian's **12.2.0**. That difference has caused no problems across every
version in this repository. The modules the vendor ships have
`CONFIG_MODVERSIONS` off, so only the vermagic string and the exported symbols
have to line up -- not CRCs.

One trap: in a git tree, `setlocalversion` appends a `+` to the release string,
`kernel.release` becomes `6.1.141+`, and the vendor modules then refuse to load
because vermagic no longer matches. Fix it with an empty `.scmversion` in the
source root, as the build instructions do.

## Disk

| | |
| --- | --- |
| kernel source tree | ~1.9 GB |
| out-of-tree build directory | ~1.6 GB |
| ccache | up to whatever you set, 1 GB after a few builds |

## Versions this was built and tested with

```
Debian            12.15
gcc               aarch64-linux-gnu-gcc (Debian 12.2.0-14) 12.2.0
mkimage           2023.01
dtc               1.6.1
python3           3.11.2 (build machine) / 3.12.5 (device)
```

Nothing depends on these exact versions. They are recorded so that if a build
misbehaves, you can tell whether you are somewhere we have been.

## Next

[build.md](build.md) for bringing the tree to 6.1.141 and building it.
