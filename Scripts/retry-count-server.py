"""Serves a file, failing the first N requests for each Range with 503, and counts every request.

Used to measure how many times one byte range is really asked for when the downloader has more than
one retry layer. The count is what a refactor has to bring down.
"""
import os
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

PATH = ""
BPS = 0
FAIL_FIRST = 0
COUNT = 0
BY_RANGE = {}
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        global COUNT
        header = self.headers.get("Range") or "-"
        with LOCK:
            COUNT += 1
            seen = BY_RANGE.get(header, 0)
            BY_RANGE[header] = seen + 1
            total = COUNT
        if seen < FAIL_FIRST:
            sys.stderr.write("FAIL %d %s\n" % (total, header))
            sys.stderr.flush()
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        size = os.path.getsize(PATH)
        start, end, partial = 0, size - 1, False
        if header.startswith("bytes="):
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
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        with open(PATH, "rb") as f:
            f.seek(start)
            remaining = length
            while remaining > 0:
                data = f.read(min(65536, remaining))
                if not data:
                    break
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    return
                remaining -= len(data)
        with LOCK:
            sys.stderr.write("OK %d %s\n" % (total, header))
            sys.stderr.flush()


class Threaded(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    port = int(sys.argv[1])
    PATH = sys.argv[2]
    FAIL_FIRST = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    print("serving", PATH, "fail_first", FAIL_FIRST, file=sys.stderr)
    Threaded(("127.0.0.1", port), Handler).serve_forever()
