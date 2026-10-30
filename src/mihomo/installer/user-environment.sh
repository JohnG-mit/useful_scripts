#!/usr/bin/env bash

mo_user_shell_name() { basename "${SHELL:-sh}"; }

# Persist KEY='VALUE' in ~/.config/mo/config (sourced by core.sh).
mo_user_config_set() {
    local key="$1" value="$2" temp
    mkdir -p "$MO_USER_CONFIG_DIR"
    temp="$(mktemp "${TMPDIR:-/tmp}/mo-config.XXXXXX")"
    if [ -f "$MO_USER_CONFIG_FILE" ]; then
        grep -v "^${key}=" "$MO_USER_CONFIG_FILE" >"$temp" || true
    fi
    printf "%s='%s'\n" "$key" "$value" >>"$temp"
    install -m 600 "$temp" "$MO_USER_CONFIG_FILE"
    rm -f "$temp"
}

# rc files that should receive the mihomo block: every existing bash/zsh rc, plus the login shell's rc.
mo_user_rc_files() {
    local files=() rc
    case "$(mo_user_shell_name)" in
        zsh) files+=("$HOME/.zshrc") ;;
        bash) files+=("$HOME/.bashrc") ;;
        fish) mo_warn "fish 暂不自动配置 vpn_on/vpn_off，请手动 source：$MO_RUNTIME_BASE/current/shell/vpn.sh" ;;
        *) files+=("$HOME/.profile") ;;
    esac
    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
        [ -f "$rc" ] || continue
        case " ${files[*]} " in *" $rc "*) ;; *) files+=("$rc") ;; esac
    done
    printf '%s\n' "${files[@]}"
}

# Replace (or add) the marker block that loads PATH, vpn helpers and the auto vpn_on.
mo_user_configure_shell() {
    local rc temp
    while IFS= read -r rc; do
        [ -n "$rc" ] || continue
        mkdir -p "$(dirname "$rc")"; touch "$rc"
        temp="$(mktemp)"
        awk -v begin="$MO_RC_BEGIN" -v end="$MO_RC_END" '
            $0 == begin { skipping = 1; next }
            skipping && $0 == end { skipping = 0; next }
            skipping { next }
            /^[[:space:]]*$/ { blanks++; next }
            { for (; blanks > 0; blanks--) print ""; print }
        ' "$rc" >"$temp"
        {
            printf '\n%s\n' "$MO_RC_BEGIN"
            printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"'
            printf '%s\n' '[ -r "$HOME/.local/lib/mihomo/current/shell/vpn.sh" ] && . "$HOME/.local/lib/mihomo/current/shell/vpn.sh"'
            printf '%s\n' '# 新终端在 mihomo 运行时自动 vpn_on；设置 MO_AUTO_VPN=0 可关闭'
            printf '%s\n' '[ "${MO_AUTO_VPN:-1}" = 0 ] || { command -v _mo_vpn_autostart >/dev/null 2>&1 && _mo_vpn_autostart; }'
            printf '%s\n' "$MO_RC_END"
        } >>"$temp"
        cat "$temp" >"$rc"
        rm -f "$temp"
        mo_log "已写入 Shell 配置：$rc"
    done < <(mo_user_rc_files)
}

# Comment out sing-box's vpn helper lines (and the vpn_on/set_proxy call that follows) so they do
# not override the mihomo functions. Original text is kept after a marker prefix for restoring.
mo_user_disable_singbox_rc() {
    local rc temp
    for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
        [ -f "$rc" ] || continue
        grep -Eq '^[[:space:]]*(source|\.)[[:space:]]+.*sing-box.*vpn\.sh' "$rc" || continue
        [ -f "$rc.mihomo-install.bak" ] || cp -p "$rc" "$rc.mihomo-install.bak"
        temp="$(mktemp)"
        awk -v prefix="$MO_RC_DISABLED_PREFIX" '
            /^[[:space:]]*(source|\.)[[:space:]]+.*sing-box.*vpn\.sh/ { print prefix $0; after = 1; next }
            after && /^[[:space:]]*$/ { print; next }
            after && /^[[:space:]]*(vpn_on|set_proxy)([[:space:]]|$)/ { print prefix $0; after = 0; next }
            { after = 0; print }
        ' "$rc" >"$temp"
        cat "$temp" >"$rc"
        rm -f "$temp"
        mo_log "已停用 $rc 中的 sing-box 代理函数加载（备份：$rc.mihomo-install.bak）"
    done
}
