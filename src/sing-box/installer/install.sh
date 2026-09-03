#!/usr/bin/env bash
set -e

SB_INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB_SOURCE_DIR="$(cd "$SB_INSTALLER_DIR/.." && pwd)"
SB_RUNTIME_DIR="$SB_SOURCE_DIR"
export SB_RUNTIME_DIR

# shellcheck source=/dev/null
source "$SB_SOURCE_DIR/modules/core.sh"
# shellcheck source=/dev/null
source "$SB_SOURCE_DIR/modules/artifacts.sh"
# shellcheck source=/dev/null
source "$SB_SOURCE_DIR/modules/service.sh"
# shellcheck source=/dev/null
source "$SB_SOURCE_DIR/modules/subscription.sh"
# shellcheck source=/dev/null
source "$SB_SOURCE_DIR/modules/desktop-proxy.sh"
# shellcheck source=/dev/null
source "$SB_INSTALLER_DIR/apt-proxy.sh"
# shellcheck source=/dev/null
source "$SB_INSTALLER_DIR/user-environment.sh"
# shellcheck source=/dev/null
source "$SB_INSTALLER_DIR/systemd.sh"

sb_install_runtime() {
    local release previous link legacy
    release="$SB_RUNTIME_BASE/releases/$(date +%Y%m%d_%H%M%S).$$"
    mkdir -p "$release"/{cli,modules,python,shell,resources} "$SB_BIN_DIR"
    cp -R "$SB_SOURCE_DIR/modules/." "$release/modules/"
    cp -R "$SB_SOURCE_DIR/python/." "$release/python/"
    cp -R "$SB_SOURCE_DIR/shell/." "$release/shell/"
    install -m 755 "$SB_SOURCE_DIR/cli/sb" "$release/cli/sb"
    install -m 644 "$SB_SOURCE_DIR/resources/config-template.json" "$release/resources/config-template.json"
    install -m 644 "$SB_SOURCE_DIR/resources/artifacts.lock" "$release/resources/artifacts.lock"
    previous="$(readlink "$SB_RUNTIME_BASE/current" 2>/dev/null || true)"
    link="$SB_RUNTIME_BASE/.current.$$"
    ln -s "$release" "$link"
    if [ -d "$SB_RUNTIME_BASE/current" ] && [ ! -L "$SB_RUNTIME_BASE/current" ]; then
        legacy="$SB_RUNTIME_BASE/.current-legacy.$$"
        mv "$SB_RUNTIME_BASE/current" "$legacy"
        sb_warn "发现旧版 current 目录，已保留为：$legacy"
    fi
    mv -Tf "$link" "$SB_RUNTIME_BASE/current"
    [ -z "$previous" ] || ln -sfn "$previous" "$SB_RUNTIME_BASE/previous"
    install -m 755 "$SB_SOURCE_DIR/cli/sb" "$SB_BIN_DIR/sb"
    install -m 755 "$SB_SOURCE_DIR/modules/log-rotation.sh" "$SB_BIN_DIR/sing-box-log-rotate"
    SB_RUNTIME_DIR="$SB_RUNTIME_BASE/current"
    SB_CONFIG_TEMPLATE="$SB_RUNTIME_DIR/resources/config-template.json"
    SB_ARTIFACT_LOCK="$SB_RUNTIME_DIR/resources/artifacts.lock"
    export SB_RUNTIME_DIR SB_CONFIG_TEMPLATE SB_ARTIFACT_LOCK
}

sb_install_binary() {
    sb_artifact_install_core "$SB_BINARY"
}

sb_install_assign_ports() {
    local mixed api candidate
    mixed="$(sb_find_available_port 7897)"; api="$(sb_find_available_port 9090)"
    candidate="$(mktemp "${TMPDIR:-/tmp}/sing-box-config.XXXXXX")"
    "$SB_PYTHON" - "$SB_CONFIG_FILE" "$candidate" "$mixed" "$api" <<'PY'
import json, sys
source, output, mixed, api_port = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
with open(source, "r", encoding="utf-8") as f: data=json.load(f)
for inbound in data.get("inbounds", []):
    if inbound.get("type") == "mixed": inbound["listen_port"] = mixed; break
api = data.setdefault("experimental", {}).setdefault("clash_api", {})
controller = api.get("external_controller", "127.0.0.1:9090")
host, sep, _ = controller.rpartition(":")
api["external_controller"] = f"{host if sep else '127.0.0.1'}:{api_port}"
with open(output, "w", encoding="utf-8") as f: json.dump(data, f, indent=2, ensure_ascii=False)
PY
    sb_subscription_check_generated "$candidate" || { rm -f "$candidate"; return 1; }
    install -m 600 "$candidate" "$SB_CONFIG_FILE.new"; mv "$SB_CONFIG_FILE.new" "$SB_CONFIG_FILE"; rm -f "$candidate"
    sb_log "使用 mixed 端口 $mixed，Clash API 端口 $api"
}

