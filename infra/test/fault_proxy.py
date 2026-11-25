#!/usr/bin/env python3
"""HTTP/1.1 proxy between a Matrix client and its homeserver that breaks things on command and counts traffic (ADR-0009, ROADMAP M17-6).

    infra/test/fault_proxy.py [--listen 8118] [--control 8119] [--upstream localhost:8008] [--bind 127.0.0.1]

The client talks to --listen; tests talk to --control:
    POST   /rules   {"action": …, "path": "regex", "times": n, …}   add a rule → {"id": n}
    DELETE /rules   remove every rule          DELETE /rules/<id>   remove one          GET /rules   the rules, with `hits`
    GET    /stats   requests and body bytes per endpoint (IDs replaced by "_")           DELETE /stats   start counting again
Rules match the request path in the order they were added; the first match with `times` left applies (no `times`: always). Actions:
    drop      close the connection without an answer              refuse    stop listening, until the rule is removed (server down)
    hang      accept the request and never answer (half-open)     cut       close the connection after `bytes` (default 1) of the response body
    delay     wait `ms`, then pass the request on                 throttle  pass the response on at `bytes_per_second`
    status    answer `status` (with `body`; 429 takes `retry_after_ms`) without asking the server
    lose      the server gets the request, the client gets no answer (was it sent or not?)
Standard library only. For local tests: no TLS, no authentication on the control port, which binds to the same address.
"""
import argparse, asyncio, collections, contextlib, json, re, sys

MAX_HEAD = 64 * 1024
ACTIONS = {"drop", "refuse", "hang", "cut", "delay", "throttle", "status", "lose"}
REASONS = {200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 429: "Too Many Requests", 500: "Internal Server Error",
           502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout"}


def endpoint(method, path):
    """The path without query and identifiers, so `stats` groups calls and holds nothing private."""
    parts = path.split("?")[0].split("/")
    clean = ["_" if re.search(r"%|[!@$:]|\d{3,}|[A-Za-z0-9_-]{18,}", p) else p for p in parts]
    if "send" in clean and len(clean) > clean.index("send") + 2:
        clean[clean.index("send") + 2] = "_"  # the transaction ID
    return f"{method} {'/'.join(clean)}"


class Closed(Exception):
    pass


async def read_head(reader):
    try:
        head = await reader.readuntil(b"\r\n\r\n")
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, ConnectionError):
        raise Closed
    first, *lines = head.decode("latin-1").split("\r\n")
    headers = [tuple(part.strip() for part in line.split(":", 1)) for line in lines if ":" in line]
    return first, headers


def header(headers, name):
    return next((value for key, value in headers if key.lower() == name), None)


async def body_parts(reader, headers, until_close):
    """Yields (raw bytes to pass on, payload length)."""
    if "chunked" in (header(headers, "transfer-encoding") or "").lower():
        while True:
            line = await reader.readuntil(b"\r\n")
            size = int(line.split(b";")[0], 16)
            data = await reader.readexactly(size + 2)
            yield line + data, size
            if size == 0:
                return
    length = header(headers, "content-length")
    if length is not None:
        left = int(length)
        while left:
            data = await reader.read(min(left, 64 * 1024))
            if not data:
                raise Closed
            left -= len(data)
            yield data, len(data)
    elif until_close:
        while data := await reader.read(64 * 1024):
            yield data, len(data)


