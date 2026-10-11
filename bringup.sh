#!/usr/bin/env bash

# One-click, idempotent environment bring-up.
# Order: sing-box -> zsh -> pyenv/uv -> Codex CLI -> cc-switch-cli
# Re-running after a mid-step failure skips completed stages.

set -Eeuo pipefail

readonly BRINGUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SRC_DIR="$BRINGUP_DIR/src"
readonly STATE_DIR="${BRINGUP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/useful_scripts/bringup}"

AUTO_LOGOUT=0
REINSTALL_SINGBOX=0
FORCE_ALL=0
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
用法：bash bringup.sh [选项]

依次安装并配置：
  1. sing-box 用户态服务
  2. Zsh / Oh My Zsh
  3. pyenv + uv
  4. Codex CLI
  5. cc-switch-cli

各环节与本脚本均幂等：已完成的步骤会自动跳过，中途失败后可直接重跑。

选项：
  --subscription-file 文件   首次安装 sing-box 时使用的订阅文件
  --subscription-url URL     首次安装 sing-box 时使用的 HTTPS 订阅 URL
  --reinstall-sing-box       强制重新安装 sing-box（需同时提供订阅）
  --force                    忽略完成标记，强制重跑 zsh / pyenv / codex / cc-switch
  --logout                   全部成功后注销当前会话一次
  --no-logout                不注销（默认）
  -h, --help                 显示帮助

环境变量：
  SB_SUBSCRIPTION_FILE / SB_SUBSCRIPTION_URL  等价于对应命令行选项
  BRINGUP_STATE_DIR                           完成标记目录（默认 ~/.local/state/useful_scripts/bringup）
EOF
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --no-logout)
                AUTO_LOGOUT=0
                ;;
            --logout)
                AUTO_LOGOUT=1
                ;;
            --reinstall-sing-box)
                REINSTALL_SINGBOX=1
                ;;
            --force)
                FORCE_ALL=1
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

mark_done() {
    local step="$1"
    mkdir -p "$STATE_DIR"
    touch "$STATE_DIR/${step}.done"
}

step_marked_done() {
    local step="$1"
    [[ -f "$STATE_DIR/${step}.done" ]]
}

