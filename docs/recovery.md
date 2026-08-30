# Recovery

Ways back, in order of how much has gone wrong.

**Plan for needing the serial console.** If the device stops booting, that is
what gets it back. Do not start on the assumption that something easier will.

> **The vendor recovery routes do not work here, and it is worth knowing why.**
>
> GL.iNet document a U-Boot web failsafe at `192.168.1.1` -- hold Reset while
> powering on, wait for the blue LED to flash five times, release. It has never
> worked on this device. When one was actually left unbootable, the LED did not
> come on at all, so there was no signal to act on and no way to tell whether
> the mode had been entered. Recovery meant a serial console.
>
> Two things on this board explain it:
>
> * **The LED is not U-Boot's to drive.** It is run by a userspace daemon,
>   `/usr/sbin/led_event_controller`, started from `/etc/init.d/S23led` over
>   sysfs GPIOs. There is no LED node in the kernel device tree, nothing under
>   `/sys/class/leds`, and no LED node in U-Boot's control FDT. So the flashing
>   pattern the procedure asks you to wait for can only come from a booted
>   Linux -- exactly what you do not have when you need this.
> * **U-Boot is probably not seeing the button.** The only key in U-Boot's
>   device tree is an `adc-keys` "volume up" on the SARADC. The physical button
>   is `gpio-keys` `KEY_RST` on a GPIO. Holding Reset most likely never reaches
>   U-Boot's download-key check at all.
>
> U-Boot's control FDT also has no Ethernet controller, only mmc, serial, GPIO,
> SARADC and the USB2 phy -- which would leave `httpd` with no interface to
> bind to. That FDT may be a trimmed pre-relocation tree, so treat that last
> point as supporting evidence rather than proof.
>
> The USB/Maskrom route fails for a separate and simpler reason: with
> `idbloader`, ATF and U-Boot all intact, the BootROM loads them and never
> presents itself over USB, so a broken *boot partition* never gets that far.
>
> The pieces really are in the U-Boot binary -- the upload page and an `httpd`
> command (`start web server for firmware recovery`) are both there. Present is
> not the same as reachable. If you do get one of these routes to work on your
> unit, please open an issue and say which; it would change this page.

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

This is the one that actually works when things are bad. It has been used many
times here. It needs the serial console (below).

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

No `2207:` device appears at the OTG port, because the BootROM never gets that
far -- see the note at the top. Maskrom rescues a broken loader, not a broken
kernel. Forcing it would mean pulling an eMMC line to ground while powering on,
which is a last resort and has not been tried here.

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
