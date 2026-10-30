import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

from mihomo_config import merge  # noqa: E402

TEMPLATE = yaml.safe_load((ROOT / "resources" / "config-template.yaml").read_text(encoding="utf-8"))
OVERRIDE = yaml.safe_load((ROOT / "resources" / "override.yaml").read_text(encoding="utf-8"))

CLASH_SUB = """
port: 7890
socks-port: 7891
mixed-port: 1234
external-controller: 0.0.0.0:9999
secret: from-subscription
dns:
  enable: true
  nameserver: [1.1.1.1]
proxies:
  - {name: node-a, type: ss, server: 1.2.3.4, port: 8388, cipher: aes-128-gcm, password: x}
proxy-groups:
  - {name: Proxy, type: select, proxies: [node-a]}
rules:
  - MATCH,Proxy
"""

LINK_SUB = "ss://YWVzLTEyOC1nY206cGFzcw@1.2.3.4:8388#node-a\ntrojan://pw@example.com:443#node-b\n"


class MergeTests(unittest.TestCase):
    def test_clash_yaml_is_base_and_override_wins(self):
        override = dict(OVERRIDE, **{"mixed-port": 7900, "secret": "local"})
        config, provider = merge.build_config(CLASH_SUB, TEMPLATE, override, gh_proxy="https://m.example/")
        self.assertIsNone(provider)
        self.assertEqual(config["mixed-port"], 7900)
        self.assertEqual(config["secret"], "local")
        self.assertEqual(config["external-controller"], "127.0.0.1:9090")
        self.assertNotIn("port", config)
        self.assertNotIn("socks-port", config)
        self.assertEqual(config["proxies"][0]["name"], "node-a")
        self.assertEqual(config["rules"], ["MATCH,Proxy"])
        self.assertEqual(config["dns"]["nameserver"], ["1.1.1.1"])

    def test_link_subscription_uses_template_provider(self):
        config, provider = merge.build_config(LINK_SUB, TEMPLATE, OVERRIDE, provider_path="./providers/x.txt")
        self.assertEqual(provider, LINK_SUB)
        self.assertEqual(config["proxy-providers"]["sub"]["path"], "./providers/x.txt")
        self.assertEqual(config["proxy-groups"][0]["name"], "Proxy")
        self.assertNotIn("proxies", config)

    def test_base64_subscription_is_not_clash(self):
        self.assertIsNone(merge.parse_clash_yaml("c3M6Ly9hYmM="))

    def test_gh_proxy_placeholder(self):
        config, _ = merge.build_config(CLASH_SUB, TEMPLATE, OVERRIDE, gh_proxy="https://m.example")
        self.assertTrue(config["geox-url"]["geoip"].startswith("https://m.example/https://github.com/"))
        config, _ = merge.build_config(CLASH_SUB, TEMPLATE, OVERRIDE, gh_proxy="")
        self.assertTrue(config["geox-url"]["geoip"].startswith("https://github.com/"))

    def test_tun_enables_dns_defaults(self):
        override = merge.deep_merge(OVERRIDE, {"tun": {"enable": True}})
        config, _ = merge.build_config(LINK_SUB, TEMPLATE, override)
        self.assertTrue(config["tun"]["enable"])
        self.assertTrue(config["dns"]["enable"])
        self.assertEqual(config["dns"]["enhanced-mode"], "fake-ip")

    def test_tun_keeps_subscription_dns(self):
        override = merge.deep_merge(OVERRIDE, {"tun": {"enable": True}})
        config, _ = merge.build_config(CLASH_SUB, TEMPLATE, override)
        self.assertEqual(config["dns"]["nameserver"], ["1.1.1.1"])

    def test_dotted_helpers(self):
        data = {}
        merge.set_dotted(data, "tun.enable", "true")
        merge.set_dotted(data, "mixed-port", "7901")
        self.assertIs(merge.get_dotted(data, "tun.enable"), True)
        self.assertEqual(data["mixed-port"], 7901)


class CliTests(unittest.TestCase):
    def run_cli(self, *args):
        env = dict(os.environ, PYTHONPATH=str(ROOT / "python"))
        return subprocess.run(
            [sys.executable, "-m", "mihomo_config", *args], env=env, capture_output=True, text=True
        )

    def test_generate_and_override_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            source = tmp / "sub.txt"
            source.write_text(LINK_SUB, encoding="utf-8")
            override = tmp / "override.yaml"
            self.assertEqual(self.run_cli("override-init", str(override), str(ROOT / "resources" / "override.yaml")).returncode, 0)
            self.assertEqual(self.run_cli("override-set", str(override), "mixed-port=7911", "secret=abc").returncode, 0)
            result = self.run_cli(
                "generate", "--source", str(source), "--template", str(ROOT / "resources" / "config-template.yaml"),
                "--override", str(override), "--output", str(tmp / "config.yaml"),
                "--provider-file", str(tmp / "providers" / "sub.txt"),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("mode=provider", result.stdout)
            config = yaml.safe_load((tmp / "config.yaml").read_text(encoding="utf-8"))
            self.assertEqual(config["mixed-port"], 7911)
            self.assertEqual((tmp / "providers" / "sub.txt").read_text(encoding="utf-8"), LINK_SUB)
            self.assertEqual(oct((tmp / "config.yaml").stat().st_mode & 0o777), "0o600")
            got = self.run_cli("override-get", str(override), "secret")
            self.assertEqual(got.stdout.strip(), "abc")

    def test_empty_subscription_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "sub.txt"
            source.write_text("\n", encoding="utf-8")
            result = self.run_cli(
                "generate", "--source", str(source), "--template", str(ROOT / "resources" / "config-template.yaml"),
                "--override", str(Path(tmp) / "none.yaml"), "--output", str(Path(tmp) / "c.yaml"),
            )
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
