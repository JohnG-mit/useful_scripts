import base64
import json
import os
import re
import sys
import urllib.parse
from typing import Any, Dict, List, Optional, Set, Tuple

try:
    import yaml
except ImportError:  # pragma: no cover - runtime dependency hint
    yaml = None


def decode_base64_padded(value: str) -> str:
    value = value.strip()
    missing_padding = len(value) % 4
    if missing_padding:
        value += "=" * (4 - missing_padding)
    data = base64.urlsafe_b64decode(value.encode("utf-8"))
    return data.decode("utf-8", errors="ignore")


def sanitize_tag(raw: str, fallback: str) -> str:
    text = (raw or "").strip()
    if not text:
        text = fallback
    text = urllib.parse.unquote(text)
    text = re.sub(r"\s+", "-", text)
    text = re.sub(r"[^A-Za-z0-9._:-]", "-", text)
    text = re.sub(r"-+", "-", text).strip("-")
    return text or fallback


def ensure_unique_tag(tag: str, used_tags: Set[str]) -> str:
    candidate = tag
    index = 2
    while candidate in used_tags:
        candidate = f"{tag}-{index}"
        index += 1
    used_tags.add(candidate)
    return candidate


def parse_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.lower() in {"1", "true", "yes", "on"}
    return bool(value)


def parse_duration(value: Any, default_value: str) -> str:
    if value is None:
        return default_value
    if isinstance(value, (int, float)):
        return f"{int(value)}s"
    text = str(value).strip()
    if not text:
        return default_value
    if text.isdigit():
        return f"{text}s"
    return text


def maybe_decode_base64_blob(text: str) -> Optional[str]:
    compact = "".join(line.strip() for line in text.splitlines() if line.strip())
    if not compact or len(compact) < 16:
        return None
    if not re.fullmatch(r"[A-Za-z0-9+/=_-]+", compact):
        return None
    try:
        decoded = decode_base64_padded(compact)
    except Exception:
        return None
    if "vless://" in decoded or "vmess://" in decoded or "{\"" in decoded or "proxies:" in decoded:
        return decoded
    return None


def extract_tls_from_common_fields(data: Dict[str, Any], server_name_default: str = "") -> Optional[Dict[str, Any]]:
    skip_cert = data.get("skip-cert-verify")
    server_name = data.get("servername") or data.get("sni") or server_name_default
    should_enable = any(
        [
            parse_bool(data.get("tls")),
            data.get("network") in {"ws", "grpc", "http"},
            bool(server_name),
            skip_cert is not None,
        ]
    )
    if not should_enable:
        return None
    tls = {
        "enabled": True,
        "server_name": server_name,
        "insecure": parse_bool(skip_cert),
    }
    fingerprint = data.get("client-fingerprint") or data.get("fp")
    if fingerprint:
        tls["utls"] = {"enabled": True, "fingerprint": str(fingerprint)}
    return tls


def parse_vless_url(url: str, used_tags: Set[str]) -> Dict[str, Any]:
    parsed = urllib.parse.urlparse(url)
    params = urllib.parse.parse_qs(parsed.query)

    server = parsed.hostname or ""
    port = parsed.port or 443
    uuid = urllib.parse.unquote(parsed.username or "")

    tag = ensure_unique_tag(sanitize_tag(parsed.fragment, "vless-auto"), used_tags)

    outbound: Dict[str, Any] = {
        "type": "vless",
        "tag": tag,
        "server": server,
        "server_port": port,
        "uuid": uuid,
        "flow": params.get("flow", [""])[0],
        "packet_encoding": "xudp",
    }

    sni = params.get("sni", [""])[0] or server
    insecure = parse_bool(params.get("insecure", ["false"])[0])
    tls: Dict[str, Any] = {
        "enabled": True,
        "server_name": sni,
        "insecure": insecure,
    }

    fp = params.get("fp", [""])[0]
    if fp:
        tls["utls"] = {"enabled": True, "fingerprint": fp}

    if params.get("security", [""])[0] == "reality":
        tls["reality"] = {
            "enabled": True,
            "public_key": params.get("pbk", [""])[0],
            "short_id": params.get("sid", [""])[0],
        }

    outbound["tls"] = tls

    network = params.get("type", ["tcp"])[0]
    if network == "ws":
        outbound["transport"] = {
            "type": "ws",
            "path": params.get("path", ["/"])[0],
            "headers": {"Host": params.get("host", [""])[0]},
        }
    elif network == "grpc":
        outbound["transport"] = {
            "type": "grpc",
            "service_name": params.get("serviceName", [""])[0],
        }

    return outbound


