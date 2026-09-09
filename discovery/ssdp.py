#!/usr/bin/env python3
"""Announce this KVM over SSDP so Windows Explorer lists it.

Windows does not build its "Network -> Other devices" list from mDNS. That part
of Explorer is fed by SSDP/UPnP, through the SSDP Discovery and Function
Discovery Provider Host services. So a device can be perfectly visible to
Bonjour and still be absent from Explorer -- which is exactly what happens to
these KVMs while a Synology NAS on the same wire shows up fine.

This daemon fills that gap: it answers M-SEARCH, sends the periodic alive
notifications, and serves a minimal UPnP device description. Double-clicking
the entry in Explorer opens presentationURL, which is the KVM web interface.

Deliberately dependency-free -- plain sockets and http.server, nothing to
install on a device with no package manager.
"""

import http.server
import os
import re
import signal
import errno
import socket
import struct
import sys
import threading
import time
import uuid as uuidlib

SSDP_ADDR = "239.255.255.250"
SSDP_PORT = 1900
HTTP_PORT = int(os.environ.get("SSDP_HTTP_PORT", "1901"))
CACHE_MAX_AGE = 1800          # how long a control point may cache us
NOTIFY_INTERVAL = 600         # comfortably below CACHE_MAX_AGE

IFACE = os.environ.get("SSDP_IFACE", "eth0")


# --------------------------------------------------------------- device facts

def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip().strip("\x00")
    except OSError:
        return default


def iface_ip(iface):
    """Current IPv4 of the interface, or "" while it has none."""
    try:
        import subprocess
        out = subprocess.run(["ip", "-4", "addr", "show", iface],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=5).stdout.decode()
        m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", out)
        return m.group(1) if m else ""
    except Exception:
        return ""


def device_facts():
    mac = read("/sys/class/net/%s/address" % IFACE, "00:00:00:00:00:00")
    macflat = mac.replace(":", "").lower()
    host = read("/proc/sys/kernel/hostname", "glkvm")

    # /etc/version is what the firmware itself uses -- the same place the
    # vendor mDNS record takes its v= from. Reading anything else gets you a
    # number that disagrees with what every other tool on the network shows.
    #   RK_MODEL=RM1PE
    #   RK_VERSION=V1.9.1 release1
    verfile = read("/etc/version")
    m = re.search(r"^RK_MODEL=(\S+)", verfile, re.M)
    model = "GL-" + m.group(1) if m else (
        read("/proc/gl-hw-info/model") or "GL-KVM")
    m = re.search(r"^RK_VERSION=V?([\d.]+)", verfile, re.M)
    version = m.group(1) if m else ""

    # Stable UDN: same device, same uuid across restarts and reboots. Derived
    # from the MAC rather than random, so Windows does not accumulate a new
    # phantom entry every time the daemon restarts.
    udn = "uuid:" + str(uuidlib.uuid5(uuidlib.NAMESPACE_DNS, "glkvm-" + macflat))

    return {
        "mac": mac, "macflat": macflat, "host": host,
        "model": model, "version": version, "udn": udn,
        "friendly": "%s (%s)" % (host, model) if model else host,
    }


F = device_facts()


def description_xml(ip):
    # Shape copied from what a Synology NAS serves, because that one is known
    # to land in Explorer. The dummy serviceList is part of that: a Basic
    # device with no services at all is not reliably picked up.
    return """<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
\t<specVersion>
\t\t<major>1</major>
\t\t<minor>0</minor>
\t</specVersion>
\t<device>
\t\t<deviceType>urn:schemas-upnp-org:device:Basic:1</deviceType>
\t\t<friendlyName>{friendly}</friendlyName>
\t\t<manufacturer>GL.iNet</manufacturer>
\t\t<manufacturerURL>https://www.gl-inet.com</manufacturerURL>
\t\t<modelDescription>GL.iNet KVM over IP</modelDescription>
\t\t<modelName>{model}</modelName>
\t\t<modelNumber>{model} {version}</modelNumber>
\t\t<modelURL>https://www.gl-inet.com</modelURL>
\t\t<serialNumber>{macflat}</serialNumber>
\t\t<UDN>{udn}</UDN>
\t\t<serviceList>
\t\t\t<service>
\t\t\t\t<URLBase>http://{ip}:{port}</URLBase>
\t\t\t\t<serviceType>urn:schemas-dummy-com:service:Dummy:1</serviceType>
\t\t\t\t<serviceId>urn:dummy-com:serviceId:dummy1</serviceId>
\t\t\t\t<controlURL>/dummy</controlURL>
\t\t\t\t<eventSubURL>/dummy</eventSubURL>
\t\t\t\t<SCPDURL>/dummy.xml</SCPDURL>
\t\t\t</service>
\t\t</serviceList>
\t\t<presentationURL>http://{ip}/</presentationURL>
\t</device>
</root>
""".format(ip=ip, port=HTTP_PORT, **F)


