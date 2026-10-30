"""Build a mihomo config.yaml from a subscription and local overrides."""

from __future__ import annotations

import copy
import sys
from typing import Any

import yaml

GH_PROXY_PLACEHOLDER = "__GH_PROXY__"

# Listener keys a subscription may carry; the local mixed-port is the only listener we manage.
STRIPPED_KEYS = (
    "port",
    "socks-port",
    "redir-port",
    "tproxy-port",
    "external-controller-tls",
    "external-controller-unix",
    "external-ui-url",
    "external-ui-name",
)

DEFAULT_TUN_DNS = {
    "enable": True,
    "listen": "127.0.0.1:1053",
    "ipv6": False,
    "enhanced-mode": "fake-ip",
    "fake-ip-range": "198.18.0.1/16",
    "default-nameserver": ["223.5.5.5", "119.29.29.29"],
    "nameserver": ["https://dns.alidns.com/dns-query", "https://doh.pub/dns-query"],
    "fake-ip-filter": ["*.lan", "*.local", "+.stun.*.*", "+.msftconnecttest.com", "+.msftncsi.com"],
}


def load_yaml_file(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as handle:
        return yaml.safe_load(handle)


# PyYAML (YAML 1.1) turns bare off/on/yes/no into bools. Mihomo wants strings here.
_BOOLISH_STRING_KEYS = {
    "find-process-mode": {False: "off", True: "always"},
}


def normalize_boolish_strings(config: dict) -> dict:
    """Restore mihomo string enums that YAML 1.1 coerced to bool."""
    for key, mapping in _BOOLISH_STRING_KEYS.items():
        if key in config and isinstance(config[key], bool):
            config[key] = mapping[config[key]]
    return config


def parse_clash_yaml(text: str) -> dict | None:
    """Return the parsed mapping when text is a Clash/Mihomo YAML profile, else None."""
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError:
        return None
    if isinstance(data, dict) and ("proxies" in data or "proxy-providers" in data):
        return normalize_boolish_strings(data)
    return None


def deep_merge(base: dict, override: dict) -> dict:
    """Merge override into a copy of base. Dicts merge recursively; everything else is replaced."""
    result = copy.deepcopy(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


def substitute(obj: Any, gh_proxy: str) -> Any:
    prefix = (gh_proxy.rstrip("/") + "/") if gh_proxy else ""
    if isinstance(obj, str):
        return obj.replace(GH_PROXY_PLACEHOLDER, prefix)
    if isinstance(obj, list):
        return [substitute(item, gh_proxy) for item in obj]
    if isinstance(obj, dict):
        return {key: substitute(value, gh_proxy) for key, value in obj.items()}
    return obj


def build_config(
    source_text: str,
    template: dict,
    override: dict,
    provider_path: str = "./providers/sub.txt",
    gh_proxy: str = "",
) -> tuple[dict, str | None]:
    """Return (config, provider_content). provider_content is None for Clash YAML subscriptions."""
    clash = parse_clash_yaml(source_text)
    provider_content: str | None = None
    if clash is not None:
        base = clash
        for key in STRIPPED_KEYS:
            base.pop(key, None)
    else:
        base = copy.deepcopy(template)
        providers = base.setdefault("proxy-providers", {})
        provider = providers.setdefault("sub", {"type": "file"})
        provider["type"] = "file"
        provider["path"] = provider_path
        provider_content = source_text if source_text.endswith("\n") else source_text + "\n"

    config = normalize_boolish_strings(deep_merge(base, substitute(override, gh_proxy)))

    tun = config.get("tun")
    if isinstance(tun, dict) and tun.get("enable"):
        dns = config.get("dns") if isinstance(config.get("dns"), dict) else {}
        if not dns.get("enable"):
            config["dns"] = deep_merge(DEFAULT_TUN_DNS, dns) | {"enable": True}
    return config, provider_content


def dump_config(config: dict) -> str:
    return yaml.safe_dump(config, sort_keys=False, allow_unicode=True, default_flow_style=False, width=4096)


def set_dotted(data: dict, dotted_key: str, raw_value: str) -> None:
    value = yaml.safe_load(raw_value)
    parts = dotted_key.split(".")
    cursor = data
    for part in parts[:-1]:
        child = cursor.get(part)
        if not isinstance(child, dict):
            child = {}
            cursor[part] = child
        cursor = child
    cursor[parts[-1]] = value


def get_dotted(data: dict, dotted_key: str) -> Any:
    cursor: Any = data
    for part in dotted_key.split("."):
        if not isinstance(cursor, dict) or part not in cursor:
            return None
        cursor = cursor[part]
    return cursor


def eprint(*args: Any) -> None:
    print(*args, file=sys.stderr)
