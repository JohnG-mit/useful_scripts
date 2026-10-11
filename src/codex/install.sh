#!/usr/bin/env bash

# Idempotent Codex CLI installer.
# Uses the official standalone installer and installs into ~/.local/bin.

set -euo pipefail

LOCAL_BIN_DIR="${CODEX_INSTALL_DIR:-$HOME/.local/bin}"
CODEX_BIN="$LOCAL_BIN_DIR/codex"
INSTALL_URL="${CODEX_INSTALL_URL:-https://chatgpt.com/codex/install.sh}"
FORCE_REINSTALL="${CODEX_FORCE:-0}"

log() {
    printf '[codex] %s\n' "$*"
}

die() {
    printf '[codex][ERROR] %s\n' "$*" >&2
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
    printf '\n# Codex CLI / local tools\n%s\n' "$line" >>"$rc"
    log "已将 ~/.local/bin 写入 $rc"
}

codex_ready() {
    if [ -x "$CODEX_BIN" ]; then
        return 0
    fi
    command -v codex >/dev/null 2>&1
}

install_codex() {
    export PATH="$LOCAL_BIN_DIR:$PATH"
    export CODEX_INSTALL_DIR="$LOCAL_BIN_DIR"
    export CODEX_NON_INTERACTIVE="${CODEX_NON_INTERACTIVE:-1}"

    log "正在通过官方安装器安装 Codex CLI..."
    curl -fsSL "$INSTALL_URL" | sh
}

verify_codex() {
    export PATH="$LOCAL_BIN_DIR:$PATH"
    if ! command -v codex >/dev/null 2>&1 && [ ! -x "$CODEX_BIN" ]; then
        die "Codex CLI 安装后仍不可用。"
    fi
    if [ -x "$CODEX_BIN" ]; then
        log "Codex CLI 已就绪：$CODEX_BIN"
    else
        log "Codex CLI 已就绪：$(command -v codex)"
    fi
}

main() {
    require_command curl
    mkdir -p "$LOCAL_BIN_DIR"
    export PATH="$LOCAL_BIN_DIR:$PATH"
    ensure_path_in_shell_rc

    if [ "$FORCE_REINSTALL" != 1 ] && codex_ready; then
        log "Codex CLI 已安装，跳过安装。"
        verify_codex
        return
    fi

    install_codex
    verify_codex
    log "安装完成。首次使用请运行：codex"
}

main "$@"
