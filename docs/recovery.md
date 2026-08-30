# Recovery

Three ways back, in order of how much has gone wrong.

## 1. The device still boots: revert over SSH

```sh
scripts/revert-kernel.sh <device-ip>                    # list backups
scripts/revert-kernel.sh <device-ip> <backup-file>      # restore one
```

`install-kernel.sh` writes a timestamped copy of the boot partition to
`/userdata/kernel-backup/` before every install, so there is always something
to go back to. Keep a copy of the untouched vendor image there as well; it is
the one that always works.

## 2. The device does not boot: U-Boot over the serial console

This has been used many times and it works. You need the serial console
(below).

Interrupt the boot at `Hit key to stop autoboot` with Ctrl-C, then:

```
ext4load mmc 0:8 0x48000000 /kernel-backup/boot-vendor.img
mmc write 0x48000000 0x8000 0x77F5
reset
```

`0x77F5` is 30709 sectors of 512 bytes = 15,723,008 bytes, the size of
`boot-vendor.img`. **Adjust it if your image has a different size**, and check
that the load output reports the byte count you expect before writing.

Partition 8 is `userdata`, partition 3 is `boot` starting at sector `0x8000`.

Optional verification before the reset:

```
mmc read 0x4c000000 0x8000 0x77F5
cmp.b 0x48000000 0x4c000000 0xF7F000
```

## 3. Neither works: the SSH race

If the kernel panics but gets far enough for dropbear to come up, there is a
window of a few seconds per boot. Hammer it:

```sh
for i in $(seq 1 50); do
  OUT=$(sshpass -p admin ssh -o ConnectTimeout=2 root@<ip> \
    'cat /userdata/kernel-backup/boot-vendor.img > /dev/block/by-name/boot \
     && sync && echo WRITE_OK' 2>/dev/null)
  case "$OUT" in *WRITE_OK*) echo "caught it on attempt $i"; break;; esac
done
```

Restore first, diagnose second. If the loop is interrupted halfway through a
diagnostic step you still want a bootable partition behind you.

## Maskrom does not help here

The vendor documentation describes Maskrom via reset, power and OTG. It does
not work for a broken boot partition: the BootROM finds idbloader, ATF and
U-Boot intact, loads them, and never appears on USB. No `2207:` device shows
up. Maskrom rescues a broken loader, not a broken kernel.

## Serial console

* UART2, **1500000 baud**, 8N1, 3.3 V. Do not use a 5 V adapter.
* `tio -b 1500000 -f none /dev/ttyUSB0 --log --log-file boot.log`, or
  `screen -L /dev/ttyUSB0 1500000`.
* **Turn off hardware handshaking** (`-crtscts`). With a three-wire connection
  and no CTS the driver blocks everything you type: you can read but not send,
  which looks like a dead console.
* Stop ModemManager and close stale `screen` sessions first.
* To test the sending direction, bridge TX and RX at the adapter and type.

On the RM1PE the RX pad is tiny and needs a soldered wire. A fine-tip iron,
0.1 mm enamelled wire and no-clean flux will do it; keep the run under half a
millimetre.

**Attach the console before you flash, and log the session.** Without it you
cannot tell whether U-Boot rejected the image, the kernel panicked, or nothing
was loaded at all.