class Proxy:
    def __init__(self, bind, listen, control, upstream):
        self.bind, self.listen, self.control, self.upstream = bind, listen, control, upstream
        self.rules, self.next_id = [], 1
        self.stats = collections.defaultdict(lambda: {"requests": 0, "bytes_up": 0, "bytes_down": 0, "status": collections.Counter()})
        self.server = None
        self.open = set()

    async def start(self):
        self.control_server = await asyncio.start_server(self.on_control, self.bind, self.control)
        self.control = self.control_server.sockets[0].getsockname()[1]
        await self.accept(True)

    async def accept(self, accepting):
        if accepting and self.server is None:
            self.server = await asyncio.start_server(self.on_client, self.bind, self.listen, limit=MAX_HEAD, reuse_address=True)
            self.listen = self.server.sockets[0].getsockname()[1]
        elif not accepting and self.server is not None:
            self.server.close()
            self.server = None
            for writer in list(self.open):  # a server that is down also drops what it was doing
                writer.transport.abort()

    async def stop(self):
        await self.accept(False)
        self.control_server.close()

    def match(self, path):
        for rule in self.rules:
            if rule["action"] != "refuse" and rule.get("times", 1) > 0 and re.search(rule.get("path", ""), path):
                rule["hits"] += 1
                if "times" in rule:
                    rule["times"] -= 1
                return rule
        return None

    # MARK: Client side

    async def on_client(self, reader, writer):
        self.open.add(writer)
        try:
            while await self.one_request(reader, writer):
                pass
        except (Closed, ConnectionError, asyncio.IncompleteReadError, OSError):
            pass
        finally:
            self.open.discard(writer)
            with contextlib.suppress(Exception):
                writer.close()

    async def one_request(self, reader, writer):
        """Handles one request; `True` when the connection may carry another."""
        first, headers = await read_head(reader)
        method, path, _ = first.split(" ", 2)
        counted = self.stats[endpoint(method, path)]
        counted["requests"] += 1
        body = b""
        async for raw, size in body_parts(reader, headers, until_close=False):
            body += raw
            counted["bytes_up"] += size
        rule = self.match(path)
        action = rule["action"] if rule else None
        if action == "drop":
            writer.transport.abort()
            return False
        if action == "hang":
            await reader.read()  # until the client gives up
            return False
        if action == "delay":
            await asyncio.sleep(rule["ms"] / 1000)
        if action == "status":
            return await self.answer(writer, rule, counted)

        host, port = self.upstream
        try:
            up_reader, up_writer = await asyncio.open_connection(host, port, limit=MAX_HEAD)
        except OSError:
            return await self.answer(writer, {"status": 502, "body": {"errcode": "M_UNKNOWN", "error": "upstream unreachable"}}, counted)
        self.open.add(up_writer)
        try:
            kept = [(key, value) for key, value in headers if key.lower() not in ("connection", "expect")]
            up_writer.write("".join([first, "\r\n", *(f"{key}: {value}\r\n" for key, value in kept), "Connection: close\r\n\r\n"]).encode("latin-1") + body)
            await up_writer.drain()
            # A client that goes away must not leave the server with a long poll of nobody.
            gone = asyncio.ensure_future(self.gone(writer))
            answered = asyncio.ensure_future(read_head(up_reader))
            await asyncio.wait({gone, answered}, return_when=asyncio.FIRST_COMPLETED)
            gone.cancel()
            if not answered.done():
                answered.cancel()
                return False
            status, up_headers = answered.result()
            code = int(status.split(" ")[1])
            counted["status"][str(code)] += 1
            if action == "lose":
                async for _ in body_parts(up_reader, up_headers, until_close=True):
                    pass
                writer.transport.abort()
                return False
            framed = header(up_headers, "content-length") is not None or header(up_headers, "transfer-encoding") is not None
            reusable = framed or code in (204, 304)
            passed = [(key, value) for key, value in up_headers if key.lower() not in ("connection", "keep-alive")]
            writer.write("".join([status, "\r\n", *(f"{key}: {value}\r\n" for key, value in passed),
                                  "" if reusable else "Connection: close\r\n", "\r\n"]).encode("latin-1"))
            if method != "HEAD" and code not in (204, 304):
                left = rule.get("bytes", 1) if action == "cut" else None
                async for raw, size in body_parts(up_reader, up_headers, until_close=True):
                    if left is not None:
                        writer.write(raw[:left])
                        left -= len(raw)
                        if left <= 0:
                            await writer.drain()
                            await asyncio.sleep(0.05)  # let the part arrive before the connection breaks
                            writer.transport.abort()
                            return False
                        continue
                    counted["bytes_down"] += size
                    if action == "throttle":  # in quarter-second pieces, each after its time
                        piece = max(1, int(rule["bytes_per_second"] / 4))
                        for start in range(0, len(raw), piece):
                            await asyncio.sleep(len(raw[start:start + piece]) / rule["bytes_per_second"])
                            writer.write(raw[start:start + piece])
                            await writer.drain()
                        continue
                    writer.write(raw)
                    await writer.drain()
            await writer.drain()
            return reusable
        finally:
            self.open.discard(up_writer)
            up_writer.close()

    async def gone(self, writer):
        while not writer.transport.is_closing():
            await asyncio.sleep(0.1)

    async def answer(self, writer, rule, counted):
        code = int(rule["status"])
        content = rule.get("body")
        if content is None:
            content = {"errcode": "M_LIMIT_EXCEEDED" if code == 429 else "M_UNKNOWN", "error": "fault_proxy"}
            if "retry_after_ms" in rule:
                content["retry_after_ms"] = rule["retry_after_ms"]
        data = json.dumps(content).encode()
        extra = f"Retry-After: {max(1, rule['retry_after_ms'] // 1000)}\r\n" if "retry_after_ms" in rule else ""
        counted["status"][str(code)] += 1
        writer.write((f"HTTP/1.1 {code} {REASONS.get(code, 'Status')}\r\nContent-Type: application/json\r\n{extra}"
                      f"Content-Length: {len(data)}\r\n\r\n").encode() + data)
        await writer.drain()
        return True

    # MARK: Control side

    async def on_control(self, reader, writer):
        try:
            first, headers = await read_head(reader)
            method, path, _ = first.split(" ", 2)
            body = b""
            async for raw, _size in body_parts(reader, headers, until_close=False):
                body += raw
            code, value = await self.command(method, path, body)
            data = json.dumps(value).encode()
            writer.write(f"HTTP/1.1 {code} {REASONS[code]}\r\nContent-Type: application/json\r\nContent-Length: {len(data)}\r\nConnection: close\r\n\r\n".encode() + data)
            await writer.drain()
        except (Closed, ConnectionError):
            pass
        finally:
            writer.close()

    async def command(self, method, path, body):
        if path == "/rules" and method == "POST":
            try:
                rule = json.loads(body)
                action = rule["action"]
                re.compile(rule.get("path", ""))
            except (ValueError, KeyError, TypeError, re.error):
                return 400, {"error": "not a rule"}
            needed = {"delay": "ms", "throttle": "bytes_per_second", "status": "status"}.get(action)
            if action not in ACTIONS or (needed and needed not in rule):
                return 400, {"error": f"unknown action, or {needed} is missing"}
            rule = {**rule, "id": self.next_id, "hits": 0}
            self.next_id += 1
            self.rules.append(rule)
            await self.accept(not any(r["action"] == "refuse" for r in self.rules))
            return 200, {"id": rule["id"]}
        if path == "/rules" and method == "GET":
            return 200, self.rules
        if path.startswith("/rules") and method == "DELETE":
            wanted = path.removeprefix("/rules").strip("/")
            self.rules = [r for r in self.rules if wanted and str(r["id"]) != wanted]
            await self.accept(not any(r["action"] == "refuse" for r in self.rules))
            return 200, {}
        if path == "/stats" and method == "GET":
            return 200, self.stats
        if path == "/stats" and method == "DELETE":
            self.stats.clear()
            return 200, {}
        return 404, {"error": "unknown command"}


async def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--listen", type=int, default=8118)
    parser.add_argument("--control", type=int, default=8119)
    parser.add_argument("--upstream", default="localhost:8008")
    parser.add_argument("--bind", default="127.0.0.1")
    options = parser.parse_args()
    host, port = options.upstream.rsplit(":", 1)
    proxy = Proxy(options.bind, options.listen, options.control, (host, int(port)))
    await proxy.start()
    print(f"fault proxy: {options.bind}:{proxy.listen} -> {options.upstream}, control {proxy.control}", flush=True)
    await asyncio.Event().wait()


if __name__ == "__main__":
    with contextlib.suppress(KeyboardInterrupt):
        asyncio.run(main())
