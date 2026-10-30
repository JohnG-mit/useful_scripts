#!/usr/bin/env bash
# One-step installer for the user-level mihomo service (replaces the sing-box setup).
set -e

MO_GH_PROXY_USER_SET="${MO_GH_PROXY+set}"
MO_INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MO_SOURCE_DIR="$(cd "$MO_INSTALLER_DIR/.." && pwd)"
MO_RUNTIME_DIR="$MO_SOURCE_DIR"
export MO_RUNTIME_DIR

# shellcheck source=/dev/null
for MO_MODULE in core artifacts service subscription cron desktop-proxy apt-proxy; do
    source "$MO_SOURCE_DIR/modules/$MO_MODULE.sh"
done
unset MO_MODULE
# shellcheck source=/dev/null
source "$MO_INSTALLER_DIR/user-environment.sh"
# shellcheck source=/dev/null
source "$MO_INSTALLER_DIR/systemd.sh"

mo_install_usage() {
    cat <<'EOF'
用法：bash install.sh [选项]

选项：
  -u, --url URL        订阅 URL
  -f, --file 文件      本地订阅/yaml 文件
      --keep-singbox   不停用现有 sing-box（mihomo 将自动选择其他端口）
      --no-apt         不配置 APT 代理
      --no-desktop     不配置 GNOME 桌面代理
  -h, --help           显示帮助

环境变量：
  MO_GH_PROXY          GitHub 镜像前缀（默认 https://cdn.gh-proxy.org/，设为空则直连）
  MO_VERSION           指定核心版本（默认最新）
  MO_FORCE_CORE=1      重新下载核心 / MO_FORCE_UI=1 重新下载面板
  MO_CONFIGURE_APT_PROXY=0|1、MO_CONFIGURE_DESKTOP_PROXY=0|1
EOF
}

MO_ARGS_SUB=()
MO_DISABLE_SINGBOX="${MO_DISABLE_SINGBOX:-1}"

mo_install_parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -u|--url) [ "$#" -ge 2 ] || { mo_error "$1 需要参数值"; exit 2; }; MO_ARGS_SUB=(--url "$2"); shift 2 ;;
            -f|--file) [ "$#" -ge 2 ] || { mo_error "$1 需要参数值"; exit 2; }; MO_ARGS_SUB=(--file "$2"); shift 2 ;;
            --keep-singbox) MO_DISABLE_SINGBOX=0; shift ;;
            --no-apt) MO_CONFIGURE_APT_PROXY=0; shift ;;
            --no-desktop) MO_CONFIGURE_DESKTOP_PROXY=0; shift ;;
            -h|--help) mo_install_usage; exit 0 ;;
            *) mo_error "未知参数：$1"; mo_install_usage; exit 2 ;;
        esac
    done
}

mo_install_check_environment() {
    [ "$(uname -s)" = Linux ] || { mo_error "仅支持 Linux"; exit 1; }
    [ "$(id -u)" -ne 0 ] || { mo_error "请以普通用户运行（需要管理员权限时会调用 sudo）"; exit 1; }
    local cmd
    for cmd in systemctl curl gzip tar install; do
        mo_require_command "$cmd" || exit 1
    done
    mo_ensure_user_systemd_env
    systemctl --user show-environment >/dev/null 2>&1 || {
        mo_error "无法连接用户级 systemd 会话（请在登录的桌面/SSH 会话中运行，或先执行 loginctl enable-linger）"
        exit 1
    }
    if ! mo_select_python 2>/dev/null; then
        mo_warn "未找到带 PyYAML 的 Python 3，尝试安装 python3-yaml"
        if command -v apt-get >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
            sudo apt-get install -y python3-yaml || true
        fi
        mo_select_python || exit 1
    fi
    MO_PYTHON="$(command -v "$MO_PYTHON" 2>/dev/null || printf '%s' "$MO_PYTHON")"
    export MO_PYTHON
}

mo_install_persist_settings() {
    mo_user_config_set MO_PYTHON "$MO_PYTHON"
    if [ -n "$MO_GH_PROXY_USER_SET" ]; then
        mo_user_config_set MO_GH_PROXY "$MO_GH_PROXY"
    fi
}