sb_install_set_default_proxy() {
    local group="${SB_DEFAULT_PROXY_GROUP:-}" node="${SB_DEFAULT_PROXY_NODE:-}" candidate selected
    [ -n "$node" ] || return 0

    group="${group:-proxy}"
    candidate="$(mktemp "${TMPDIR:-/tmp}/sing-box-config.XXXXXX")"
    if ! selected="$("$SB_PYTHON" - "$SB_CONFIG_FILE" "$candidate" "$group" "$node" <<'PY'
import json
import sys

source, output, group, requested = sys.argv[1:]
with open(source, "r", encoding="utf-8") as config_file:
    data = json.load(config_file)

selector = next(
    (
        outbound
        for outbound in data.get("outbounds", [])
        if outbound.get("type") == "selector" and outbound.get("tag") == group
    ),
    None,
)
if selector is None:
    raise SystemExit(f"未找到代理组：{group}")

members = [member for member in selector.get("outbounds", []) if isinstance(member, str)]
matches = [member for member in members if member == requested]
if not matches:
    matches = [member for member in members if member.endswith(requested)]
if len(matches) != 1:
    raise SystemExit(f"代理组 {group} 中无法唯一匹配默认节点：{requested}")

selector["default"] = matches[0]
with open(output, "w", encoding="utf-8") as config_file:
    json.dump(data, config_file, indent=2, ensure_ascii=False)
    config_file.write("\n")
print(matches[0])
PY
)"; then
        rm -f "$candidate"
        return 1
    fi

    sb_subscription_check_generated "$candidate" || { rm -f "$candidate"; return 1; }
    install -m 600 "$candidate" "$SB_CONFIG_FILE.new"
    mv "$SB_CONFIG_FILE.new" "$SB_CONFIG_FILE"
    rm -f "$candidate"
    sb_log "代理组 $group 的默认节点已设置为：$selected"
}

sb_install_main() {
    local configure_apt_proxy answer
    export PATH="$SB_BIN_DIR:$PATH"
    mkdir -p "$SB_BIN_DIR" "$SB_RUNTIME_BASE/releases" "$SB_WORK_DIR"
    chmod 700 "$SB_WORK_DIR"
    if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet "$SB_SERVICE_NAME" 2>/dev/null; then
        systemctl --user stop "$SB_SERVICE_NAME"
    fi
    sb_install_runtime
    sb_install_binary
    sb_artifact_install_ui "$SB_WORK_DIR/ui" || sb_warn "Zashboard 下载或校验失败，管理面板暂不可用"
    sb_user_configure_path
    sb_user_configure_vpn
    "$SB_BIN_DIR/sb" subscription update --replace --no-restart "$@"
    sb_install_set_default_proxy
    sb_install_assign_ports
    sb_install_systemd_units
    configure_apt_proxy="${SB_CONFIGURE_APT_PROXY:-1}"
    if [ -t 0 ] && [ -t 1 ] && [ -z "${SB_CONFIGURE_APT_PROXY+x}" ]; then
        printf '是否使用 sudo 将 APT 代理写入 %s？[Y/n] ' "$SB_APT_PROXY_CONFIG"
        IFS= read -r answer || answer=''
        case "$answer" in
            [Nn]|[Nn][Oo]) configure_apt_proxy=0 ;;
        esac
    fi
    if [ "$configure_apt_proxy" != 0 ]; then
        sb_apt_proxy_enable || sb_warn "未配置 APT 代理；可在重新安装时授权 sudo，或设置 SB_CONFIGURE_APT_PROXY=0 跳过"
    else
        sb_log "已跳过 APT 代理配置"
    fi
    if [ "${SB_CONFIGURE_DESKTOP_PROXY:-1}" != 0 ]; then
        sb_desktop_proxy_enable || sb_warn "未配置 GNOME 桌面代理，请在桌面会话中运行 'sb desktop-proxy enable'"
    fi
    sb_log "安装完成。查看帮助：sb help"
    sb_log "重新加载 Shell 后可使用 vpn_on、vpn_off 和 vpn_status"
}

sb_install_main "$@"