# ---------------------------------------------------------------- http server

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        ip = iface_ip(IFACE) or self.request.getsockname()[0]
        if self.path.startswith("/desc.xml"):
            body = description_xml(ip).encode()
            self.send_response(200)
            self.send_header("Content-Type", 'text/xml; charset="utf-8"')
        elif self.path.startswith("/dummy.xml"):
            body = (b'<?xml version="1.0"?>\n<scpd '
                    b'xmlns="urn:schemas-upnp-org:service-1-0">'
                    b"<specVersion><major>1</major><minor>0</minor>"
                    b"</specVersion><actionList/><serviceStateTable/></scpd>\n")
            self.send_response(200)
            self.send_header("Content-Type", 'text/xml; charset="utf-8"')
        else:
            body = b"not found\n"
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # the default logs every hit to stderr


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


# ----------------------------------------------------------------------- ssdp

def targets():
    return ["upnp:rootdevice",
            "urn:schemas-upnp-org:device:Basic:1",
            F["udn"]]


def usn_for(st):
    return F["udn"] if st == F["udn"] else "%s::%s" % (F["udn"], st)


def location(ip):
    return "http://%s:%d/desc.xml" % (ip, HTTP_PORT)


def make_socket():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except (AttributeError, OSError):
        pass
    s.bind(("", SSDP_PORT))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 4)
    mreq = struct.pack("4sl", socket.inet_aton(SSDP_ADDR), socket.INADDR_ANY)
    # At boot this runs before DHCP has given eth0 an address, and joining a
    # multicast group with no usable interface fails with ENODEV.  Wait for
    # the address rather than die: the init hook that starts us does not.
    for attempt in range(150):
        try:
            s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
            break
        except OSError as e:
            if e.errno != errno.ENODEV or attempt == 149:
                raise
            time.sleep(2)
    return s


def notify(sock, kind):
    ip = iface_ip(IFACE)
    if not ip:
        return
    for st in targets():
        lines = ["NOTIFY * HTTP/1.1",
                 "HOST: %s:%d" % (SSDP_ADDR, SSDP_PORT),
                 "NT: " + st,
                 "NTS: " + kind,
                 "USN: " + usn_for(st)]
        if kind == "ssdp:alive":
            lines += ["CACHE-CONTROL: max-age=%d" % CACHE_MAX_AGE,
                      "LOCATION: " + location(ip),
                      "SERVER: Linux/%s UPnP/1.0 glkvm/%s"
                      % (os.uname().release, F["version"] or "1.0")]
        try:
            sock.sendto(("\r\n".join(lines) + "\r\n\r\n").encode(),
                        (SSDP_ADDR, SSDP_PORT))
        except OSError:
            pass
        time.sleep(0.05)


def answer(sock, addr, st):
    ip = iface_ip(IFACE)
    if not ip:
        return
    reply = "\r\n".join([
        "HTTP/1.1 200 OK",
        "CACHE-CONTROL: max-age=%d" % CACHE_MAX_AGE,
        "DATE: " + time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime()),
        "EXT:",
        "LOCATION: " + location(ip),
        "SERVER: Linux/%s UPnP/1.0 glkvm/%s"
        % (os.uname().release, F["version"] or "1.0"),
        "ST: " + st,
        "USN: " + usn_for(st),
        "", ""]).encode()
    try:
        sock.sendto(reply, addr)
    except OSError:
        pass


def serve_ssdp(sock, stop):
    while not stop.is_set():
        try:
            sock.settimeout(1.0)
            data, addr = sock.recvfrom(2048)
        except socket.timeout:
            continue
        except OSError:
            break

        text = data.decode("latin-1", "replace")
        if not text.startswith("M-SEARCH"):
            continue
        head = {}
        for line in text.split("\r\n")[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                head[k.strip().upper()] = v.strip()
        if '"ssdp:discover"' not in head.get("MAN", ""):
            continue

        st = head.get("ST", "ssdp:all")
        # MX is the caller's tolerance for a random delay; spreading replies is
        # what keeps a network of many devices from answering in one burst.
        try:
            mx = min(int(head.get("MX", "1")), 5)
        except ValueError:
            mx = 1
        delay = min(mx, 2) * 0.3

        if st == "ssdp:all":
            matched = targets()
        elif st in targets():
            matched = [st]
        else:
            continue

        def reply_later(addr=addr, matched=matched, delay=delay):
            time.sleep(delay)
            for st_ in matched:
                answer(sock, addr, st_)
        threading.Thread(target=reply_later, daemon=True).start()


def main():
    stop = threading.Event()

    httpd = Server(("", HTTP_PORT), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    sock = make_socket()
    threading.Thread(target=serve_ssdp, args=(sock, stop), daemon=True).start()

    def bye(*_):
        stop.set()
        notify(sock, "ssdp:byebye")
        httpd.shutdown()
        sys.exit(0)

    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGINT, bye)

    # Announced twice at startup: the spec asks for it, because the first
    # multicast is the one most likely to be lost.
    notify(sock, "ssdp:alive")
    time.sleep(1)
    notify(sock, "ssdp:alive")

    while not stop.is_set():
        for _ in range(NOTIFY_INTERVAL):
            if stop.is_set():
                return
            time.sleep(1)
        notify(sock, "ssdp:alive")


if __name__ == "__main__":
    main()
