#!/usr/bin/env python3
"""Fault-injecting HTTP source for HTTP-TPC pull tests.

The server pretends to hold a file of any size at /f/<size>[/<label>].  The
content is synthetic and deterministic: it is made of 1 MiB blocks, each one
starting with its own block number, so a block written at the wrong offset of
the destination file is always detected.  Nothing is stored on disk.

Faults are selected per request with query parameters of the source URL, e.g.

    http://host:port/f/67108864/t1?fault=drop&after=1000000&times=1

    fault=none        behave correctly (default)
    fault=status      answer GET with the HTTP status given by code= (default 503)
    fault=drop        send after= bytes of the body, then reset the connection
                      (rst=0: close it cleanly instead)
    fault=stall       send after= bytes, then stay silent for secs= seconds
    fault=slow        send the body at rate= bytes per second
    fault=late        answer correctly, but only after a wait that depends on
                      the range, so that ranges arrive in a chosen order:
                        order=reverse  of every window= ranges (default 4), the
                                       last one is answered first; step=
                                       seconds apart (default 0.25)
                        order=random   wait between 0 and max= seconds (default
                                       1), chosen from seed= and the range
                      A range is one of the 16 MiB pieces the destination asks for.
    fault=norange     ignore the Range header: answer 200 with the whole file
    fault=wrongrange  answer 206 for a range starting 1 MiB further than asked
    fault=shift       answer 206 claiming the range asked, with the data found
                      1 MiB further in the file
    fault=short       answer 206 for a range by= bytes shorter than asked
    fault=chunked     answer 206 with the right Content-Range but a chunked body
                      and no Content-Length; the body is by= bytes shorter than
                      the range (negative: longer; default 0, a correct answer)
    fault=corrupt     flip one bit of the byte at file offset at=
    fault=close       answer correctly but close the connection afterwards
    fault=proxied     answer a request for the whole file correctly, but with status
                      203 in place of 200, as a proxy that has changed the answer
    fault=shrink      HEAD reports <size>, GET serves a file by= bytes shorter
    fault=noclen      HEAD answers without Content-Length

Selectors restrict the GET requests a fault applies to:

    times=N           only the first N matching requests (default: all of them)
    at=OFFSET         only requests whose range contains this file offset
    conn=N            only requests on the N-th connection used for this URL

Other paths:

    /r/<port>/f/...   redirect (307) to the same path on another port, the way
                      a redirector sends a client to a data server
    /_stats           JSON log of every request served so far
    /_reset           forget the log and the fault counters

Command line:

    faulty_source.py serve  [--port P] [--bind ADDR] [--delay-ms MS]
    faulty_source.py verify FILE SIZE     compare FILE with the expected content
    faulty_source.py adler32 SIZE         print the adler32 of the expected content
"""

import argparse
import json
import random
import re
import socket
import socketserver
import struct
import sys
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

BLOCK = 1 << 20
RANGE = 16 * BLOCK
CHUNK = 256 * 1024
_PATTERN = random.Random(20261118).getrandbits(BLOCK * 8).to_bytes(BLOCK, "little")


def content(offset, length):
    """Return the expected bytes [offset, offset + length) of any file."""
    out = bytearray()
    end = offset + length
    while offset < end:
        block, pos = divmod(offset, BLOCK)
        count = min(BLOCK - pos, end - offset)
        if pos < 8:
            data = struct.pack(">Q", block) + _PATTERN[8:]
            out += data[pos:pos + count]
        else:
            out += _PATTERN[pos:pos + count]
        offset += count
    return bytes(out)


def adler32(size):
    value = 1
    offset = 0
    while offset < size:
        count = min(4 * BLOCK, size - offset)
        value = zlib.adler32(content(offset, count), value)
        offset += count
    return value & 0xFFFFFFFF


def verify(path, size):
    """Compare a file with the expected content; return an error or None."""
    offset = 0
    with open(path, "rb") as stream:
        while True:
            data = stream.read(4 * BLOCK)
            if not data:
                break
            if offset + len(data) > size:
                return "file is longer than the %d bytes expected" % size
            expected = content(offset, len(data))
            if data != expected:
                first = next(i for i in range(len(data)) if data[i] != expected[i])
                return "content differs at offset %d" % (offset + first)
            offset += len(data)
    if offset != size:
        return "file has %d bytes, %d expected" % (offset, size)
    return None


