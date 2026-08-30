#!/usr/bin/env python3
"""Captive-portal state service for the GL-RM1PE access point.

nginx forwards the operating systems' connectivity-probe URLs here. While a
client is unknown it gets a redirect to the portal page, so the system shows
its captive-portal window. Once the portal has called /captive/done, this
service answers that client with whatever its OS reads as "the internet is
here", and the window stops appearing on later joins.

State is deliberately in memory only: after a restart of the access point every
client sees the portal again, and a recycled DHCP lease never inherits somebody
else's release.

Listens on 127.0.0.1:8088. nginx passes the client address in X-Real-IP.
"""

import http.server
import socketserver
import time
from urllib.parse import urlparse

PORT = 8088
PORTAL = "http://192.192.193.1/portal/?cna=1"

# The ?cna=1 marker above is how the page tells the captive window apart from a
# normal browser. The user agent cannot do it: the system prober identifies as
# CaptiveNetworkSupport, but the web view inside the very same window sends an
# ordinary Safari string.

released = {}
TTL = 6 * 3600

APPLE = b"<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>\n"


def is_released(ip):
    ts = released.get(ip)
    if ts is None:
        return False
    if time.time() - ts > TTL:
        del released[ip]
        return False
    return True


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def client_ip(self):
        return self.headers.get("X-Real-IP", self.client_address[0])

    def send_body(self, code, body, ctype="text/html"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_empty(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path
        ip = self.client_ip()

        if path == "/captive/done":
            released[ip] = time.time()
            self.send_body(200, b"ok", "text/plain")
            return

        if path == "/captive/status":
            self.send_body(200, b"released" if is_released(ip) else b"captive",
                           "text/plain")
            return

        if not is_released(ip):
            self.send_response(302)
            self.send_header("Location", PORTAL)
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return

        # Released: answer what each system expects to see.
        if path.endswith("/generate_204") or path.endswith("/gen_204"):
            self.send_empty(204)
        elif path.endswith("connecttest.txt"):
            self.send_body(200, b"Microsoft Connect Test", "text/plain")
        elif path.endswith("ncsi.txt"):
            self.send_body(200, b"Microsoft NCSI", "text/plain")
        elif path.endswith("success.txt"):
            self.send_body(200, b"success\n", "text/plain")
        else:
            self.send_body(200, APPLE)

    def log_message(self, fmt, *args):
        # Quiet by default. Uncomment to watch probes arrive; the user agent
        # tells you whether it is the system prober or the portal page.
        #
        # import sys
        # sys.stderr.write("%s %s %s | %s\n" % (
        #     time.strftime("%H:%M:%S"), self.client_ip(), self.path,
        #     self.headers.get("User-Agent", "-")))
        # sys.stderr.flush()
        pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    Server(("127.0.0.1", PORT), Handler).serve_forever()