def parse_hysteria2_url(url: str, used_tags: Set[str]) -> Dict[str, Any]:
    parsed = urllib.parse.urlparse(url)
    params = urllib.parse.parse_qs(parsed.query)

    server = parsed.hostname or ""
    port = parsed.port or 443
    password = urllib.parse.unquote(parsed.username or "")

    sni = params.get("sni", [server])[0] or server
    insecure = parse_bool(params.get("insecure", ["false"])[0])

    outbound: Dict[str, Any] = {
        "type": "hysteria2",
        "tag": ensure_unique_tag(sanitize_tag(parsed.fragment, "hy2-auto"), used_tags),
        "server": server,
        "server_port": port,
        "password": password,
        "tls": {
            "enabled": True,
            "server_name": sni,
            "insecure": insecure,
            "alpn": params.get("alpn", ["h3"])[0].split(","),
        },
    }

    if "obfs" in params:
        outbound["obfs"] = {
            "type": "salamander",
            "password": params["obfs"][0],
        }

    return outbound


def parse_tuic_url(url: str, used_tags: Set[str]) -> Dict[str, Any]:
    parsed = urllib.parse.urlparse(url)
    params = urllib.parse.parse_qs(parsed.query)

    server = parsed.hostname or ""
    port = parsed.port or 443
    uuid = urllib.parse.unquote(parsed.username or "")
    password = urllib.parse.unquote(parsed.password or "")

    if not password and ":" in uuid:
        uuid, password = uuid.split(":", 1)

    sni = params.get("sni", [server])[0] or server
    insecure = parse_bool(params.get("insecure", ["false"])[0])

    return {
        "type": "tuic",
        "tag": ensure_unique_tag(sanitize_tag(parsed.fragment, "tuic-auto"), used_tags),
        "server": server,
        "server_port": port,
        "uuid": uuid,
        "password": password,
        "congestion_control": params.get("congestion_control", ["bbr"])[0],
        "tls": {
            "enabled": True,
            "server_name": sni,
            "insecure": insecure,
            "alpn": params.get("alpn", ["h3"])[0].split(","),
        },
    }


def parse_trojan_url(url: str, used_tags: Set[str]) -> Dict[str, Any]:
    parsed = urllib.parse.urlparse(url)
    params = urllib.parse.parse_qs(parsed.query)

    server = parsed.hostname or ""
    port = parsed.port or 443
    password = urllib.parse.unquote(parsed.username or "")
    sni = params.get("sni", [server])[0] or server

    outbound: Dict[str, Any] = {
        "type": "trojan",
        "tag": ensure_unique_tag(sanitize_tag(parsed.fragment, "trojan-auto"), used_tags),
        "server": server,
        "server_port": port,
        "password": password,
        "tls": {
            "enabled": True,
            "server_name": sni,
            "insecure": parse_bool(params.get("insecure", ["false"])[0]),
        },
    }

    network = params.get("type", [""])[0]
    if network == "ws":
        outbound["transport"] = {
            "type": "ws",
            "path": params.get("path", ["/"])[0],
            "headers": {"Host": params.get("host", [""])[0]},
        }
    elif network == "grpc":
        outbound["transport"] = {
            "type": "grpc",
            "service_name": params.get("serviceName", [""])[0],
        }

    return outbound


