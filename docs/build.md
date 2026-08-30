# Building

## Why 6.1.141 and not 6.1.118

The published tree is 6.1.118. The device ships 6.1.141, and the six vendor
modules (`kmpp`, `kmpp_smart`, `rockit`, `rockit_base`, `rockit_osal`,
`gl-hw-info`) are binaries with a vermagic of `6.1.141 SMP mod_unload aarch64`.
Load them into a 6.1.118 kernel and they are rejected. Without them there is no
encoder, and without the encoder there is no stream.

So the tree has to be brought to 6.1.141 first, with the upstream incremental
patches from kernel.org:

```sh
cd kernel
for v in $(seq 119 141); do
    curl -sO "https://cdn.kernel.org/pub/linux/kernel/v6.x/incr/patch-6.1.$((v-1))-$v.xz"
    xz -d "patch-6.1.$((v-1))-$v.xz"
    patch -p1 -F0 < "patch-6.1.$((v-1))-$v" || echo "rejects in 6.1.$v"
done
```

**Use `-F0`.** With the default fuzz one hunk lands in the wrong place in
`rockchip_i2s_tdm.c` and produces a duplicate function definition that only
shows up much later, as a confusing compiler error.

This leaves 24 rejects in 20 files, because the vendor tree has diverged from
upstream in those places. `patches/0001` is our resolution of all of them:
nine hunks applied by hand, five already present in the vendor code, five not
applicable. `patches/0002` fixes what only the compiler finds afterwards, where
the stable series added calls whose definitions were in a reject.

## Vermagic

`setlocalversion` appends a `+` inside a git tree, which makes the release
`6.1.141+` and breaks the vermagic comparison. Prevent it with an empty file:

```sh
touch .scmversion
```

## The three missing defconfig options

`patches/0003` adds them. What each one does:

| Option | Missing symptom |
| --- | --- |
| `CONFIG_ROCKCHIP_DVBM` | `kmpp.ko` fails to load and takes `kmpp_smart`, `rockit_base` and `rockit` with it |
| `CONFIG_HWSPINLOCK` + `CONFIG_HWSPINLOCK_ROCKCHIP` | Asynchronous SError panic at ~25 s |
| `CONFIG_VIDEO_LT6911C` | No HDMI input. The defconfig enables `LT6911UXC`, which is a different chip |

The panic is worth understanding, because the trace points somewhere else
entirely. The OTP node references `hwlocks = <&hwspinlock 0>`. With no
hwspinlock driver, `fw_devlink` silently holds OTP back as a consumer of a
supplier that never probes. Every OTP nvmem read then fails, which stalls
cpuinfo, pvtpll, dmc and npu in the deferred-probe chain. At the deferred-probe
timeout the queue is forced through, `pvtpll` writes into a block that was
never initialised, and the CPU takes an SError inside `rv1103b_pvtpll_configs`.
Nothing in that backtrace mentions hwspinlock.

The same patch also enables the wireless stack and the staging driver for the
RTL8188EU. See [wlan-ap.md](wlan-ap.md) if you use a different stick.

## Build

```sh
make ARCH=arm64 O=../build rv1126bp_gl_rm1_poe_defconfig
make ARCH=arm64 O=../build olddefconfig
make ARCH=arm64 O=../build CROSS_COMPILE="aarch64-linux-gnu-" -j"$(nproc)" \
     Image modules rockchip/rv1126bp-evb-v14.dtb
```

Do not skip `olddefconfig`: without it `ARM64_TLB_RANGE` and
`SHADOW_CALL_STACK` quietly take their defaults. Do not skip `modules` either,
or `Module.symvers` stays empty and the symbol check below cannot work.

Debian's `aarch64-linux-gnu-gcc` 12.2 is fine. The vendor used ARM GNU 10.3, and
the difference has caused no trouble so far.

## Check the symbols before you flash

The vendor modules resolve 642 kernel symbols at load time and there is no CRC
check to warn you: a missing symbol simply fails at runtime. Two minutes of
checking beats a bricked boot.

Copy `/usr/lib/module/*.ko` and `/usr/lib/modules/6.1.141/gl-hw-info.ko` off the
device, then:

```sh
MODS="kmpp.ko kmpp_smart.ko rockit.ko rockit_base.ko rockit_osal.ko gl-hw-info.ko"
for f in $MODS; do aarch64-linux-gnu-nm --defined-only $f | awk '{print $3}'; done \
    | sort -u > exports.txt
for f in $MODS; do aarch64-linux-gnu-nm -u $f | awk '{print $2}'; done \
    | sort -u > undefined.txt
awk '{print $2}' ../build/Module.symvers | sort -u > symbols.txt
comm -23 undefined.txt exports.txt | comm -23 - symbols.txt
```

The output must be empty.

Note what this does **not** catch: it only checks symbols the vendor modules
need. A missing platform driver such as hwspinlock or the LT6911C passes this
check and fails later, on the device.

## The boot image

The boot partition holds a FIT with external payloads: a 1536-byte header, then
the device tree, kernel and resource blob referenced by `data-position` and
`data-size`. The `boot.its` in the vendor tree describes *embedded* data; build
it literally and U-Boot rejects the result with `FIT: No fit blob`.

`scripts/build-fit.sh` does it correctly (`mkimage -E -p 0x800 -B 0x200`) and
verifies afterwards that the payloads really ended up external. It also takes
the device tree and the resource blob from your own device rather than shipping
someone else's.

Signature verification does not happen on this device: the header carries
`sha256,rsa2048:dev`, but the boot log says `Verified-boot: 0`, the U-Boot
control FDT has no `/signature` node, and the binary contains the
"requires CONFIG_FIT_SIGNATURE" error path. Unsigned FITs with correct hashes
boot fine.
