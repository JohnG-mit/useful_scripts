#!/usr/bin/env bash

sb_proxy_ip() {
    sb_service_require_running && sb_require_command curl && sb_select_python || return
    sb_set_proxy_env
    local response
    response="$(curl -fsSL --max-time 15 https://ipapi.co/json/ 2>/dev/null || true)"
    [ -n "$response" ] || response="$(curl -fsSL --max-time 15 https://ipinfo.io/json 2>/dev/null || true)"
    [ -n "$response" ] || { sb_error "获取代理 IP 信息失败"; return 1; }
    IP_JSON="$response" "$SB_PYTHON" <<'PY'
import json
import os
data = json.loads(os.environ["IP_JSON"])
print(f"IP：{data.get('ip') or data.get('query') or '未知'}")
country = data.get("country_name") or data.get("country") or "未知"
region = data.get("region") or data.get("regionName") or "未知"
print(f"位置：{country} / {region} / {data.get('city') or '未知'}")
print(f"运营商：{data.get('org') or data.get('organization') or '未知'}")
PY
}

sb_speedtest_arch() {
    case "$(uname -m)" in
        i386|i686) echo i386 ;;
        x86_64|amd64) echo x86_64 ;;
        armv6l) echo armel ;;
        armv7l|armhf) echo armhf ;;
        aarch64|arm64) echo aarch64 ;;
        *) sb_error "speedtest 不支持此架构：$(uname -m)"; return 1 ;;
    esac
}

sb_ensure_speedtest() {
    if command -v speedtest >/dev/null 2>&1; then command -v speedtest; return; fi
    if command -v speedtest-cli >/dev/null 2>&1; then command -v speedtest-cli; return; fi
    sb_require_command curl && sb_require_command tar || return
    local temp_dir archive binary arch
    arch="$(sb_speedtest_arch)" || return
    temp_dir="$(sb_make_temp_dir)"; archive="$temp_dir/speedtest.tgz"
    sb_log "正在下载 Ookla speedtest..." >&2
    curl -fsSL "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-$arch.tgz" -o "$archive" || { rm -rf "$temp_dir"; return 1; }
    tar -xzf "$archive" -C "$temp_dir" || { rm -rf "$temp_dir"; return 1; }
    binary="$(find "$temp_dir" -type f -name speedtest | head -n1)"
    [ -n "$binary" ] || { rm -rf "$temp_dir"; sb_error "未找到 speedtest 二进制文件"; return 1; }
    install -d "$SB_BIN_DIR"
    install -m 755 "$binary" "$SB_BIN_DIR/speedtest"
    rm -rf "$temp_dir"
    printf '%s\n' "$SB_BIN_DIR/speedtest"
}

sb_proxy_speedtest() {
    sb_service_require_running && sb_select_python || return
    sb_set_proxy_env
    local command output mode
    command="$(sb_ensure_speedtest)" || return
    if output="$("$command" --accept-license --accept-gdpr -f json 2>/dev/null)"; then
        mode=ookla
    elif output="$("$command" --json 2>/dev/null)"; then
        mode=legacy
    else
        sb_error "speedtest 测速失败"; return 1
    fi
    SPEEDTEST_JSON="$output" "$SB_PYTHON" - "$mode" <<'PY'
import json, os, sys
data = json.loads(os.environ["SPEEDTEST_JSON"])
if sys.argv[1] == "legacy":
    ping, down, up = data.get("ping"), data.get("download", 0), data.get("upload", 0)
    server = (data.get("server") or {}).get("sponsor", "未知")
else:
    ping = (data.get("ping") or {}).get("latency")
    down = (data.get("download") or {}).get("bandwidth", 0) * 8
    up = (data.get("upload") or {}).get("bandwidth", 0) * 8
    server = (data.get("server") or {}).get("name", "未知")
print(f"服务器：{server}")
print("延迟：未知" if ping is None else f"延迟：{float(ping):.2f} ms")
print(f"下载：{down / 1_000_000:.2f} Mbps")
print(f"上传：{up / 1_000_000:.2f} Mbps")
PY
}