def parse_ss_url(url: str, used_tags: Set[str]) -> Dict[str, Any]:
    parsed = urllib.parse.urlparse(url)

    tag = ensure_unique_tag(sanitize_tag(parsed.fragment, "ss-auto"), used_tags)
    query = urllib.parse.parse_qs(parsed.query)

    netloc = parsed.netloc
    if "@" not in netloc and parsed.path:
        netloc += parsed.path

    raw = netloc
    if raw.startswith("//"):
        raw = raw[2:]

    server = ""
    port = 0
    method = ""
    password = ""

    def parse_host_port(host_port: str) -> Tuple[str, int]:
        if ":" not in host_port:
            raise ValueError("invalid host:port in ss link")
        host, port_text = host_port.rsplit(":", 1)
        return host, int(port_text)

    if "@" in raw:
        creds, host_port = raw.rsplit("@", 1)
        if ":" in creds:
            method, password = creds.split(":", 1)
            method = urllib.parse.unquote(method)
            password = urllib.parse.unquote(password)
        else:
            decoded = decode_base64_padded(creds)
            method, password = decoded.split(":", 1)
        server, port = parse_host_port(host_port)
    else:
        decoded = decode_base64_padded(raw)
        creds, host_port = decoded.rsplit("@", 1)
        method, password = creds.split(":", 1)
        server, port = parse_host_port(host_port)

    outbound: Dict[str, Any] = {
        "type": "shadowsocks",
        "tag": tag,
        "server": server,
        "server_port": port,
        "method": method,
        "password": password,
    }

    plugin = query.get("plugin", [""])[0]
    if plugin:
        plugin = urllib.parse.unquote(plugin)
        parts = plugin.split(";")
        plugin_name = parts[0]
        plugin_opts = ";".join(parts[1:]) if len(parts) > 1 else ""
        if plugin_name == "obfs":
            plugin_name = "obfs-local"
        outbound["plugin"] = plugin_name
        if plugin_opts:
            outbound["plugin_opts"] = plugin_opts

    return outbound


def parse_vmess_url(url: str, used_tags: Set[str]) -> Dict[str, Any]:
    payload = url[len("vmess://") :].strip()
    vmess_json = json.loads(decode_base64_padded(payload))

    server = vmess_json.get("add", "")
    port = int(vmess_json.get("port", 0))
    tag = ensure_unique_tag(sanitize_tag(vmess_json.get("ps", "vmess-auto"), "vmess-auto"), used_tags)

    outbound: Dict[str, Any] = {
        "type": "vmess",
        "tag": tag,
        "server": server,
        "server_port": port,
        "uuid": vmess_json.get("id", ""),
        "security": vmess_json.get("scy", "auto"),
        "alter_id": int(vmess_json.get("aid", 0) or 0),
    }

    net = vmess_json.get("net", "tcp")
    tls_value = vmess_json.get("tls", "")
    if str(tls_value).lower() in {"tls", "reality", "1", "true"}:
        outbound["tls"] = {
            "enabled": True,
            "server_name": vmess_json.get("sni", "") or vmess_json.get("host", "") or server,
            "insecure": False,
        }

    if net == "ws":
        outbound["transport"] = {
            "type": "ws",
            "path": vmess_json.get("path", "/"),
            "headers": {"Host": vmess_json.get("host", "")},
        }
    elif net == "grpc":
        outbound["transport"] = {
            "type": "grpc",
            "service_name": vmess_json.get("path", ""),
        }

    return outbound


def parse_uri_line(line: str, used_tags: Set[str]) -> Optional[Dict[str, Any]]:
    if line.startswith("vless://"):
        return parse_vless_url(line, used_tags)
    if line.startswith("hysteria2://"):
        return parse_hysteria2_url(line, used_tags)
    if line.startswith("tuic://"):
        return parse_tuic_url(line, used_tags)
    if line.startswith("vmess://"):
        return parse_vmess_url(line, used_tags)
    if line.startswith("trojan://"):
        return parse_trojan_url(line, used_tags)
    if line.startswith("ss://"):
        return parse_ss_url(line, used_tags)
    return None


