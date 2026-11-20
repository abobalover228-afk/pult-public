import base64
import json
import threading
import secrets
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from server import create_server


class SignalingChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = create_server(port=0)
        cls.url = "http://127.0.0.1:" + str(cls.server.server_address[1])
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def request(self, path, body=None, room=None, peer="A" * 24, token=None, key=None):
        headers = {}
        if room:
            headers = {"Authorization": "Bearer " + (token or room["access"]), "X-Pult-Peer": peer}
            if key:
                headers["X-Pult-Peer-Key"] = key
            path = "/v1/rooms/" + room["room"] + "/" + path
        request = Request(self.url + path, data=json.dumps(body).encode() if body is not None else None,
                          headers=headers)
        try:
            with urlopen(request, timeout=3) as response:
                return response.status, json.load(response)
        except HTTPError as error:
            with error:
                return error.code, json.load(error)

    def test_member_cannot_take_a_keyed_peer_id(self):
        status, room = self.request("/v1/rooms", {})
        host, key = "H" * 24, "k" * 40
        self.assertEqual(self.request("join", {}, room=room, peer=host, key=key)[0], 200)
        self.assertEqual(self.request("join", {}, room=room, peer="B" * 24)[0], 200)
        self.assertEqual(self.request("join", {}, room=room, peer=host)[0], 401)
        self.assertEqual(self.request("join", {}, room=room, peer=host, key="x" * 40)[0], 401)
        self.assertEqual(self.request("signal", {"recipient": "B" * 24, "box": "QUFB"}, room=room, peer=host)[0], 401)
        self.request("leave", {}, room=room, peer=host, key=key)
        self.assertEqual(self.request("join", {}, room=room, peer=host)[0], 401)
        self.assertEqual(self.request("join", {}, room=room, peer=host, key=key)[0], 200)

    def test_negotiation_only_and_auth(self):
        status, room = self.request("/v1/rooms", {})
        self.assertEqual(status, 201)
        self.assertEqual(self.request("join", {}, room=room, token="wrong")[0], 403)
        self.assertEqual(self.request("join", {}, room=room)[0], 200)
        status, joined = self.request("join", {}, room=room, peer="B" * 24)
        self.assertEqual(joined["peers"], ["A" * 24])
        opaque = base64.b64encode(b"opaque-encrypted-sdp").decode()
        self.assertEqual(self.request("signal", {"recipient": "B" * 24, "box": opaque}, room=room)[0], 200)
        status, events = self.request("events?after=" + str(joined["cursor"]), room=room, peer="B" * 24)
        self.assertEqual(events["events"][0]["box"], opaque)
        self.assertEqual(self.request("messages", {"text": "PRIVATE CHAT"}, room=room)[0], 404)
        self.assertEqual(self.request("signal", {"recipient": "B" * 24, "text": "PRIVATE CHAT"}, room=room)[0], 400)
        self.assertEqual(self.request("join", {"text": "PRIVATE CHAT"}, room=room)[0], 409)
        self.assertEqual(self.request("leave", {}, room=room)[0], 200)
        self.assertEqual(self.request("signal", {"recipient": "B" * 24, "box": opaque}, room=room)[0], 410)

    def test_owner_only_creation(self):
        token = secrets.token_urlsafe(32)
        server = create_server(port=0, create_token=token)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        url = "http://127.0.0.1:" + str(server.server_address[1]) + "/v1/rooms"
        try:
            with self.assertRaises(HTTPError) as error:
                urlopen(Request(url, data=b"{}"), timeout=3)
            self.assertEqual(error.exception.code, 403)
            error.exception.close()
            with urlopen(Request(url, data=b"{}", headers={"X-Pult-Create-Token": token}), timeout=3) as response:
                self.assertEqual(response.status, 201)
        finally:
            server.shutdown(); server.server_close()

    def test_relay_is_opt_in_and_addressed(self):
        _, room = self.request("/v1/rooms", {})
        self.request("join", {}, room=room)
        opaque = base64.b64encode(b"sealed-room-packet").decode()
        self.assertEqual(self.request("join", {}, room=room, peer="B" * 24)[1]["relay"], False)
        self.assertEqual(self.request("relay", {"recipient": "B" * 24, "box": opaque}, room=room)[0], 404)
        self.assertEqual(self.request("/health")[1], {"ok": True, "mode": "signaling-only", "create": "open"})
        server = create_server(port=0, relay=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        saved, self.url = self.url, "http://127.0.0.1:" + str(server.server_address[1])
        try:
            self.assertEqual(self.request("/health")[1]["mode"], "relay")
            _, room = self.request("/v1/rooms", {})
            self.request("join", {}, room=room)
            _, bob = self.request("join", {}, room=room, peer="B" * 24)
            _, eve = self.request("join", {}, room=room, peer="C" * 24)
            self.assertTrue(bob["relay"])
            self.assertEqual(self.request("relay", {"recipient": "B" * 24, "box": opaque}, room=room)[0], 200)
            _, events = self.request("events?after=" + str(eve["cursor"]), room=room, peer="B" * 24)
            self.assertEqual([(e["kind"], e["sender"], e["box"]) for e in events["events"]], [("relay", "A" * 24, opaque)])
            self.assertEqual(self.request("relay", {"recipient": "Z" * 24, "box": opaque}, room=room)[0], 400)
            self.assertEqual(self.request("relay", {"recipient": "B" * 24, "box": "x" * 48_001}, room=room)[0], 400)
            self.assertEqual(self.request("relay", {"recipient": "B" * 24, "text": "PLAIN"}, room=room)[0], 400)
        finally:
            self.url = saved
            server.shutdown(); server.server_close()

    def test_limits_and_membership(self):
        _, room = self.request("/v1/rooms", {})
        for number in range(8):
            self.assertEqual(self.request("join", {}, room=room, peer=str(number) * 24)[0], 200)
        self.assertEqual(self.request("join", {}, room=room, peer="Z" * 24)[0], 409)
        self.assertEqual(self.request("join", {}, room=room, peer="bad")[0], 400)
        self.assertEqual(self.request("signal", {"recipient": "1" * 24, "box": "x" * 48_001}, room=room, peer="0" * 24)[0], 400)


if __name__ == "__main__":
    unittest.main()
