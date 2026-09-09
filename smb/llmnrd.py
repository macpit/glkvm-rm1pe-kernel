#!/usr/bin/env python3
"""Answer LLMNR queries for this host's own name.

Windows resolves a flat name like \\glkvm-dev through DNS, then LLMNR
(Link-Local Multicast Name Resolution, RFC 4795, UDP 5355 on 224.0.0.252),
then NetBIOS.  mDNS is never consulted for a name without a .local suffix,
so advertising the box over WSD is not enough on its own: the Explorer
lists it and then fails with "Windows cannot access \\<name>".

This daemon answers those queries, and nothing else: only for our own
hostname, only A records, only over IPv4.  It is deliberately not a general
name server -- answering for other names would hijack them on the segment.

Started by /etc/init.d/S99smb.
"""

import errno
import socket
import struct
import sys
import subprocess
import time

PORT = 5355
GROUP = '224.0.0.252'
TTL = 30

TYPE_A = 1
TYPE_AAAA = 28
TYPE_ANY = 255
CLASS_IN = 1


def own_addresses(iface):
    """Current IPv4 addresses of iface, most preferred first."""
    try:
        out = subprocess.run(['ip', '-4', '-o', 'addr', 'show', 'dev', iface],
                             capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return []
    addrs = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) > 3 and parts[2] == 'inet':
            addrs.append(parts[3].split('/')[0])
    return addrs


def parse_name(data, off):
    labels = []
    while True:
        if off >= len(data):
            raise ValueError('truncated name')
        length = data[off]
        if length == 0:
            off += 1
            break
        if length & 0xC0:                      # no compression in LLMNR queries
            raise ValueError('compressed name')
        off += 1
        labels.append(data[off:off + length])
        off += length
    return b'.'.join(labels), off


def build_response(query, qname_raw, qtype, addr):
    txid = query[0:2]
    # QR=1, opcode 0, AA=1 -- an LLMNR responder is authoritative for its name
    flags = struct.pack('!H', 0x8400)
    counts = struct.pack('!HHHH', 1, 1, 0, 0)

    question = b''
    for label in qname_raw.split(b'.'):
        question += bytes([len(label)]) + label
    question += b'\x00' + struct.pack('!HH', qtype, CLASS_IN)

    answer = question[:-4]                     # same name, no pointer
    answer += struct.pack('!HHIH', TYPE_A, CLASS_IN, TTL, 4)
    answer += socket.inet_aton(addr)

    return txid + flags + counts + question + answer


def main():
    iface = sys.argv[1] if len(sys.argv) > 1 else 'eth0'
    name = (sys.argv[2] if len(sys.argv) > 2 else socket.gethostname()).lower()
    wanted = {name.encode(), (name + '.local').encode()}

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('', PORT))
    # Joining the group needs an interface with an address; at boot DHCP may
    # not be done yet (ENODEV).  Wait for it instead of dying.
    mreq = socket.inet_aton(GROUP) + socket.inet_aton('0.0.0.0')
    for attempt in range(150):
        try:
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
            break
        except OSError as e:
            if e.errno != errno.ENODEV or attempt == 149:
                raise
            time.sleep(2)
    print(f'llmnrd: answering for {name} on {iface}', flush=True)

    while True:
        try:
            data, src = sock.recvfrom(2048)
        except OSError:
            continue
        if len(data) < 12:
            continue
        flags, qdcount = struct.unpack('!HH', data[2:6])
        if flags & 0x8000 or qdcount != 1:     # ignore responses and oddities
            continue
        try:
            qname, off = parse_name(data, 12)
            qtype, qclass = struct.unpack('!HH', data[off:off + 4])
        except Exception:
            continue
        if qclass != CLASS_IN or qname.lower() not in wanted:
            continue
        if qtype not in (TYPE_A, TYPE_ANY):    # no AAAA: we answer IPv4 only
            continue
        addrs = own_addresses(iface)
        if not addrs:
            continue
        try:
            sock.sendto(build_response(data, qname, TYPE_A, addrs[0]), src)
        except OSError:
            pass


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        pass
