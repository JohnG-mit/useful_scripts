#!/usr/bin/env bash

sb_user_shell_name() { basename "${SHELL:-sh}"; }

sb_user_rc_file() {
    case "$(sb_user_shell_name)" in
        zsh) printf '%s/.zshrc\n' "$HOME" ;;
        bash) printf '%s/.bashrc\n' "$HOME" ;;
        fish) printf '%s/.config/fish/config.fish\n' "$HOME" ;;
        *) printf '%s/.profile\n' "$HOME" ;;
    esac
}

sb_user_configure_path() {
    local rc shell_name line
    rc="$(sb_user_rc_file)"; shell_name="$(sb_user_shell_name)"
    mkdir -p "$(dirname "$rc")"; touch "$rc"
    if [ "$shell_name" = fish ]; then
        line='fish_add_path -g "$HOME/.local/bin"'
    else
        line='export PATH="$HOME/.local/bin:$PATH"'
    fi
    grep -Fqx "$line" "$rc" || { printf '\n# sing-box commands\n%s\n' "$line" >>"$rc"; }
}

sb_user_configure_vpn() {
    local rc shell_name line
    rc="$(sb_user_rc_file)"; shell_name="$(sb_user_shell_name)"
    case "$shell_name" in bash|zsh) ;; *) sb_warn "仅为 Bash/Zsh 配置 VPN 辅助函数的自动加载"; return ;; esac
    line='. "$HOME/.local/lib/sing-box/current/shell/vpn.sh"'
    grep -Fqx "$line" "$rc" || { printf '\n# sing-box VPN helper\n%s\n' "$line" >>"$rc"; }
}
