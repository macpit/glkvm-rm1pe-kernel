#!/usr/bin/env python3
"""Swap the kernel inside a FIT boot image, without rebuilding the FIT.

The boot partition holds a FIT whose header is a flattened device tree and
whose three payloads (fdt, kernel, resource) sit outside it, addressed by
data-position and data-size. Those fields are fixed width, and so is the
sha256 in each hash node. So a new kernel can be dropped in by overwriting
those fields in place and re-laying the payloads -- no mkimage, no dtc, no
libfdt. Only python3, which the device already has.

Usage:
    patch-fit.py --info  <image>
    patch-fit.py <image> <kernel> <output>

<image> may be a file or the boot partition itself. Output is always written
to a separate file; this never writes to a block device on its own.
"""
import argparse
import hashlib
import struct
import sys

FDT_MAGIC = 0xd00dfeed
BEGIN_NODE, END_NODE, PROP, NOP, END = 1, 2, 3, 4, 9
ALIGN = 0x200          # mkimage -B 0x200, matches the original layout
PARTS = ("fdt", "kernel", "resource")


def die(msg):
    print("patch-fit: " + msg, file=sys.stderr)
    raise SystemExit(1)


def align(x, a=ALIGN):
    return (x + a - 1) & ~(a - 1)


def parse_header(buf):
    if len(buf) < 40:
        die("image too short to hold a FIT header")
    magic, totalsize, off_struct, off_strings, _rsv, _ver, _lcv, _cpu, \
        size_strings, size_struct = struct.unpack_from(">10I", buf, 0)
    if magic != FDT_MAGIC:
        die("bad magic 0x%08x -- not a FIT image" % magic)
    return dict(totalsize=totalsize, off_struct=off_struct,
                off_strings=off_strings, size_struct=size_struct)


def walk(buf, h):
    """Yield (path, propname, value_offset, value_len) for every property."""
    off = h["off_struct"]
    end = off + h["size_struct"]
    path = []
    while off < end:
        (tok,) = struct.unpack_from(">I", buf, off)
        off += 4
        if tok == BEGIN_NODE:
            nul = buf.index(b"\0", off)
            path.append(buf[off:nul].decode("ascii", "replace"))
            off = align(nul + 1, 4)
        elif tok == END_NODE:
            if not path:
                die("malformed FIT: unbalanced node end")
            path.pop()
        elif tok == PROP:
            plen, nameoff = struct.unpack_from(">II", buf, off)
            off += 8
            ns = h["off_strings"] + nameoff
            name = buf[ns:buf.index(b"\0", ns)].decode("ascii", "replace")
            yield "/".join(path), name, off, plen
            off = align(off + plen, 4)
        elif tok == NOP:
            continue
        elif tok == END:
            break
        else:
            die("malformed FIT: bad token 0x%x at 0x%x" % (tok, off - 4))


def index(buf, h):
    """Locate the fields we need, by part name."""
    found = {p: {} for p in PARTS}
    for path, name, voff, vlen in walk(buf, h):
        for p in PARTS:
            if path == "/images/" + p and name in ("data-size", "data-position"):
                if vlen != 4:
                    die("%s/%s is %d bytes, expected 4" % (p, name, vlen))
                found[p][name] = voff
            elif path.startswith("/images/%s/hash" % p) and name in ("algo", "value"):
                found[p][name] = (voff, vlen)
    for p in PARTS:
        for need in ("data-size", "data-position", "algo", "value"):
            if need not in found[p]:
                die("FIT has no %s for image '%s'" % (need, p))
        algo_off, algo_len = found[p]["algo"]
        if bytes(buf[algo_off:algo_off + algo_len]).rstrip(b"\0") != b"sha256":
            die("image '%s' does not use sha256; refusing" % p)
        if found[p]["value"][1] != 32:
            die("image '%s' hash is %d bytes, expected 32" % (p, found[p]["value"][1]))
    return found


def u32(buf, off):
    return struct.unpack_from(">I", buf, off)[0]


def layout(buf, idx):
    return {p: (u32(buf, idx[p]["data-position"]), u32(buf, idx[p]["data-size"]))
            for p in PARTS}


def show(blob, idx, lay, label):
    print("%s:" % label)
    for p in PARTS:
        pos, size = lay[p]
        hoff, _ = idx[p]["value"]
        stored = bytes(blob[hoff:hoff + 32]).hex()
        actual = hashlib.sha256(blob[pos:pos + size]).hexdigest()
        mark = "ok" if stored == actual and pos + size <= len(blob) else "MISMATCH"
        print("    %-9s pos=0x%-8x size=%9d  sha256=%s… %s"
              % (p, pos, size, stored[:16], mark))


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--info", metavar="IMAGE",
                    help="print the layout of an existing image and exit")
    ap.add_argument("image", nargs="?")
    ap.add_argument("kernel", nargs="?")
    ap.add_argument("output", nargs="?")
    ap.add_argument("--read-size", type=int, default=32 * 1024 * 1024,
                    help="bytes to read from IMAGE (default 32 MiB, the partition size)")
    a = ap.parse_args()

    src = a.info or a.image
    if not src:
        ap.error("need an image")
    with open(src, "rb") as f:
        blob = bytearray(f.read(a.read_size))
    h = parse_header(blob)
    idx = index(blob, h)
    lay = layout(blob, idx)

    if a.info:
        show(blob, idx, lay, src)
        return
    if not a.kernel or not a.output:
        ap.error("need <image> <kernel> <output>")

    with open(a.kernel, "rb") as f:
        newk = f.read()
    if not newk:
        die("kernel image is empty")

    header_len = min(pos for pos, _ in lay.values())
    for p in PARTS:
        pos, size = lay[p]
        if pos + size > len(blob):
            die("image '%s' runs past the end of the source" % p)
    payload = {p: bytes(blob[pos:pos + size]) for p, (pos, size) in lay.items()}

    # The fdt and resource blobs are carried over untouched, so the source has
    # to be sound before we build anything on top of it. Every FIT records a
    # sha256 per image; check them rather than assume.
    for p in PARTS:
        hoff, _ = idx[p]["value"]
        stored = bytes(blob[hoff:hoff + 32])
        if hashlib.sha256(payload[p]).digest() != stored:
            die("image '%s' in the source does not match its recorded sha256.\n"
                "The boot partition looks damaged or is not one we know. "
                "Refusing to build on it." % p)
    payload["kernel"] = newk

    # fdt keeps its position; everything after it follows from the sizes.
    new = {}
    new["fdt"] = (lay["fdt"][0], len(payload["fdt"]))
    new["kernel"] = (align(new["fdt"][0] + new["fdt"][1]), len(newk))
    new["resource"] = (align(new["kernel"][0] + new["kernel"][1]),
                       len(payload["resource"]))
    total = new["resource"][0] + new["resource"][1]

    out = bytearray(blob[:header_len])
    for p in PARTS:
        pos, size = new[p]
        struct.pack_into(">I", out, idx[p]["data-position"], pos)
        struct.pack_into(">I", out, idx[p]["data-size"], size)
        hoff, _ = idx[p]["value"]
        out[hoff:hoff + 32] = hashlib.sha256(payload[p]).digest()
    out.extend(b"\0" * (total - header_len))
    for p in PARTS:
        pos, size = new[p]
        out[pos:pos + size] = payload[p]

    with open(a.output, "wb") as f:
        f.write(out)

    idx2 = index(out, parse_header(out))
    show(bytearray(out), idx2, layout(out, idx2), a.output)
    print("    %d bytes, %s" % (len(out), hashlib.sha256(out).hexdigest()))


if __name__ == "__main__":
    main()