def parse_uri_lines(text: str, used_tags: Set[str]) -> List[Dict[str, Any]]:
    outbounds: List[Dict[str, Any]] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            outbound = parse_uri_line(line, used_tags)
            if outbound:
                outbounds.append(outbound)
            else:
                print(f"Warning: Unsupported protocol in line: {line[:30]}...")
        except Exception as exc:
            print(f"Warning: Failed to parse line {line[:30]}...: {exc}")
    return outbounds


def normalize_clash_plugin(proxy: Dict[str, Any], outbound: Dict[str, Any]) -> None:
    plugin = proxy.get("plugin")
    if not plugin:
        return

    if plugin == "obfs":
        plugin = "obfs-local"

    plugin_opts = proxy.get("plugin-opts") or {}
    opts_text = ""

    if plugin == "obfs-local" and isinstance(plugin_opts, dict):
        mode = plugin_opts.get("mode")
        host = plugin_opts.get("host")
        parts = []
        if mode:
            parts.append(f"obfs={mode}")
        if host:
            parts.append(f"obfs-host={host}")
        opts_text = ";".join(parts)
    elif isinstance(plugin_opts, dict):
        opts_text = ";".join(f"{k}={v}" for k, v in plugin_opts.items())

    outbound["plugin"] = plugin
    if opts_text:
        outbound["plugin_opts"] = opts_text


def convert_clash_proxy(proxy: Dict[str, Any], used_tags: Set[str]) -> Optional[Dict[str, Any]]:
    node_type = str(proxy.get("type", "")).lower()
    name = str(proxy.get("name", ""))
    tag = ensure_unique_tag(sanitize_tag(name, f"{node_type}-node"), used_tags)

    if node_type == "ss":
        outbound: Dict[str, Any] = {
            "type": "shadowsocks",
            "tag": tag,
            "server": proxy.get("server", ""),
            "server_port": int(proxy.get("port", 0)),
            "method": proxy.get("cipher", ""),
            "password": proxy.get("password", ""),
        }
        normalize_clash_plugin(proxy, outbound)
        if parse_bool(proxy.get("udp-over-tcp")):
            outbound["udp_over_tcp"] = True
        return outbound

    if node_type == "trojan":
        outbound = {
            "type": "trojan",
            "tag": tag,
            "server": proxy.get("server", ""),
            "server_port": int(proxy.get("port", 0)),
            "password": proxy.get("password", ""),
        }
        tls = extract_tls_from_common_fields(proxy, proxy.get("server", ""))
        if tls:
            outbound["tls"] = tls
        return outbound

    if node_type == "vless":
        outbound = {
            "type": "vless",
            "tag": tag,
            "server": proxy.get("server", ""),
            "server_port": int(proxy.get("port", 0)),
            "uuid": proxy.get("uuid", ""),
            "flow": proxy.get("flow", ""),
            "packet_encoding": "xudp",
        }
        tls = extract_tls_from_common_fields(proxy, proxy.get("server", ""))
        if tls:
            outbound["tls"] = tls
        return outbound

    if node_type == "vmess":
        outbound = {
            "type": "vmess",
            "tag": tag,
            "server": proxy.get("server", ""),
            "server_port": int(proxy.get("port", 0)),
            "uuid": proxy.get("uuid", ""),
            "alter_id": int(proxy.get("alterId", 0) or 0),
            "security": proxy.get("cipher", "auto"),
        }
        tls = extract_tls_from_common_fields(proxy, proxy.get("server", ""))
        if tls:
            outbound["tls"] = tls

        network = proxy.get("network")
        if network == "ws":
            ws_opts = proxy.get("ws-opts") or {}
            outbound["transport"] = {
                "type": "ws",
                "path": ws_opts.get("path", "/"),
                "headers": ws_opts.get("headers") or {},
            }
        elif network == "grpc":
            grpc_opts = proxy.get("grpc-opts") or {}
            outbound["transport"] = {
                "type": "grpc",
                "service_name": grpc_opts.get("grpc-service-name", ""),
            }

        return outbound

    if node_type == "hysteria2":
        outbound = {
            "type": "hysteria2",
            "tag": tag,
            "server": proxy.get("server", ""),
            "server_port": int(proxy.get("port", 0)),
            "password": proxy.get("password", ""),
        }
        tls = extract_tls_from_common_fields(proxy, proxy.get("server", ""))
        if not tls:
            tls = {
                "enabled": True,
                "server_name": proxy.get("sni") or proxy.get("server", ""),
                "insecure": parse_bool(proxy.get("skip-cert-verify")),
            }
        outbound["tls"] = tls
        return outbound

    if node_type == "tuic":
        outbound = {
            "type": "tuic",
            "tag": tag,
            "server": proxy.get("server", ""),
            "server_port": int(proxy.get("port", 0)),
            "uuid": proxy.get("uuid", ""),
            "password": proxy.get("password", ""),
            "congestion_control": proxy.get("congestion-controller", "cubic"),
        }
        tls = extract_tls_from_common_fields(proxy, proxy.get("server", ""))
        if not tls:
            tls = {
                "enabled": True,
                "server_name": proxy.get("sni") or proxy.get("server", ""),
                "insecure": parse_bool(proxy.get("skip-cert-verify")),
            }
        outbound["tls"] = tls
        return outbound

    print(f"Warning: Unsupported clash/mihomo proxy type: {node_type}")
    return None