clear_step_mark() {
    local step="$1"
    rm -f "$STATE_DIR/${step}.done"
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
    local input=""
    read -r -p "请输入订阅文件路径或 HTTPS URL：" input
    if [[ "$input" == https://* ]]; then
        SUBSCRIPTION_URL="$input"
        SUBSCRIPTION_ARGS=(--url "$SUBSCRIPTION_URL")
    else
        SUBSCRIPTION_FILE="${input/#\~/$HOME}"
        [[ -f "$SUBSCRIPTION_FILE" ]] || die "未找到订阅文件：$SUBSCRIPTION_FILE"
        SUBSCRIPTION_ARGS=(--file "$SUBSCRIPTION_FILE")
    fi
}

singbox_ready() {
    [[ -x "$HOME/.local/bin/sing-box" ]] &&
        [[ -x "$HOME/.local/bin/sb" ]] &&
        [[ -r "$HOME/.local/lib/sing-box/current/shell/vpn.sh" ]] &&
        [[ -s "$HOME/service/sing-box/config.json" ]] &&
        [[ -f "$HOME/.config/systemd/user/sing-box.service" ]]
}

zsh_ready() {
    command -v zsh >/dev/null 2>&1 &&
        [[ -d "$HOME/.oh-my-zsh" ]] &&
        [[ -f "$HOME/.zshrc" ]]
}

pyenv_ready() {
    [[ -x "$HOME/.pyenv/bin/pyenv" ]] &&
        [[ -x "$HOME/.local/bin/uv" ]]
}

codex_ready() {
    [[ -x "$HOME/.local/bin/codex" ]] || command -v codex >/dev/null 2>&1
}

cc_switch_ready() {
    [[ -x "$HOME/.local/bin/cc-switch" ]] || command -v cc-switch >/dev/null 2>&1
}

should_skip_step() {
    local step="$1"
    local respect_force="${2:-1}"
    shift 2
    if (( respect_force == 1 && FORCE_ALL == 1 )); then
        clear_step_mark "$step"
        return 1
    fi
    if step_marked_done "$step" && "$@"; then
        return 0
    fi
    # Recover from a previous partial failure: if the install truly looks ready,
    # treat it as done even without a marker.
    if "$@"; then
        mark_done "$step"
        return 0
    fi
    return 1
}

check_environment() {
    [[ "$(uname -s)" == "Linux" ]] || die "统一安装脚本目前仅支持 Linux。"
    [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"
    # shellcheck source=/etc/os-release
    source /etc/os-release
    [[ "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *ubuntu* || "${ID_LIKE:-}" == *debian* ]] || \
        die "统一安装脚本目前仅支持 Ubuntu/Debian（检测到：${ID:-未知}）。"
    (( EUID != 0 )) || die "请以普通登录用户运行本脚本；需要管理员权限时脚本会自动调用 sudo。"
    command -v curl >/dev/null 2>&1 || die "未找到 curl。"
    command -v git >/dev/null 2>&1 || die "未找到 git。"
}

start_sudo_keepalive() {
    command -v sudo >/dev/null 2>&1 || return 0
    if ! sudo -n true >/dev/null 2>&1; then
        log "集中请求一次管理员权限（后续 apt / chsh 可能需要）"
        sudo -v || {
            log "未能获取 sudo；将继续，个别步骤可能回落到用户态安装。"
            return 0
        }
    fi
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
    declare -F vpn_on >/dev/null 2>&1 || die "代理辅助脚本中未找到 vpn_on。"
    vpn_on
    log "已为后续下载启用代理环境变量。"
}

activate_zsh_configuration() {
    local zsh_path
    zsh_path="$(command -v zsh 2>/dev/null || true)"
    [[ -n "$zsh_path" ]] || die "Zsh 安装后仍不可用。"
    export SHELL="$zsh_path"
    export BRINGUP_SHELL=zsh
    export PATH="$HOME/.local/bin:$PATH"
    "$zsh_path" -lic 'true' >/dev/null 2>&1 || true
    log "Zsh 配置已激活；后续 Shell 配置将写入 ~/.zshrc。"
}

run_step() {
    local number="$1" total="$2" step_id="$3" name="$4"
    shift 4
    log "[$number/$total] $name"
    "$@"
    mark_done "$step_id"
    log "[$number/$total] $name 完成"
}

logout_once() {
    (( AUTO_LOGOUT == 1 )) || {
        log "全部安装完成。请重新打开终端，或执行：exec zsh"
        return
    }

    log "全部安装完成，即将注销当前会话以应用 Shell 设置"
    sleep 3
    stop_sudo_keepalive

    if command -v gnome-session-quit >/dev/null 2>&1 && [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        gnome-session-quit --logout --no-prompt && return
    fi
    if command -v loginctl >/dev/null 2>&1 && [[ -n "${XDG_SESSION_ID:-}" ]]; then
        loginctl terminate-session "$XDG_SESSION_ID" && return
    fi
    die "无法自动注销。请手动注销并重新登录一次。"
}

install_singbox_step() {
    local total=5
    if (( REINSTALL_SINGBOX == 1 )); then
        clear_step_mark sing-box
        resolve_subscription
        run_step 1 "$total" sing-box "安装 sing-box" \
            bash "$SRC_DIR/sing-box/installer/install.sh" "${SUBSCRIPTION_ARGS[@]}"
        enable_proxy_for_remaining_steps
        return
    fi

    # sing-box is only forced by --reinstall-sing-box, not --force.
    if should_skip_step sing-box 0 singbox_ready; then
        log "[1/$total] 跳过已完成的 sing-box 安装"
        ensure_singbox_service
        enable_proxy_for_remaining_steps
        return
    fi

    resolve_subscription
    run_step 1 "$total" sing-box "安装 sing-box" \
        bash "$SRC_DIR/sing-box/installer/install.sh" "${SUBSCRIPTION_ARGS[@]}"
    enable_proxy_for_remaining_steps
}

main() {
    local total=5
    parse_args "$@"
    check_environment
    mkdir -p "$STATE_DIR" "$HOME/.local/bin"
    export PATH="$HOME/.local/bin:$PATH"

    start_sudo_keepalive
    trap stop_sudo_keepalive EXIT INT TERM

    install_singbox_step

    if should_skip_step zsh 1 zsh_ready; then
        log "[2/$total] 跳过已完成的 Zsh 安装"
    else
        run_step 2 "$total" zsh "安装 Zsh Shell 环境" \
            bash "$SRC_DIR/shell/set_zsh.sh"
    fi
    activate_zsh_configuration

    if should_skip_step pyenv 1 pyenv_ready; then
        log "[3/$total] 跳过已完成的 pyenv + uv 安装"
    else
        run_step 3 "$total" pyenv "安装 pyenv + uv" \
            env BRINGUP_SHELL=zsh bash "$SRC_DIR/conda/set_pyenv.sh"
    fi

    if should_skip_step codex 1 codex_ready; then
        log "[4/$total] 跳过已完成的 Codex CLI 安装"
    else
        run_step 4 "$total" codex "安装 Codex CLI" \
            env CODEX_FORCE="$FORCE_ALL" bash "$SRC_DIR/codex/install.sh"
    fi

    if should_skip_step cc-switch 1 cc_switch_ready; then
        log "[5/$total] 跳过已完成的 cc-switch-cli 安装"
    else
        run_step 5 "$total" cc-switch "安装 cc-switch-cli" \
            env CC_SWITCH_FORCE="$FORCE_ALL" bash "$SRC_DIR/cc-switch/install.sh"
    fi

    stop_sudo_keepalive
    trap - EXIT INT TERM
    logout_once
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
