"""A file server that caps each connection's bandwidth, like a CDN that throttles per stream.

    python3 Scripts/throttled-server.py 8099 /tmp/big.bin 300000

Each response writes at most BYTES_PER_SEC bytes a second, so one connection tops out there no matter
how fast the link is. A downloader that opens several ranges at once gets a multiple of it.
"""
import os
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn


PATH = ""
BPS = 300_000
# Requests answered, and the most that were ever in flight at once: the two numbers that say
# whether a downloader is actually using the sockets it opened.
STATS = {"requests": 0, "peak": 0, "active": 0, "bytes": 0}
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        with LOCK:
            STATS["requests"] += 1
            STATS["active"] += 1
            STATS["peak"] = max(STATS["peak"], STATS["active"])
        try:
            self._serve()
        finally:
            with LOCK:
                STATS["active"] -= 1
            line = "REQ %d peak=%d bytes=%d\n" % (STATS["requests"], STATS["peak"], STATS["bytes"])
            sys.stderr.write(line)
            sys.stderr.flush()
            with open(os.path.join(os.path.dirname(PATH), "server-stats.txt"), "a") as log:
                log.write(line)

    def _serve(self):
        size = os.path.getsize(PATH)
        start, end = 0, size - 1
        header = self.headers.get("Range")
        partial = False
        if header and header.startswith("bytes="):
            spec = header[6:].split(",")[0]
            first, _, last = spec.partition("-")
            if first:
                start = int(first)
                end = int(last) if last else size - 1
            elif last:
                start = max(0, size - int(last))
            partial = True
        end = min(end, size - 1)
        length = max(0, end - start + 1)
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        chunk = max(4096, BPS // 20)
        sent = 0
        began = time.monotonic()
        with open(PATH, "rb") as f:
            f.seek(start)
            while sent < length:
                want = min(chunk, length - sent)
                data = f.read(want)
                if not data:
                    break
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    return
                sent += len(data)
                with LOCK:
                    STATS["bytes"] += len(data)
                # Pace the stream: this is the per-connection cap the accelerator exists to beat.
                target = began + sent / BPS
                delay = target - time.monotonic()
                if delay > 0:
                    time.sleep(delay)


class Threaded(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    port = int(sys.argv[1])
    PATH = sys.argv[2]
    BPS = int(sys.argv[3]) if len(sys.argv) > 3 else BPS
    Threaded(("127.0.0.1", port), Handler).serve_forever()