def select_root_group(group_infos: List[Tuple[str, str, bool]]) -> Optional[str]:
    if not group_infos:
        return None

    priority_patterns = ["default", "proxy", "global", "auto"]
    for pattern in priority_patterns:
        for original_name, tag, hidden in group_infos:
            lowered = original_name.lower()
            if pattern in lowered and not hidden:
                return tag

    for _, tag, hidden in group_infos:
        if not hidden:
            return tag

    return group_infos[0][1]


def convert_clash_groups(
    payload: Dict[str, Any],
    name_to_tag: Dict[str, str],
    used_tags: Set[str],
) -> List[Dict[str, Any]]:
    outbounds: List[Dict[str, Any]] = []
    groups = payload.get("proxy-groups") or []
    if not isinstance(groups, list):
        return outbounds

    special_map = {"DIRECT": "direct", "REJECT": "block", "REJECT-DROP": "block"}

    group_name_to_tag: Dict[str, str] = {}
    group_infos: List[Tuple[str, str, bool]] = []

    for group in groups:
        if not isinstance(group, dict):
            continue
        group_name = str(group.get("name", ""))
        group_tag = ensure_unique_tag(sanitize_tag(group_name, "group"), used_tags)
        group_name_to_tag[group_name] = group_tag
        group_infos.append((group_name, group_tag, parse_bool(group.get("hidden"))))

    has_block_group = False

    for group in groups:
        if not isinstance(group, dict):
            continue

        group_name = str(group.get("name", ""))
        group_type = str(group.get("type", "select")).lower()
        group_tag = group_name_to_tag[group_name]

        raw_members = group.get("proxies") or []
        members: List[str] = []

        for member in raw_members:
            member_name = str(member)
            if member_name in name_to_tag:
                members.append(name_to_tag[member_name])
            elif member_name in group_name_to_tag:
                members.append(group_name_to_tag[member_name])
            elif member_name in special_map:
                mapped = special_map[member_name]
                members.append(mapped)
                if mapped == "block":
                    has_block_group = True

        if not members:
            continue

        mapped_group_type = group_type
        if group_type == "load-balance":
            mapped_group_type = "url-test"
            print(
                f"Warning: proxy-group '{group_name}' type 'load-balance' has no direct sing-box equivalent, mapped to urltest."
            )

        if mapped_group_type in {"url-test", "fallback"}:
            outbound = {
                "type": "urltest",
                "tag": group_tag,
                "outbounds": members,
                "url": group.get("url") or "https://www.gstatic.com/generate_204",
                "interval": parse_duration(group.get("interval"), "3m"),
                "tolerance": int(group.get("tolerance", 50) or 50),
            }
        else:
            outbound = {
                "type": "selector",
                "tag": group_tag,
                "outbounds": members,
                "default": members[0],
            }

        outbounds.append(outbound)

    if has_block_group and "block" not in used_tags:
        used_tags.add("block")
        outbounds.insert(0, {"type": "block", "tag": "block"})

    root_group_tag = select_root_group(group_infos)
    if root_group_tag and root_group_tag != "proxy":
        proxy_members = [root_group_tag]
        for _, tag, hidden in group_infos:
            if tag != root_group_tag and not hidden:
                proxy_members.append(tag)
        if len(proxy_members) == 1:
            for _, tag, _ in group_infos:
                if tag != root_group_tag:
                    proxy_members.append(tag)
        outbounds.insert(
            0,
            {
                "type": "selector",
                "tag": "proxy",
                "outbounds": proxy_members,
                "default": root_group_tag,
            },
        )
        used_tags.add("proxy")

    return outbounds


