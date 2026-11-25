import asyncio, http.client, http.server, json, os, socketserver, sys, threading, time, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fault_proxy


class Upstream(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    seen = []

    def do_GET(self):
        length = int(self.headers.get("Content-Length", 0))
        Upstream.seen.append((self.command, self.path, self.rfile.read(length)))
        data = b"x" * 5000
        self.send_response(200)
        if self.path == "/chunked":
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for part in (data[:3000], data[3000:]):
                self.wfile.write(b"%x\r\n%s\r\n" % (len(part), part))
            self.wfile.write(b"0\r\n\r\n")
        else:
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    do_PUT = do_GET

    def log_message(self, *arguments):
        pass


class Server(socketserver.ThreadingTCPServer):  # HTTPServer looks its own host name up first, which takes half a minute on some Macs
    allow_reuse_address, daemon_threads = True, True


class FaultProxyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream = Server(("127.0.0.1", 0), Upstream)
        threading.Thread(target=cls.upstream.serve_forever, daemon=True).start()
        cls.loop = asyncio.new_event_loop()
        threading.Thread(target=cls.loop.run_forever, daemon=True).start()
        cls.proxy = fault_proxy.Proxy("127.0.0.1", 0, 0, ("127.0.0.1", cls.upstream.server_address[1]))
        asyncio.run_coroutine_threadsafe(cls.proxy.start(), cls.loop).result(5)

    @classmethod
    def tearDownClass(cls):
        asyncio.run_coroutine_threadsafe(cls.proxy.stop(), cls.loop).result(5)
        cls.upstream.shutdown()
        cls.upstream.server_close()
        cls.loop.call_soon_threadsafe(cls.loop.stop)

    def setUp(self):
        Upstream.seen = []
        self.control("DELETE", "/rules")
        self.control("DELETE", "/stats")

    def control(self, method, path, body=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.proxy.control, timeout=5)
        connection.request(method, path, json.dumps(body) if body is not None else None)
        response = connection.getresponse()
        value = json.loads(response.read())
        connection.close()
        return response.status, value

    def rule(self, **rule):
        status, value = self.control("POST", "/rules", rule)
        self.assertEqual(status, 200)
        return value["id"]

    def request(self, path="/a", method="GET", body=None, timeout=5):
        connection = http.client.HTTPConnection("127.0.0.1", self.proxy.listen, timeout=timeout)
        try:
            connection.request(method, path, body)
            response = connection.getresponse()
            return response.status, response.read(), response
        finally:
            connection.close()

    def test_passes_requests_and_bodies_through(self):
        self.assertEqual(self.request("/a", "PUT", b"hello")[:2], (200, b"x" * 5000))
        self.assertEqual(Upstream.seen, [("PUT", "/a", b"hello")])
        self.assertEqual(self.request("/chunked")[:2], (200, b"x" * 5000))

    def test_keeps_a_connection_for_several_requests(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.proxy.listen, timeout=5)
        for path in ("/a", "/chunked", "/b"):
            connection.request("GET", path)
            self.assertEqual(len(connection.getresponse().read()), 5000)
        connection.close()

    def test_drop_applies_the_given_number_of_times_and_only_to_its_path(self):
        self.rule(action="drop", path="^/a", times=2)
        for _ in range(2):
            with self.assertRaises((http.client.RemoteDisconnected, ConnectionError)):
                self.request("/a")
        self.assertEqual(self.request("/b")[0], 200)
        self.assertEqual(self.request("/a")[0], 200)
        self.assertEqual(self.control("GET", "/rules")[1][0]["hits"], 2)

    def test_hang_never_answers(self):
        self.rule(action="hang", times=1)
        with self.assertRaises(TimeoutError):
            self.request(timeout=0.4)
        self.assertEqual(Upstream.seen, [])
        self.assertEqual(self.request()[0], 200)

    def test_delay_and_throttle_take_time(self):
        self.rule(action="delay", ms=300, times=1)
        start = time.monotonic()
        self.request()
        self.assertGreater(time.monotonic() - start, 0.28)
        self.rule(action="throttle", bytes_per_second=10_000, times=1)
        start = time.monotonic()
        self.assertEqual(len(self.request()[1]), 5000)
        self.assertGreater(time.monotonic() - start, 0.4)

    def test_status_answers_without_the_server(self):
        self.rule(action="status", status=429, retry_after_ms=2500, times=1)
        status, body, response = self.request()
        self.assertEqual((status, json.loads(body)["retry_after_ms"], response.getheader("Retry-After")), (429, 2500, "2"))
        self.rule(action="status", status=503, times=1)
        self.assertEqual(self.request()[0], 503)
        self.assertEqual(Upstream.seen, [])

    def test_lose_reaches_the_server_but_not_the_client(self):
        self.rule(action="lose", times=1)
        with self.assertRaises((http.client.RemoteDisconnected, ConnectionError)):
            self.request("/send", "PUT", b"1")
        self.assertEqual(Upstream.seen, [("PUT", "/send", b"1")])

    def test_cut_breaks_the_response(self):
        self.rule(action="cut", bytes=100, times=1)
        with self.assertRaises((http.client.IncompleteRead, ConnectionError)):
            self.request()

    def test_refuse_is_a_server_that_is_down(self):
        idle = http.client.HTTPConnection("127.0.0.1", self.proxy.listen, timeout=5)
        idle.request("GET", "/a")
        idle.getresponse().read()
        number = self.rule(action="refuse")
        with self.assertRaises(ConnectionRefusedError):
            self.request()
        with self.assertRaises((http.client.HTTPException, ConnectionError)):
            idle.sock.settimeout(1)
            idle.request("GET", "/a")
            idle.getresponse()
        self.control("DELETE", f"/rules/{number}")
        self.assertEqual(self.request()[0], 200)

    def test_stats_count_bytes_and_hide_identifiers(self):
        self.request("/_matrix/client/v3/rooms/!abc%3Aexample/send/m.room.message/t1?x=1", "PUT", b"12345")
        self.request("/_matrix/client/v3/sync?since=s123")
        stats = self.control("GET", "/stats")[1]
        self.assertEqual(stats["PUT /_matrix/client/v3/rooms/_/send/m.room.message/_"], {"requests": 1, "bytes_up": 5, "bytes_down": 5000, "status": {"200": 1}})
        self.assertEqual(stats["GET /_matrix/client/v3/sync"]["bytes_down"], 5000)

    def test_bad_rules_are_refused(self):
        for rule in ({"action": "explode"}, {"action": "delay"}, {"path": "x"}, {"action": "drop", "path": "("}):
            self.assertEqual(self.control("POST", "/rules", rule)[0], 400)


if __name__ == "__main__":
    unittest.main()
