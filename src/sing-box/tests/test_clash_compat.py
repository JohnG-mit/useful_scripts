import unittest

from singbox_config.converter import convert_clash_proxy


class ClashCompatTest(unittest.TestCase):
    def test_vless_ws_transport_and_utls(self):
        outbound = convert_clash_proxy(
            {
                "name": "jp-ws",
                "type": "vless",
                "server": "unamecf.example.com",
                "port": 443,
                "uuid": "511fd9d5-1836-4c39-9480-7e3fb7c23f72",
                "tls": True,
                "flow": "",
                "client-fingerprint": "ios",
                "servername": "ujp1.example.com",
                "network": "ws",
                "ws-opts": {
                    "path": "/pq/jp1",
                    "headers": {"Host": "ujp1.example.com"},
                },
            },
            set(),
        )
        self.assertEqual(outbound["transport"]["type"], "ws")
        self.assertEqual(outbound["transport"]["path"], "/pq/jp1")
        self.assertEqual(outbound["transport"]["headers"]["Host"], "ujp1.example.com")
        self.assertEqual(outbound["tls"]["server_name"], "ujp1.example.com")
        self.assertEqual(outbound["tls"]["utls"]["fingerprint"], "ios")
        self.assertNotIn("flow", outbound)

    def test_vless_reality_opts(self):
        outbound = convert_clash_proxy(
            {
                "name": "jp-reality",
                "type": "vless",
                "server": "pq.vmjp.example.com",
                "port": 443,
                "uuid": "511fd9d5-1836-4c39-9480-7e3fb7c23f72",
                "tls": True,
                "flow": "xtls-rprx-vision",
                "client-fingerprint": "ios",
                "servername": "iosapps.itunes.apple.com",
                "reality-opts": {
                    "public-key": "ybBxu1pW3O9Me954LCDfXgHW6lIYepAbnla82yaZ5HE",
                    "short-id": "6a1faecb",
                },
            },
            set(),
        )
        self.assertEqual(outbound["flow"], "xtls-rprx-vision")
        self.assertTrue(outbound["tls"]["reality"]["enabled"])
        self.assertEqual(
            outbound["tls"]["reality"]["public_key"],
            "ybBxu1pW3O9Me954LCDfXgHW6lIYepAbnla82yaZ5HE",
        )
        self.assertEqual(outbound["tls"]["reality"]["short_id"], "6a1faecb")
        self.assertNotIn("transport", outbound)

    def test_vless_ws_sni_falls_back_to_host_header(self):
        outbound = convert_clash_proxy(
            {
                "name": "jp-ws-no-sni",
                "type": "vless",
                "server": "69.84.182.18",
                "port": 443,
                "uuid": "511fd9d5-1836-4c39-9480-7e3fb7c23f72",
                "tls": True,
                "client-fingerprint": "ios",
                "network": "ws",
                "ws-opts": {
                    "path": "/pq/jp1",
                    "headers": {"Host": "jpa1.example.com"},
                },
            },
            set(),
        )
        self.assertEqual(outbound["tls"]["server_name"], "jpa1.example.com")

    def test_hysteria2_ports_and_alpn(self):
        outbound = convert_clash_proxy(
            {
                "name": "kr-hy2",
                "type": "hysteria2",
                "server": "146.56.164.36",
                "port": 35000,
                "ports": "35000-39000",
                "mport": "35000-39000",
                "skip-cert-verify": True,
                "sni": "api.push.apple.com",
                "password": "511fd9d5-1836-4c39-9480-7e3fb7c23f72",
            },
            set(),
        )
        self.assertEqual(outbound["server_ports"], ["35000:39000"])
        self.assertEqual(outbound["tls"]["alpn"], ["h3"])
        self.assertTrue(outbound["tls"]["insecure"])


if __name__ == "__main__":
    unittest.main()
