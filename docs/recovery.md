# Recovery

Ways back, in order of how much has gone wrong.

**Plan for needing the serial console.** The vendor's own failsafe routes are
documented below and are worth trying first, but the one time this project
actually bricked a device, they did not get it back -- serial and U-Boot did.
Do not start on the assumption that a web page will save you.

## 0. The vendor's failsafe routes: try them, do not count on them

GL.iNet document a U-Boot web recovery for this hardware. It is quick to
attempt and costs nothing, so it is the first thing to try -- but see the
caveat at the end of this section before you rely on it.

For the **GL-RM1PE**, from
[GL's own documentation](https://docs.gl-inet.com/kvm/en/faq/debrick/):

1. Download the stock firmware from <https://dl.gl-inet.com/kvm>.
2. Power the KVM off. Connect it directly to your computer's Ethernet port.
3. **Hold the Reset button and power the device on at the same time.** The blue
   LED flashes five times; release Reset after that, and the LED goes solid.
4. Set your computer's Ethernet interface to `192.168.1.2` / `255.255.255.0`.
5. Open `http://192.168.1.1` -- that is the U-Boot web UI. Choose the firmware
   file and click Update. It takes about three minutes; do not cut the power.

GL document two further routes that also need no serial console:
[RKDevTool](https://docs.gl-inet.com/kvm/en/tutorials/how_to_debrick_kvm_via_rkdevtool/)
and [USB OTG](https://docs.gl-inet.com/kvm/en/tutorials/how_to_unbrick_kvm_via_usb_otg/).

All three restore the stock image. If you only want your previous kernel back
and the device still gives you a shell, use option 1 instead.

> ### The caveat, and it is a real one
>
> **This did not work here when it was needed.** The one time a device in this
> project was left unbootable, the vendor recovery route did not bring it back;
> a serial console and the U-Boot prompt did. The documented USB/Maskrom route
> failed for a reason we could pin down -- with `idbloader`, ATF and U-Boot all
> intact, the BootROM loads them happily and never presents itself over USB, so
> a broken *boot partition* never reaches the point where Maskrom would help.
>
> The parts are certainly present in the U-Boot on this device: the upload page
> and the `httpd` command (`start web server for firmware recovery`) are in the
> binary, alongside `tftp`, `dhcp` and `rockusb`. Present is not the same as
> working when you need it, and this repository does not have evidence for the
> latter.
>
> Treat the vendor routes as worth five minutes before you get the soldering
> iron out, not as the reason you do not need one. If one of them does work for
> you, please open an issue and say which -- it would be genuinely useful to
> know.

## 1. The device still boots: revert over SSH

```sh
scripts/revert-kernel.sh <device-ip>                    # list backups
scripts/revert-kernel.sh <device-ip> <backup-file>      # restore one
```

`install-kernel.sh` writes a timestamped copy of the boot partition to
`/userdata/kernel-backup/` before every install, so there is always something
to go back to. Keep a copy of the untouched vendor image there as well; it is
the one that always works.

## 2. The device does not boot, and you want your own image back

This puts a specific image back rather than restoring stock, so it is what you
want if option 0 would throw away more than you like. It has been used many
times here and it works, but it needs the serial console (below).

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
