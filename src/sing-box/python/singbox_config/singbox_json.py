import json
from typing import Any, Dict, List


def _extract_outbounds(source: Any) -> List[Dict[str, Any]]:
    if isinstance(source, list):
        raw = source
    elif isinstance(source, dict) and isinstance(source.get("outbounds"), list):
        raw = source["outbounds"]
    else:
        raise ValueError("JSON 输入必须是 outbounds 列表或包含 outbounds 的对象")
    if not all(isinstance(item, dict) for item in raw):
        raise ValueError("JSON 中的每个出站节点都必须是对象")
    return json.loads(json.dumps(raw))


def normalize_outbounds(source: Any) -> List[Dict[str, Any]]:
    outbounds = _extract_outbounds(source)
    tags = set()
    for index, outbound in enumerate(outbounds, 1):
        outbound_type = outbound.get("type")
        tag = outbound.get("tag")
        if not isinstance(outbound_type, str) or not outbound_type.strip():
            raise ValueError(f"出站节点 #{index} 缺少有效的 type")
        if not isinstance(tag, str) or not tag.strip():
            raise ValueError(f"出站节点 #{index} 缺少有效的 tag")
        if tag in tags:
            raise ValueError(f"出站节点 tag 重复：{tag}")
        tags.add(tag)

    if "direct" not in tags:
        outbounds.insert(0, {"type": "direct", "tag": "direct"})
        tags.add("direct")

    if "direct_company_dns" not in tags:
        direct_index = next(
            (index for index, item in enumerate(outbounds) if item.get("tag") == "direct"),
            -1,
        )
        outbounds.insert(
            direct_index + 1,
            {
                "type": "direct",
                "tag": "direct_company_dns",
                "domain_resolver": "company_dns",
            },
        )
        tags.add("direct_company_dns")

    selector = next(
        (item for item in outbounds if item.get("type") == "selector" and item.get("tag") == "proxy"),
        None,
    )
    candidates = [
        item["tag"]
        for item in outbounds
        if item.get("tag") not in {"direct", "direct_company_dns", "proxy"}
    ]
    if not candidates:
        candidates = ["direct"]
    if selector is None:
        selector = {"type": "selector", "tag": "proxy", "outbounds": candidates, "default": candidates[0]}
        outbounds.insert(1 if outbounds[0].get("tag") == "direct" else 0, selector)
    else:
        members = selector.get("outbounds")
        members = [
            tag
            for tag in members
            if isinstance(tag, str)
            and tag in tags
            and tag not in {"proxy", "direct_company_dns"}
        ] if isinstance(members, list) else []
        selector["outbounds"] = members or candidates
        if selector.get("default") not in selector["outbounds"]:
            selector["default"] = selector["outbounds"][0]
    return outbounds


def apply_replace(config: Dict[str, Any], source: Any) -> Dict[str, Any]:
    outbounds = normalize_outbounds(source)
    tags = {item["tag"] for item in outbounds}
    config["outbounds"] = outbounds
    route = config.setdefault("route", {})
    source_final = source.get("route", {}).get("final") if isinstance(source, dict) else None
    if isinstance(source_final, str) and source_final in tags:
        route["final"] = source_final
    elif "proxy" in tags:
        route["final"] = "proxy"
    else:
        route["final"] = "direct"
    return config
