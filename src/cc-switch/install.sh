#!/usr/bin/env bash

# Idempotent cc-switch-cli installer.
# Uses the upstream release install.sh and installs into ~/.local/bin.

set -euo pipefail

LOCAL_BIN_DIR="${CC_SWITCH_INSTALL_DIR:-$HOME/.local/bin}"
CC_SWITCH_BIN="$LOCAL_BIN_DIR/cc-switch"
INSTALL_URL="${CC_SWITCH_INSTALL_URL:-https://github.com/SaladDay/cc-switch-cli/releases/latest/download/install.sh}"
FORCE_REINSTALL="${CC_SWITCH_FORCE:-0}"

log() {
    printf '[cc-switch] %s\n' "$*"
}

die() {
    printf '[cc-switch][ERROR] %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "未找到依赖命令：$1"
}

ensure_path_in_shell_rc() {
    local rc line
    case "$(basename "${SHELL:-bash}")" in
        zsh) rc="$HOME/.zshrc" ;;
        bash) rc="$HOME/.bashrc" ;;
        *) rc="$HOME/.profile" ;;
    esac
    mkdir -p "$(dirname "$rc")"
    touch "$rc"
    line='export PATH="$HOME/.local/bin:$PATH"'
    if grep -Fqx "$line" "$rc" 2>/dev/null; then
        return
    fi
    printf '\n# cc-switch / local tools\n%s\n' "$line" >>"$rc"
    log "已将 ~/.local/bin 写入 $rc"
}

cc_switch_ready() {
    if [ -x "$CC_SWITCH_BIN" ]; then
        return 0
    fi
    command -v cc-switch >/dev/null 2>&1
}

install_cc_switch() {
    export PATH="$LOCAL_BIN_DIR:$PATH"
    export CC_SWITCH_INSTALL_DIR="$LOCAL_BIN_DIR"

    log "正在通过官方安装器安装 cc-switch-cli..."
    # Non-interactive shells refuse overwrite unless CC_SWITCH_FORCE=1.
    if [ "$FORCE_REINSTALL" = 1 ]; then
        curl -fsSL "$INSTALL_URL" | env CC_SWITCH_FORCE=1 CC_SWITCH_INSTALL_DIR="$LOCAL_BIN_DIR" bash
    else
        curl -fsSL "$INSTALL_URL" | env CC_SWITCH_INSTALL_DIR="$LOCAL_BIN_DIR" bash
    fi
}

verify_cc_switch() {
    export PATH="$LOCAL_BIN_DIR:$PATH"
    if ! command -v cc-switch >/dev/null 2>&1 && [ ! -x "$CC_SWITCH_BIN" ]; then
        die "cc-switch 安装后仍不可用。"
    fi
    if [ -x "$CC_SWITCH_BIN" ]; then
        log "cc-switch 已就绪：$CC_SWITCH_BIN"
        "$CC_SWITCH_BIN" --version >/dev/null 2>&1 || true
    else
        log "cc-switch 已就绪：$(command -v cc-switch)"
    fi
}

main() {
    require_command curl
    mkdir -p "$LOCAL_BIN_DIR"
    export PATH="$LOCAL_BIN_DIR:$PATH"
    ensure_path_in_shell_rc

    if [ "$FORCE_REINSTALL" != 1 ] && cc_switch_ready; then
        log "cc-switch 已安装，跳过安装。"
        verify_cc_switch
        return
    fi

    install_cc_switch
    verify_cc_switch
    log "安装完成。可运行：cc-switch --help"
}

main "$@"