def parse_clash_or_mihomo_yaml(payload: Dict[str, Any], used_tags: Set[str]) -> List[Dict[str, Any]]:
    proxies = payload.get("proxies") or []
    if not isinstance(proxies, list):
        raise ValueError("YAML payload has no valid proxies list")

    outbounds: List[Dict[str, Any]] = []
    name_to_tag: Dict[str, str] = {}

    if "direct" not in used_tags:
        used_tags.add("direct")
        outbounds.append({"type": "direct", "tag": "direct"})

    for proxy in proxies:
        if not isinstance(proxy, dict):
            continue
        converted = convert_clash_proxy(proxy, used_tags)
        if not converted:
            continue
        outbounds.append(converted)
        if proxy.get("name"):
            name_to_tag[str(proxy["name"])] = converted["tag"]

    group_outbounds = convert_clash_groups(payload, name_to_tag, used_tags)
    outbounds.extend(group_outbounds)

    if not any(o.get("tag") == "proxy" for o in outbounds):
        candidate_tags = [
            outbound["tag"]
            for outbound in outbounds
            if outbound.get("tag") not in {"direct", "block", "proxy"}
        ]
        if candidate_tags:
            outbounds.insert(
                1 if outbounds and outbounds[0].get("tag") == "direct" else 0,
                {
                    "type": "selector",
                    "tag": "proxy",
                    "outbounds": candidate_tags,
                    "default": candidate_tags[0],
                },
            )
            used_tags.add("proxy")

    return outbounds


def parse_singbox_json(payload: Any, used_tags: Set[str]) -> List[Dict[str, Any]]:
    if isinstance(payload, list):
        raw_outbounds = payload
    elif isinstance(payload, dict):
        raw_outbounds = payload.get("outbounds")
    else:
        raw_outbounds = None

    if not isinstance(raw_outbounds, list):
        raise ValueError("JSON payload must be an outbounds list or object with outbounds")

    outbounds: List[Dict[str, Any]] = []
    if "direct" not in used_tags:
        used_tags.add("direct")
        outbounds.append({"type": "direct", "tag": "direct"})

    for item in raw_outbounds:
        if not isinstance(item, dict):
            continue
        item_copy = json.loads(json.dumps(item))
        tag = str(item_copy.get("tag", "")).strip()
        if not tag:
            fallback = f"{item_copy.get('type', 'outbound')}-auto"
            tag = ensure_unique_tag(sanitize_tag("", fallback), used_tags)
            item_copy["tag"] = tag
        elif tag in used_tags:
            new_tag = ensure_unique_tag(sanitize_tag(tag, "outbound"), used_tags)
            if new_tag != tag:
                old_tag = tag
                item_copy["tag"] = new_tag
                for nested in raw_outbounds:
                    if isinstance(nested, dict) and isinstance(nested.get("outbounds"), list):
                        nested["outbounds"] = [new_tag if x == old_tag else x for x in nested["outbounds"]]
        else:
            used_tags.add(tag)
        outbounds.append(item_copy)

    return outbounds


