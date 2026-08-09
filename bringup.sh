#!/usr/bin/env bash

set -Eeuo pipefail

readonly BRINGUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AUTO_LOGOUT=1
REINSTALL_SINGBOX=0
REUSE_SINGBOX=0
SUDO_KEEPALIVE_PID=""
SUBSCRIPTION_FILE="${SB_SUBSCRIPTION_FILE:-}"
SUBSCRIPTION_URL="${SB_SUBSCRIPTION_URL:-}"
SUBSCRIPTION_ARGS=()
SUBSCRIPTION_PROVIDED=0
if [[ -n "$SUBSCRIPTION_FILE" || -n "$SUBSCRIPTION_URL" ]]; then
    SUBSCRIPTION_PROVIDED=1
fi

log() {
    printf '\n[bringup] %s\n' "$*"
}

die() {
    printf '[bringup][ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
用法：bash bringup.sh [--no-logout] [--reinstall-sing-box]
                       [--subscription-file 文件|--subscription-url URL]

依次安装并配置 sing-box、Zsh、Fcitx 5/Rime、V4L 相机支持、pyenv/uv 和 Docker。
全部成功后默认自动注销一次；调试或远程执行时可用 --no-logout 跳过。
首次安装必须提供订阅；重新运行时会自动复用完整的 sing-box 安装和现有配置。
传入新订阅或 --reinstall-sing-box 可强制重新安装 sing-box。
EOF
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --no-logout)
                AUTO_LOGOUT=0
                ;;
            --reinstall-sing-box)
                REINSTALL_SINGBOX=1
                ;;
            --subscription-file)
                (( $# >= 2 )) || die "$1 需要文件路径"
                SUBSCRIPTION_FILE="$2"
                SUBSCRIPTION_PROVIDED=1
                shift
                ;;
            --subscription-url)
                (( $# >= 2 )) || die "$1 需要 URL"
                SUBSCRIPTION_URL="$2"
                SUBSCRIPTION_PROVIDED=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "未知参数：$1"
                ;;
        esac
        shift
    done
}

resolve_subscription() {
    [[ -z "$SUBSCRIPTION_FILE" || -z "$SUBSCRIPTION_URL" ]] || \
        die "订阅文件和订阅 URL 只能选择一种。"
    if [[ -n "$SUBSCRIPTION_FILE" ]]; then
        SUBSCRIPTION_FILE="${SUBSCRIPTION_FILE/#\~/$HOME}"
        [[ -f "$SUBSCRIPTION_FILE" ]] || die "未找到订阅文件：$SUBSCRIPTION_FILE"
        SUBSCRIPTION_ARGS=(--file "$SUBSCRIPTION_FILE")
        return
    fi
    if [[ -n "$SUBSCRIPTION_URL" ]]; then
        [[ "$SUBSCRIPTION_URL" == https://* ]] || die "订阅 URL 必须使用 HTTPS。"
        SUBSCRIPTION_ARGS=(--url "$SUBSCRIPTION_URL")
        return
    fi
    [[ -t 0 ]] || die "必须通过 --subscription-file、--subscription-url 或对应环境变量提供订阅。"
    read -r -p "请输入订阅文件路径或 HTTPS URL：" SUBSCRIPTION_URL
    if [[ "$SUBSCRIPTION_URL" == https://* ]]; then
        SUBSCRIPTION_ARGS=(--url "$SUBSCRIPTION_URL")
    else
        SUBSCRIPTION_FILE="${SUBSCRIPTION_URL/#\~/$HOME}"
        SUBSCRIPTION_URL=""
        [[ -f "$SUBSCRIPTION_FILE" ]] || die "未找到订阅文件：$SUBSCRIPTION_FILE"
        SUBSCRIPTION_ARGS=(--file "$SUBSCRIPTION_FILE")
    fi
}

singbox_installation_ready() {
    [[ -x "$HOME/.local/bin/sing-box" ]] &&
        [[ -x "$HOME/.local/bin/sb" ]] &&
        [[ -r "$HOME/.local/lib/sing-box/current/shell/vpn.sh" ]] &&
        [[ -s "$HOME/service/sing-box/config.json" ]] &&
        [[ -f "$HOME/.config/systemd/user/sing-box.service" ]]
}

prepare_singbox_step() {
    if (( REINSTALL_SINGBOX == 0 && SUBSCRIPTION_PROVIDED == 0 )) && singbox_installation_ready; then
        REUSE_SINGBOX=1
        SUBSCRIPTION_ARGS=()
        return
    fi
    REUSE_SINGBOX=0
    resolve_subscription
}

check_environment() {
    [[ "$(uname -s)" == "Linux" ]] || die "统一安装脚本目前仅支持 Linux。"
    [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"
    # shellcheck source=/etc/os-release
    source /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || die "统一安装脚本仅支持 Ubuntu（检测到：${ID:-未知}）。"
    (( EUID != 0 )) || die "请以普通登录用户运行本脚本；需要管理员权限时脚本会自动调用 sudo。"
    command -v sudo >/dev/null 2>&1 || die "未找到 sudo。"
}

start_sudo_keepalive() {
    log "集中请求一次管理员权限"
    sudo -v
    (
        while kill -0 "$$" 2>/dev/null; do
            sudo -n true >/dev/null 2>&1 || exit
            sleep 50
        done
    ) &
    SUDO_KEEPALIVE_PID="$!"
}

stop_sudo_keepalive() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        SUDO_KEEPALIVE_PID=""
    fi
}

run_step() {
    local number="$1" name="$2"
    shift 2
    log "[$number/6] 安装 $name"
    "$@"
}

ensure_singbox_service() {
    command -v systemctl >/dev/null 2>&1 || die "无法复用 sing-box：未找到 systemctl。"
    if ! systemctl --user is-active --quiet sing-box.service 2>/dev/null; then
        log "检测到 sing-box 已安装但服务未运行，正在重新启动"
        systemctl --user restart sing-box.service || \
            die "无法启动已有 sing-box 服务；请检查日志，或使用 --reinstall-sing-box 并重新提供订阅。"
    fi
    systemctl --user is-active --quiet sing-box.service 2>/dev/null || \
        die "已有 sing-box 服务启动后仍未进入 active 状态。"
}

enable_proxy_for_remaining_steps() {
    local helper="$HOME/.local/lib/sing-box/current/shell/vpn.sh"
    [[ -r "$helper" ]] || die "sing-box 已安装，但未找到代理环境脚本：$helper"
    # shellcheck source=/dev/null
    source "$helper"
    vpn_on
}

activate_zsh_configuration() {
    local zsh_path
    zsh_path="$(command -v zsh 2>/dev/null || true)"
    [[ -n "$zsh_path" ]] || die "Zsh 安装后仍不可用。"
    export SHELL="$zsh_path"
    export BRINGUP_SHELL=zsh
    "$zsh_path" -lic 'true'
    log "Zsh 登录配置已激活；后续 Shell 配置将写入 ~/.zshrc。"
}

logout_once() {
    (( AUTO_LOGOUT == 1 )) || {
        log "已按 --no-logout 跳过注销；请稍后手动注销并重新登录一次。"
        return
    }

    log "全部安装完成，即将注销当前桌面会话以一次性应用 Shell、输入法和 Docker 用户组设置"
    sleep 5
    stop_sudo_keepalive

    if command -v gnome-session-quit >/dev/null 2>&1 && [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        if gnome-session-quit --logout --no-prompt; then
            return
        fi
        log "GNOME 注销请求失败，尝试通过 systemd-logind 注销当前会话。"
    fi
    if command -v loginctl >/dev/null 2>&1 && [[ -n "${XDG_SESSION_ID:-}" ]]; then
        if loginctl terminate-session "$XDG_SESSION_ID"; then
            return
        fi
    fi

    die "无法自动识别桌面会话。请手动注销并重新登录一次。"
}

main() {
    parse_args "$@"
    check_environment
    prepare_singbox_step
    start_sudo_keepalive
    trap stop_sudo_keepalive EXIT INT TERM

    if (( REUSE_SINGBOX )); then
        log "[1/5] 复用已完成的 sing-box 安装和现有订阅配置"
        ensure_singbox_service
        enable_proxy_for_remaining_steps
    fi

    log "安装共用系统依赖"
    bash "$BRINGUP_DIR/install-apt-dependencies.sh"

    if (( REUSE_SINGBOX == 0 )); then
        run_step 1 "sing-box" bash "$BRINGUP_DIR/sing-box/installer/install.sh" "${SUBSCRIPTION_ARGS[@]}"
        enable_proxy_for_remaining_steps
    fi

    run_step 2 "Zsh Shell 环境" bash "$BRINGUP_DIR/shell/set_zsh.sh"
    activate_zsh_configuration

    run_step 3 "Fcitx 5 + Rime 输入法" bash "$BRINGUP_DIR/input-method/install.sh"
    run_step 4 "V4L 相机支持和 video 组权限" bash "$BRINGUP_DIR/camera/install.sh"
    run_step 5 "pyenv + uv" env BRINGUP_SHELL=zsh bash "$BRINGUP_DIR/conda/set_pyenv.sh"
    run_step 6 "Docker Engine" bash "$BRINGUP_DIR/docker-install/install.sh"

    logout_once
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
