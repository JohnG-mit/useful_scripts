#!/usr/bin/env bash

sb_proxy_list() {
    sb_require_config && sb_select_python || return
    "$SB_PYTHON" - "$SB_CONFIG_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
selector = next((x for x in data.get("outbounds", [])
                 if x.get("type") == "selector" and x.get("tag") == "proxy"), None)
if selector is None:
    print("未找到 proxy 选择器", file=sys.stderr)
    raise SystemExit(1)
candidates = list(dict.fromkeys(x for x in selector.get("outbounds", []) if isinstance(x, str)))
if not candidates:
    print("proxy 选择器中没有候选节点", file=sys.stderr)
    raise SystemExit(1)
current = selector.get("default")
if current not in candidates:
    current = candidates[0]
print(f"当前节点：{current}")
print("可用节点：")
for index, tag in enumerate(candidates, 1):
    marker = "（当前）" if tag == current else ""
    print(f"  {index}) {tag}{marker}")
PY
}

sb_proxy_use() {
    local target="${1:-}" candidate selected
    [ -n "$target" ] || { sb_error "用法：sb proxy use 标签或序号"; return 2; }
    sb_require_config && sb_select_python || return
    candidate="$(mktemp "${TMPDIR:-/tmp}/sing-box-config.XXXXXX")"
    if ! selected="$("$SB_PYTHON" - "$SB_CONFIG_FILE" "$candidate" "$target" <<'PY'
import json
import sys
source, output, target = sys.argv[1:]
with open(source, "r", encoding="utf-8") as f:
    data = json.load(f)
selector = next((x for x in data.get("outbounds", [])
                 if x.get("type") == "selector" and x.get("tag") == "proxy"), None)
if selector is None:
    raise SystemExit("未找到 proxy 选择器")
candidates = list(dict.fromkeys(x for x in selector.get("outbounds", []) if isinstance(x, str)))
selected = candidates[int(target) - 1] if target.isdigit() and 0 < int(target) <= len(candidates) else target
if selected not in candidates:
    raise SystemExit(f"未知代理节点：{target}")
selector["default"] = selected
with open(output, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print(selected)
PY
)"; then
        rm -f "$candidate"
        return 1
    fi
    sb_subscription_check_generated "$candidate" || { rm -f "$candidate"; return 1; }
    install -m 600 "$candidate" "$SB_CONFIG_FILE.new"
    mv "$SB_CONFIG_FILE.new" "$SB_CONFIG_FILE"
    rm -f "$candidate"
    sb_service_restart || return
    sb_log "默认代理已切换为：$selected"
}