def detect_and_parse_source(source_text: str, used_tags: Set[str]) -> List[Dict[str, Any]]:
    stripped = source_text.strip()
    if not stripped:
        return []

    maybe_b64 = maybe_decode_base64_blob(stripped)
    if maybe_b64:
        return detect_and_parse_source(maybe_b64, used_tags)

    # JSON input (including sing-box subscription endpoint)
    if stripped.startswith("{") or stripped.startswith("["):
        try:
            payload = json.loads(stripped)
            return parse_singbox_json(payload, used_tags)
        except json.JSONDecodeError:
            pass

    # YAML input (mihomo / clash)
    if yaml is not None:
        try:
            payload = yaml.safe_load(stripped)
            if isinstance(payload, dict) and (
                isinstance(payload.get("proxies"), list)
                or isinstance(payload.get("proxy-groups"), list)
            ):
                return parse_clash_or_mihomo_yaml(payload, used_tags)
        except Exception:
            pass
    elif "proxies:" in stripped or "proxy-groups:" in stripped:
        raise RuntimeError("PyYAML is required to parse Clash/Mihomo YAML subscriptions. Please install pyyaml.")

    # URI line input
    return parse_uri_lines(stripped, used_tags)


def merge_into_proxy_selector(config: Dict[str, Any], added_tags: List[str]) -> None:
    if not added_tags:
        return

    proxy_selector = next(
        (o for o in config.get("outbounds", []) if o.get("tag") == "proxy" and o.get("type") == "selector"),
        None,
    )

    if proxy_selector is None:
        config.setdefault("outbounds", []).insert(
            0,
            {
                "type": "selector",
                "tag": "proxy",
                "outbounds": added_tags,
                "default": added_tags[0],
            },
        )
        return

    existing = proxy_selector.get("outbounds")
    if not isinstance(existing, list):
        existing = []

    for tag in added_tags:
        if tag not in existing and tag != "proxy":
            existing.append(tag)

    proxy_selector["outbounds"] = existing
    if not proxy_selector.get("default") and existing:
        proxy_selector["default"] = existing[0]


def merge_existing_group(existing: Dict[str, Any], incoming: Dict[str, Any]) -> None:
    existing_type = existing.get("type")
    incoming_type = incoming.get("type")

    # Only merge like-for-like group types; otherwise keep existing and skip incoming.
    if existing_type != incoming_type:
        return

    existing_members = existing.get("outbounds")
    incoming_members = incoming.get("outbounds")
    if not isinstance(existing_members, list):
        existing_members = []
    if not isinstance(incoming_members, list):
        incoming_members = []

    for member in incoming_members:
        if isinstance(member, str) and member not in existing_members and member != existing.get("tag"):
            existing_members.append(member)

    existing["outbounds"] = existing_members

    if existing_type == "selector":
        if not isinstance(existing.get("default"), str) or existing["default"] not in existing_members:
            if isinstance(incoming.get("default"), str) and incoming["default"] in existing_members:
                existing["default"] = incoming["default"]
            elif existing_members:
                existing["default"] = existing_members[0]
    elif existing_type == "urltest":
        if not existing.get("url") and incoming.get("url"):
            existing["url"] = incoming.get("url")
        if not existing.get("interval") and incoming.get("interval"):
            existing["interval"] = incoming.get("interval")
        if not isinstance(existing.get("tolerance"), int) and isinstance(incoming.get("tolerance"), int):
            existing["tolerance"] = incoming.get("tolerance")