mo_install_disable_singbox() {
    [ "$MO_DISABLE_SINGBOX" != 0 ] || { mo_log "保留 sing-box（--keep-singbox）"; return 0; }
    local unit stopped=0
    for unit in sing-box.service sing-box-log-rotate.timer; do
        if systemctl --user cat "$unit" >/dev/null 2>&1; then
            systemctl --user disable --now "$unit" 2>/dev/null || true
            stopped=1
        fi
    done
    [ "$stopped" = 0 ] || mo_log "已停用 sing-box 用户服务（文件已保留，可通过 mo uninstall 恢复）"
    mo_user_disable_singbox_rc
}

mo_install_runtime() {
    local release previous link
    release="$MO_RUNTIME_BASE/releases/$(date +%Y%m%d_%H%M%S).$$"
    mkdir -p "$release"/{cli,modules,python,shell,resources} "$MO_BIN_DIR"
    cp -R "$MO_SOURCE_DIR/modules/." "$release/modules/"
    cp -R "$MO_SOURCE_DIR/python/." "$release/python/"
    find "$release/python" -name __pycache__ -type d -prune -exec rm -rf {} +
    cp -R "$MO_SOURCE_DIR/shell/." "$release/shell/"
    install -m 755 "$MO_SOURCE_DIR/cli/mo" "$release/cli/mo"
    install -m 644 "$MO_SOURCE_DIR/resources/config-template.yaml" "$release/resources/config-template.yaml"
    install -m 644 "$MO_SOURCE_DIR/resources/override.yaml" "$release/resources/override.yaml"
    previous="$(readlink "$MO_RUNTIME_BASE/current" 2>/dev/null || true)"
    link="$MO_RUNTIME_BASE/.current.$$"
    ln -s "$release" "$link"
    mv -Tf "$link" "$MO_RUNTIME_BASE/current"
    [ -z "$previous" ] || ln -sfn "$previous" "$MO_RUNTIME_BASE/previous"
    install -m 755 "$MO_SOURCE_DIR/cli/mo" "$MO_BIN_DIR/mo.new.$$"
    mv -f "$MO_BIN_DIR/mo.new.$$" "$MO_BIN_DIR/mo"
    MO_RUNTIME_DIR="$MO_RUNTIME_BASE/current"
    export MO_RUNTIME_DIR
    # Keep only the five newest releases (never the active/previous ones).
    local keep_current keep_previous old count=0
    keep_current="$(readlink "$MO_RUNTIME_BASE/current" 2>/dev/null || true)"
    keep_previous="$(readlink "$MO_RUNTIME_BASE/previous" 2>/dev/null || true)"
    # shellcheck disable=SC2012
    for old in $(ls -1dt "$MO_RUNTIME_BASE"/releases/* 2>/dev/null); do
        count=$((count + 1))
        [ "$count" -gt 5 ] || continue
        [ "$old" != "$keep_current" ] && [ "$old" != "$keep_previous" ] || continue
        rm -rf "$old"
    done
}

mo_install_core() {
    if [ -x "$MO_BINARY" ] && [ -n "$(mo_current_version 2>/dev/null)" ] && [ "${MO_FORCE_CORE:-0}" != 1 ]; then
        mo_log "已安装 mihomo $(mo_current_version)，跳过下载（升级请执行 mo upgrade）"
        return 0
    fi
    mo_artifact_install_core "$MO_BINARY"
}

mo_install_ui() {
    # A different panel (e.g. an older metacubexd install) has no matching marker and is replaced.
    if [ -f "$MO_UI_DIR/index.html" ] && [ "$(cat "$MO_UI_DIR/.mo-panel" 2>/dev/null)" = "$MO_UI_NAME" ] && [ "${MO_FORCE_UI:-0}" != 1 ]; then
        mo_log "已安装 zashboard 面板，跳过下载"
        return 0
    fi
    mo_artifact_install_ui "$MO_UI_DIR" || mo_warn "zashboard 面板下载失败，Web 面板暂不可用（可设置 MO_FORCE_UI=1 重新运行安装）"
}

# Fresh installs choose free ports and a random secret; reruns keep the existing values.
mo_install_init_override() {
    local fresh=0 mixed api secret
    mkdir -p "$MO_WORK_DIR/providers"
    chmod 700 "$MO_WORK_DIR"
    [ -f "$MO_OVERRIDE_FILE" ] || fresh=1
    mo_pyconfig override-init "$MO_OVERRIDE_FILE" "$MO_RUNTIME_DIR/resources/override.yaml"
    if [ "$fresh" = 1 ]; then
        mixed="$(mo_find_available_port "$MO_DEFAULT_MIXED_PORT")"
        api="$(mo_find_available_port "$MO_DEFAULT_API_PORT")"
        mo_pyconfig override-set "$MO_OVERRIDE_FILE" "mixed-port=$mixed" "external-controller=127.0.0.1:$api"
        mo_log "使用混合代理端口 $mixed，面板/API 端口 $api"
    fi
    if [ -z "$(mo_pyconfig override-get "$MO_OVERRIDE_FILE" secret 2>/dev/null || true)" ]; then
        secret="$("$MO_PYTHON" -c 'import secrets; print(secrets.token_hex(16))')"
        mo_pyconfig override-set "$MO_OVERRIDE_FILE" "secret=$secret"
    fi
}

mo_install_subscription() {
    if [ "${#MO_ARGS_SUB[@]}" -gt 0 ]; then
        mo_subscription_update --no-restart "${MO_ARGS_SUB[@]}"
    elif [ -f "$MO_SOURCE_FILE" ]; then
        mo_log "复用已保存的订阅源"
        mo_subscription_update --saved --no-restart
    elif [ -t 0 ]; then
        mo_subscription_update --no-restart
    else
        mo_error "必须通过 --url 或 --file 提供订阅"
        exit 2
    fi
}

mo_install_main() {
    local configure_apt configure_desktop
    mo_install_parse_args "$@"
    export PATH="$MO_BIN_DIR:$PATH"
    mo_install_check_environment
    mkdir -p "$MO_BIN_DIR" "$MO_RUNTIME_BASE/releases" "$MO_WORK_DIR"
    chmod 700 "$MO_WORK_DIR"
    mo_install_persist_settings

    mo_log "[1/8] 停用 sing-box"
    mo_install_disable_singbox
    mo_log "[2/8] 安装运行环境与 mo 命令"
    mo_install_runtime
    mo_log "[3/8] 安装 mihomo 核心与 Web 面板"
    mo_install_core
    mo_install_ui
    mo_log "[4/8] 初始化本地配置"
    mo_install_init_override
    mo_log "[5/8] 导入订阅并生成配置"
    mo_install_subscription
    mo_log "[6/8] 注册用户级服务并设置开机自启"
    mo_install_systemd_units
    mo_install_linger
    mo_log "[7/8] 配置 Shell（mo / vpn_on / vpn_off / vpn_s）"
    mo_user_configure_shell

    mo_log "[8/8] 系统代理集成"
    configure_apt="${MO_CONFIGURE_APT_PROXY:-}"
    if [ -z "$configure_apt" ]; then
        if [ -t 0 ] && [ -t 1 ]; then
            mo_confirm "是否使用 sudo 将 APT 代理写入 $MO_APT_PROXY_CONFIG？" Y && configure_apt=1 || configure_apt=0
        else
            configure_apt=1
        fi
    fi
    if [ "$configure_apt" != 0 ]; then
        mo_apt_proxy_enable || mo_warn "未配置 APT 代理，可稍后执行 mo apt on"
    else
        mo_log "已跳过 APT 代理配置"
        mo_apt_proxy_remove_legacy || true
    fi
    configure_desktop="${MO_CONFIGURE_DESKTOP_PROXY:-1}"
    if [ "$configure_desktop" != 0 ]; then
        mo_desktop_proxy_enable || mo_warn "未配置 GNOME 桌面代理，可在桌面会话中执行 mo desktop on"
    fi

    mo_log "安装完成。"
    printf '  命令帮助：mo h（直接输入 mo 进入菜单）\n'
    printf '  Web 面板：%s\n' "$(MO_RUNTIME_DIR="$MO_RUNTIME_DIR" "$MO_BIN_DIR/mo" ui --print-only 2>/dev/null | sed 's/^本地面板 URL：//')"
    printf '  请重新打开终端，或执行：exec "$SHELL" -l\n'
}

mo_install_main "$@"
