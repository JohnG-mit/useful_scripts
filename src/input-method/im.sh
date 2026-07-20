#!/bin/bash

set -e

RIME_USER_DIR="$HOME/.local/share/fcitx5/rime"
RIME_SHARED_DIR="/usr/share/rime-data"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_help() {
    cat <<EOF
用法: im [命令]

无参数时进入交互菜单。

命令:
    d, deploy       重新编译 rime 配置并重载 fcitx5
    r, restart      重启 fcitx5 进程
    s, status       查看 fcitx5 运行状态与当前输入法
    e, edit         用 \$EDITOR 打开 rime 用户配置目录
    dir             打印 rime 用户配置目录
    h, help         显示帮助
EOF
}

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "Missing command: $cmd"
        exit 1
    fi
}

find_rime_shared_dir() {
    local candidate
    for candidate in "$RIME_SHARED_DIR" /usr/share/rime-data /usr/local/share/rime-data; do
        if [ -d "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

reload_fcitx5() {
    if command -v fcitx5-remote >/dev/null 2>&1; then
        fcitx5-remote -r >/dev/null 2>&1 && return 0
    fi
    return 1
}

deploy_rime() {
    require_command rime_deployer

    if [ ! -d "$RIME_USER_DIR" ]; then
        error "Rime user directory not found: $RIME_USER_DIR"
        error "Please run: bash src/input-method/install.sh"
        exit 1
    fi

    local shared_dir
    if ! shared_dir="$(find_rime_shared_dir)"; then
        error "Rime shared data directory not found (expected $RIME_SHARED_DIR)"
        exit 1
    fi

    local log_file
    log_file="$(mktemp)"

    log "Rebuilding rime schemas in $RIME_USER_DIR..."
    if ! rime_deployer --build "$RIME_USER_DIR" "$shared_dir" >"$log_file" 2>&1; then
        error "rime_deployer failed:"
        grep -iE "error|fail" "$log_file" | head -n 20 || cat "$log_file"
        rm -f "$log_file"
        exit 1
    fi

    if grep -qiE "error|fail" "$log_file"; then
        warn "rime_deployer reported issues:"
        grep -iE "error|fail" "$log_file" | head -n 20
    else
        log "Rime build succeeded"
    fi
    rm -f "$log_file"

    if reload_fcitx5; then
        log "fcitx5 reloaded"
    else
        warn "Could not reload fcitx5 automatically. Restart it manually or run: im restart"
    fi
}

restart_fcitx5() {
    if ! command -v fcitx5 >/dev/null 2>&1; then
        error "fcitx5 not found. Please run: bash src/input-method/install.sh"
        exit 1
    fi

    log "Restarting fcitx5..."
    pkill -x fcitx5 >/dev/null 2>&1 || true
    sleep 1
    (fcitx5 -d >/dev/null 2>&1 &) || true
    sleep 1

    if pgrep -x fcitx5 >/dev/null 2>&1; then
        log "fcitx5 restarted"
    else
        warn "fcitx5 does not appear to be running. Start it from your desktop session."
    fi
}

show_status() {
    if pgrep -x fcitx5 >/dev/null 2>&1; then
        log "fcitx5 is running (PID: $(pgrep -x fcitx5 | tr '\n' ' '))"
    else
        warn "fcitx5 is not running"
    fi

    if command -v fcitx5-remote >/dev/null 2>&1; then
        local current
        current="$(fcitx5-remote -n 2>/dev/null || true)"
        if [ -n "$current" ]; then
            log "Current input method: $current"
        fi
    fi

    echo "GTK_IM_MODULE=${GTK_IM_MODULE:-<unset>}"
    echo "QT_IM_MODULE=${QT_IM_MODULE:-<unset>}"
    echo "XMODIFIERS=${XMODIFIERS:-<unset>}"
}

edit_config() {
    local editor="${EDITOR:-vi}"

    if [ ! -d "$RIME_USER_DIR" ]; then
        error "Rime user directory not found: $RIME_USER_DIR"
        exit 1
    fi

    "$editor" "$RIME_USER_DIR"
}

show_dir() {
    echo "$RIME_USER_DIR"
}

show_menu() {
    cat <<'EOF'
========== im menu ==========
1) 重新编译 rime 配置并重载 (im deploy)
2) 重启 fcitx5 (im restart)
3) 查看 fcitx5 状态 (im status)
4) 编辑 rime 用户配置 (im edit)
5) 打印 rime 用户配置目录 (im dir)
0) 退出
=============================
EOF

    read -r -p "请选择 [0-5]: " choice
    case "$choice" in
        1) deploy_rime ;;
        2) restart_fcitx5 ;;
        3) show_status ;;
        4) edit_config ;;
        5) show_dir ;;
        0) exit 0 ;;
        *)
            error "无效选项: $choice"
            exit 1
            ;;
    esac
}

main() {
    case "${1:-}" in
        "")
            show_menu
            ;;
        d|deploy)
            deploy_rime
            ;;
        r|restart)
            restart_fcitx5
            ;;
        s|status)
            show_status
            ;;
        e|edit)
            edit_config
            ;;
        dir)
            show_dir
            ;;
        h|help|-h|--help)
            show_help
            ;;
        *)
            error "Unknown command: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
