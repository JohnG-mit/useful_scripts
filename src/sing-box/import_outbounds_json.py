#!/usr/bin/env python3

"""Import useful outbound-related fields from a JSON file into sing-box config."""

import json
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(f"Error: {message}", file=sys.stderr)
    sys.exit(1)


def load_json(path: Path):
    try:
        with path.open("r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        fail(f"File not found: {path}")
    except json.JSONDecodeError as exc:
        fail(f"Invalid JSON in {path}: {exc}")


def extract_outbounds(source):
    if isinstance(source, list):
        return source

    if isinstance(source, dict) and isinstance(source.get("outbounds"), list):
        return source["outbounds"]

    fail("Input JSON must be an object with an 'outbounds' list, or a list of outbound objects")


def normalize_outbounds(raw_outbounds):
    normalized = []
    tags = set()

    for idx, outbound in enumerate(raw_outbounds, start=1):
        if not isinstance(outbound, dict):
            fail(f"Outbound #{idx} is not a JSON object")

        outbound_type = outbound.get("type")
        outbound_tag = outbound.get("tag")

        if not isinstance(outbound_type, str) or not outbound_type.strip():
            fail(f"Outbound #{idx} is missing a valid 'type'")

        if not isinstance(outbound_tag, str) or not outbound_tag.strip():
            fail(f"Outbound #{idx} is missing a valid 'tag'")

        if outbound_tag in tags:
            fail(f"Duplicate outbound tag found: {outbound_tag}")

        normalized.append(outbound)
        tags.add(outbound_tag)

    if not normalized:
        fail("No valid outbounds found in input JSON")

    if "direct" not in tags:
        normalized.insert(0, {"type": "direct", "tag": "direct"})
        tags.add("direct")

    proxy_selector = None
    for outbound in normalized:
        if outbound.get("type") == "selector" and outbound.get("tag") == "proxy":
            proxy_selector = outbound
            break

    candidate_tags = [
        outbound.get("tag")
        for outbound in normalized
        if outbound.get("tag") not in {"direct", "proxy"}
    ]

    if not candidate_tags:
        candidate_tags = ["direct"]

    if proxy_selector is None:
        proxy_selector = {
            "type": "selector",
            "tag": "proxy",
            "outbounds": candidate_tags,
            "default": candidate_tags[0],
        }
        insert_index = 1 if normalized and normalized[0].get("tag") == "direct" else 0
        normalized.insert(insert_index, proxy_selector)
        tags.add("proxy")
    else:
        raw_selector_outbounds = proxy_selector.get("outbounds")
        selector_outbounds = []

        if isinstance(raw_selector_outbounds, list):
            selector_outbounds = [
                tag
                for tag in raw_selector_outbounds
                if isinstance(tag, str) and tag in tags and tag != "proxy"
            ]

        if not selector_outbounds:
            selector_outbounds = candidate_tags

        proxy_selector["outbounds"] = selector_outbounds

        default_tag = proxy_selector.get("default")
        if not isinstance(default_tag, str) or default_tag not in selector_outbounds:
            proxy_selector["default"] = selector_outbounds[0]

    return normalized


def apply_source_to_template(template, source):
    outbounds = normalize_outbounds(extract_outbounds(source))
    outbound_tags = {
        outbound.get("tag")
        for outbound in outbounds
        if isinstance(outbound, dict) and isinstance(outbound.get("tag"), str)
    }

    template["outbounds"] = outbounds

    if not isinstance(template.get("route"), dict):
        template["route"] = {}

    route_final = None
    if isinstance(source, dict) and isinstance(source.get("route"), dict):
        route_final = source["route"].get("final")

    if isinstance(route_final, str) and route_final in outbound_tags:
        template["route"]["final"] = route_final
    elif "proxy" in outbound_tags:
        template["route"]["final"] = "proxy"
    elif "direct" in outbound_tags:
        template["route"]["final"] = "direct"

    return template


def main():
    if len(sys.argv) != 4:
        print(
            "Usage: python3 import_outbounds_json.py <template_path> <source_json_path> <output_path>",
            file=sys.stderr,
        )
        sys.exit(1)

    template_path = Path(sys.argv[1])
    source_path = Path(sys.argv[2])
    output_path = Path(sys.argv[3])

    template_data = load_json(template_path)
    source_data = load_json(source_path)

    if not isinstance(template_data, dict):
        fail("Template JSON root must be an object")

    merged_config = apply_source_to_template(template_data, source_data)

    with output_path.open("w", encoding="utf-8") as f:
        json.dump(merged_config, f, indent=2, ensure_ascii=False)

    outbound_count = len(merged_config.get("outbounds", []))
    print(f"Config generated at {output_path} (outbounds: {outbound_count})")


if __name__ == "__main__":
    main()