class State:
    lock = threading.Lock()
    requests = []
    counters = {}
    connections = {}
    delay = 0.0

    @classmethod
    def reset(cls):
        with cls.lock:
            cls.requests = []
            cls.counters = {}
            cls.connections = {}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "faulty-source/1"

    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.serve("HEAD")

    def do_GET(self):
        self.serve("GET")

    # -- helpers ---------------------------------------------------------

    def reply(self, status, headers=(), body=b""):
        # 1xx, 204 and 304 never carry content (RFC 9110, Section 6.4.1).  A
        # body sent with one of them would be read by the client as the start
        # of the next response on the connection.
        bodiless = status < 200 or status in (204, 304)
        if bodiless:
            body = b""
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        if not bodiless and not any(name.lower() == "content-length" for name, _ in headers):
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def armed(self, key, query, start, end):
        """Tell whether the fault of this URL applies to this request."""
        if "at" in query and not start <= int(query["at"]) <= end:
            return False
        times = int(query.get("times", -1))
        with State.lock:
            # Connections are numbered in the order they first ask for this URL.
            seen = State.connections.setdefault(key, [])
            if self.client_address[1] not in seen:
                seen.append(self.client_address[1])
            if "conn" in query and seen.index(self.client_address[1]) + 1 != int(query["conn"]):
                return False
            count = State.counters.get(key, 0)
            if 0 <= times <= count:
                return False
            State.counters[key] = count + 1
        return True

    def abort(self, reset):
        """Close the connection in the middle of a response."""
        self.close_connection = True
        if reset:
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                       struct.pack("ii", 1, 0))
            # The socket is only really closed, and the reset only sent, once
            # the file objects wrapping it are closed as well.
            self.wfile.close()
            self.rfile.close()
            self.connection.close()

    # -- request handling ------------------------------------------------

    def serve(self, method):
        record = {"method": method, "path": self.path, "conn": self.client_address[1],
                  "range": self.headers.get("Range"), "start": time.time(),
                  "status": None, "sent": 0, "fault": None}
        try:
            if State.delay:
                time.sleep(State.delay)
            self.dispatch(method, record)
        except (BrokenPipeError, ConnectionResetError, ValueError, OSError):
            self.close_connection = True
        finally:
            record["end"] = time.time()
            with State.lock:
                State.requests.append(record)

    def send_response(self, code, message=None):
        self._status = code
        super().send_response(code, message)

    def dispatch(self, method, record):
        url = urlsplit(self.path)
        query = {name: values[-1] for name, values in parse_qs(url.query).items()}

        if url.path == "/_stats":
            with State.lock:
                body = json.dumps(State.requests).encode()
            self.reply(200, [("Content-Type", "application/json")], body)
            return
        if url.path == "/_reset":
            State.reset()
            self.reply(200)
            return

        match = re.fullmatch(r"/r/(\d+)(/f/.*)", url.path)
        if match:
            host = self.headers.get("Host", "localhost").split(":")[0]
            target = "http://%s:%s%s" % (host, match.group(1), match.group(2))
            if url.query:
                target += "?" + url.query
            record["status"] = 307
            self.reply(307, [("Location", target)])
            return

        match = re.fullmatch(r"/f/(\d+)(/[^/]*)?", url.path)
        if not match:
            record["status"] = 404
            self.reply(404, body=b"no such file\n")
            return

        size = int(match.group(1))
        fault = query.get("fault", "none")
        key = self.path

        if method == "HEAD":
            record["status"] = 200
            headers = [("Accept-Ranges", "bytes")]
            if fault == "noclen":
                record["fault"] = fault
                self.send_response(200)
                for name, value in headers:
                    self.send_header(name, value)
                self.end_headers()
            else:
                self.reply(200, headers + [("Content-Length", str(size))])
            return

        if fault == "shrink":
            size = max(0, size - int(query.get("by", 1000)))

        # Work out the range asked for.
        header = self.headers.get("Range")
        ranged = False
        start, end = 0, size - 1
        if header:
            parsed = re.fullmatch(r"bytes=(\d+)-(\d*)", header.strip())
            if not parsed:
                record["status"] = 416
                self.reply(416, [("Content-Range", "bytes */%d" % size)])
                return
            start = int(parsed.group(1))
            if parsed.group(2):
                end = min(int(parsed.group(2)), size - 1)
            if start >= size:
                record["status"] = 416
                self.reply(416, [("Content-Range", "bytes */%d" % size)])
                return
            ranged = True

        active = fault != "none" and self.armed(key, query, start, end)
        if active:
            record["fault"] = fault

        if active and fault == "status":
            code = int(query.get("code", 503))
            record["status"] = code
            self.reply(code, body=b"injected failure\n")
            return

        if active and fault == "late":
            index = start // RANGE
            if query.get("order", "reverse") == "random":
                chooser = random.Random("%s/%d" % (query.get("seed", "0"), index))
                wait = chooser.uniform(0.0, float(query.get("max", 1)))
            else:
                window = int(query.get("window", 4))
                wait = (window - 1 - index % window) * float(query.get("step", 0.25))
            time.sleep(wait)

        if active and fault == "norange":
            ranged = False
            start, end = 0, size - 1

        data_start = start
        if active and fault == "wrongrange":
            start = min(start + BLOCK, size - 1)
            data_start = start
        if active and fault == "shift":
            data_start = start + BLOCK
        if active and fault == "short":
            end = max(start, end - int(query.get("by", 1000)))

        length = end - start + 1 if size else 0
        headers = [("Accept-Ranges", "bytes"), ("Content-Length", str(length))]
        if ranged:
            headers.append(("Content-Range", "bytes %d-%d/%d" % (start, end, size)))
        if active and fault == "close":
            headers.append(("Connection", "close"))
            self.close_connection = True

        # A chunked body carries no length of its own, so the client cannot
        # see from the framing that it is shorter or longer than the range.
        chunked = active and fault == "chunked"
        if chunked:
            headers[1] = ("Transfer-Encoding", "chunked")
            length = max(0, length - int(query.get("by", 0)))

        status = 206 if ranged else 200
        if active and fault == "proxied" and not ranged:
            status = 203
        record["status"] = status
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()

        limit = None
        if active and fault in ("drop", "stall"):
            limit = int(query.get("after", 0))
        rate = float(query.get("rate", 0)) if active and fault == "slow" else 0.0
        flip = int(query["at"]) if active and fault == "corrupt" and "at" in query else None
        began = time.time()

        sent = 0
        while sent < length:
            count = min(CHUNK, length - sent)
            if limit is not None:
                count = min(count, max(0, limit - sent))
            if count:
                data = content(data_start + sent, count)
                if flip is not None and start + sent <= flip < start + sent + count:
                    data = bytearray(data)
                    data[flip - start - sent] ^= 0x01
                if chunked:
                    data = b"%x\r\n" % count + bytes(data) + b"\r\n"
                self.wfile.write(data)
                sent += count
                record["sent"] = sent
            if limit is not None and sent >= limit:
                if fault == "drop":
                    self.abort(reset=query.get("rst", "1") != "0")
                    return
                time.sleep(float(query.get("secs", 30)))
                limit = None
            if rate:
                ahead = sent / rate - (time.time() - began)
                if ahead > 0:
                    time.sleep(ahead)
        if chunked:
            self.wfile.write(b"0\r\n\r\n")


# Not http.server.ThreadingHTTPServer: that needs Python 3.7, and the test host
# may only have 3.6.
class Server(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True
    request_queue_size = 256


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    commands = parser.add_subparsers(dest="command")
    commands.required = True

    serve = commands.add_parser("serve")
    serve.add_argument("--port", type=int, default=8080)
    serve.add_argument("--bind", default="0.0.0.0")
    serve.add_argument("--delay-ms", type=float, default=0.0,
                       help="wait this long before answering each request")

    check = commands.add_parser("verify")
    check.add_argument("file")
    check.add_argument("size", type=int)

    cksum = commands.add_parser("adler32")
    cksum.add_argument("size", type=int)

    args = parser.parse_args()

    if args.command == "verify":
        error = verify(args.file, args.size)
        if error:
            print("MISMATCH: " + error)
            return 1
        print("OK")
        return 0

    if args.command == "adler32":
        print("%08x" % adler32(args.size))
        return 0

    State.delay = args.delay_ms / 1000.0
    server = Server((args.bind, args.port), Handler)
    print("READY %d" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