def configure_common_fields(config: Dict[str, Any]) -> None:
    config.setdefault("log", {})
    config["log"]["output"] = "sing-box.log"
    config["log"]["level"] = "info"
    config["log"]["timestamp"] = True

    route = config.setdefault("route", {})
    route["final"] = "proxy"

    if "rule_set" in route and isinstance(route["rule_set"], list):
        new_rule_sets = []
        for rs in route["rule_set"]:
            if not isinstance(rs, dict):
                continue
            tag = rs.get("tag")
            url = rs.get("url")
            if not tag or not url:
                continue
            new_rule_sets.append(
                {
                    "tag": tag,
                    "type": "remote",
                    "format": "binary",
                    "url": url,
                    "download_detour": "proxy",
                }
            )
        route["rule_set"] = new_rule_sets


def main() -> None:
    if len(sys.argv) < 4:
        print(
            "Usage: python3 generate_config.py <template_path> <subscription_path> <output_path> [--append <existing_config>]"
        )
        sys.exit(1)

    template_path = sys.argv[1]
    subscription_path = sys.argv[2]
    output_path = sys.argv[3]

    append_mode = len(sys.argv) >= 6 and sys.argv[4] == "--append"
    existing_config_path = sys.argv[5] if append_mode else None

    with open(subscription_path, "r", encoding="utf-8", errors="ignore") as f:
        source_text = f.read()

    if append_mode and existing_config_path and os.path.exists(existing_config_path):
        with open(existing_config_path, "r", encoding="utf-8") as f:
            config = json.load(f)
        print(f"Append mode: Loading existing config from {existing_config_path}")
    else:
        with open(template_path, "r", encoding="utf-8") as f:
            config = json.load(f)
        print(f"Replace mode: Loading template from {template_path}")

    outbounds = config.setdefault("outbounds", [])
    used_tags = {
        outbound.get("tag")
        for outbound in outbounds
        if isinstance(outbound, dict) and isinstance(outbound.get("tag"), str)
    }

    try:
        parsed_outbounds = detect_and_parse_source(source_text, used_tags)
    except Exception as exc:
        print(f"Error: Failed to parse subscription: {exc}")
        sys.exit(1)

    if not parsed_outbounds:
        print("Error: No valid outbounds found in source.")
        sys.exit(1)

    existing_tags = {
        outbound.get("tag")
        for outbound in outbounds
        if isinstance(outbound, dict) and isinstance(outbound.get("tag"), str)
    }

    added_tags: List[str] = []
    added_count = 0

    existing_by_tag = {
        outbound.get("tag"): outbound
        for outbound in outbounds
        if isinstance(outbound, dict) and isinstance(outbound.get("tag"), str)
    }

    for outbound in parsed_outbounds:
        if not isinstance(outbound, dict):
            continue

        tag = outbound.get("tag")
        if not isinstance(tag, str) or not tag:
            continue

        if tag in existing_tags:
            existing_outbound = existing_by_tag.get(tag)
            if isinstance(existing_outbound, dict):
                merge_existing_group(existing_outbound, outbound)
            continue

        outbounds.append(outbound)
        existing_tags.add(tag)
        existing_by_tag[tag] = outbound
        added_tags.append(tag)
        added_count += 1

    merge_into_proxy_selector(
        config,
        [
            tag
            for tag in added_tags
            if tag not in {"direct", "block", "proxy"}
        ],
    )

    configure_common_fields(config)

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)

    skipped = len(parsed_outbounds) - added_count
    print(f"Config generated at {output_path}")
    print(f"Added {added_count} outbounds (skipped {max(skipped, 0)} duplicates)")


if __name__ == "__main__":
    main()
