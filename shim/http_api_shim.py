#!/usr/bin/env python3
"""Meshtastic node-HTTP-API <-> TCP shim.

Speaks the two endpoints the Meshtastic web client's HTTP transport uses
    GET  /api/v1/fromradio   -> one queued FromRadio protobuf (empty body if none)
    PUT  /api/v1/toradio     -> frame and forward one ToRadio protobuf
and maintains a single auto-reconnecting connection to a Meshtastic TCP
endpoint (here: ble-bridge on 127.0.0.1:4403). This lets a browser client
served from anywhere talk to a node that only exposes the raw TCP protocol.

Stdlib only, on purpose: it runs in a bare python:alpine container with the
script bind-mounted, no pip layer to maintain.

Framing on the TCP side is the standard Meshtastic stream header:
0x94 0xC3 <len_hi> <len_lo> <protobuf>.
"""
import http.server
import os
import queue
import socket
import socketserver
import sys
import threading
import time

NODE_HOST = os.environ.get("NODE_HOST", "127.0.0.1")
NODE_PORT = int(os.environ.get("NODE_PORT", "4403"))
LISTEN_PORT = int(os.environ.get("PORT", "4405"))
# Comma-separated allowed Origins, or "*". Browsers enforce this; keep tight.
ALLOW_ORIGINS = [o.strip() for o in os.environ.get(
    "ALLOW_ORIGINS", "*").split(",") if o.strip()]
QUEUE_MAX = 2000

START = bytes([0x94, 0xC3])


class Radio:
    """One TCP connection to the node; each HTTP client gets its own bounded
    frame queue (broadcast on receive, oldest dropped). Without per-client
    queues, two browsers polling simultaneously split the stream and neither
    ever completes its config download."""

    CLIENT_IDLE_DROP = 180  # seconds without a poll before a client queue is dropped

    def __init__(self):
        self.clients = {}          # key (client ip) -> [queue, last_poll_ts]
        self.clients_lock = threading.Lock()
        self.sock = None
        self.send_lock = threading.Lock()
        threading.Thread(target=self._reader, daemon=True).start()

    def queue_for(self, key):
        now = time.time()
        with self.clients_lock:
            for k in [k for k, v in self.clients.items()
                      if now - v[1] > self.CLIENT_IDLE_DROP]:
                del self.clients[k]
            if key not in self.clients:
                self.clients[key] = [queue.Queue(maxsize=QUEUE_MAX), now]
            entry = self.clients[key]
            entry[1] = now
            return entry[0]

    def _connect(self):
        while True:
            try:
                s = socket.create_connection((NODE_HOST, NODE_PORT), timeout=10)
                s.settimeout(None)
                print(f"tcp connected to {NODE_HOST}:{NODE_PORT}", flush=True)
                return s
            except OSError as e:
                print(f"tcp connect failed: {e}; retrying in 5s", flush=True)
                time.sleep(5)

    def _enqueue(self, frame):
        with self.clients_lock:
            queues = [v[0] for v in self.clients.values()]
        for q in queues:
            try:
                q.put_nowait(frame)
            except queue.Full:
                try:
                    q.get_nowait()
                except queue.Empty:
                    pass
                q.put_nowait(frame)

    def _reader(self):
        while True:
            self.sock = self._connect()
            buf = b""
            try:
                while True:
                    data = self.sock.recv(4096)
                    if not data:
                        raise OSError("eof from node")
                    buf += data
                    while True:
                        start = buf.find(START)
                        if start < 0:
                            # keep a trailing 0x94 in case the pair is split
                            buf = buf[-1:] if buf.endswith(START[:1]) else b""
                            break
                        if start > 0:
                            buf = buf[start:]
                        if len(buf) < 4:
                            break
                        length = (buf[2] << 8) | buf[3]
                        if len(buf) < 4 + length:
                            break
                        self._enqueue(buf[4:4 + length])
                        buf = buf[4 + length:]
            except OSError as e:
                print(f"tcp lost: {e}; reconnecting", flush=True)
                try:
                    self.sock.close()
                except OSError:
                    pass
                self.sock = None
                time.sleep(2)

    def send(self, payload):
        with self.send_lock:
            if self.sock is None:
                raise OSError("node link down")
            header = bytes([0x94, 0xC3, (len(payload) >> 8) & 0xFF,
                            len(payload) & 0xFF])
            self.sock.sendall(header + payload)


radio = Radio()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _origin_ok(self):
        if "*" in ALLOW_ORIGINS:
            return "*"
        origin = self.headers.get("Origin", "")
        return origin if origin in ALLOW_ORIGINS else None

    def _cors(self, origin):
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
            self.send_header("Access-Control-Allow-Methods", "GET, PUT, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            # Chrome Private Network Access: a public origin fetching a
            # private-network host preflights with this header and requires
            # the ack (the newer Local Network Access model additionally
            # prompts the user - that part is theirs to allow).
            if self.headers.get("Access-Control-Request-Private-Network") == "true":
                self.send_header("Access-Control-Allow-Private-Network", "true")

    def _reply(self, code, body=b"", ctype="application/x-protobuf"):
        origin = self._origin_ok()
        self.send_response(code)
        self._cors(origin)
        if body or code == 200:
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_OPTIONS(self):
        self._reply(204)

    def do_GET(self):
        if self.path.startswith("/api/v1/fromradio"):
            try:
                frame = radio.queue_for(self.client_address[0]).get_nowait()
            except queue.Empty:
                frame = b""
            self._reply(200, frame)
        elif self.path == "/healthz":
            up = radio.sock is not None
            self._reply(200 if up else 503,
                        b"link up" if up else b"node link down", "text/plain")
        elif self.path == "/" or self.path.startswith("/?"):
            # The web client's "Test connection" probes the root URL.
            self._reply(200, b"meshtastic http-api shim", "text/plain")
        else:
            self._reply(404, b"not found", "text/plain")

    def do_PUT(self):
        if not self.path.startswith("/api/v1/toradio"):
            self._reply(404, b"not found", "text/plain")
            return
        length = int(self.headers.get("Content-Length", "0"))
        payload = self.rfile.read(length) if length else b""
        try:
            radio.send(payload)
            self._reply(200)
        except OSError as e:
            print(f"toradio failed: {e}", flush=True)
            self._reply(503, b"node link down", "text/plain")

    def log_message(self, fmt, *args):
        pass  # polling floods; errors are printed explicitly above


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    print(f"http-api shim on :{LISTEN_PORT} -> {NODE_HOST}:{NODE_PORT} "
          f"(origins: {ALLOW_ORIGINS})", flush=True)
    try:
        Server(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
