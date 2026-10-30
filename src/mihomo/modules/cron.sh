#!/usr/bin/env bash

MO_SYNC_SERVICE_NAME="mihomo-sync"
MO_SYNC_SERVICE_FILE="$MO_SYSTEMD_DIR/mihomo-sync.service"
MO_DEFAULT_SYNC_TIME="${MO_DEFAULT_SYNC_TIME:-06:00}"

mo_cron_write_service() {
    mkdir -p "$MO_SYSTEMD_DIR"
    local temp
    temp="$(mktemp)"
    printf '%s\n' \
        '[Unit]' 'Description=Sync mihomo subscription' 'After=network-online.target' \
        'Wants=network-online.target' '' '[Service]' 'Type=oneshot' \
        "ExecStart=$MO_BIN_DIR/mo sync --quiet" >"$temp"
    install -m 644 "$temp" "$MO_SYNC_SERVICE_FILE"
    rm -f "$temp"
}

# $@: OnCalendar/OnUnitActive lines to place in the [Timer] section.
mo_cron_write_timer() {
    local temp line
    mkdir -p "$MO_SYSTEMD_DIR"
    temp="$(mktemp)"
    {
        printf '%s\n' '[Unit]' 'Description=Periodic mihomo subscription sync' '' '[Timer]'
        for line in "$@"; do printf '%s\n' "$line"; done
        printf '%s\n' "Unit=$MO_SYNC_SERVICE_NAME.service" '' '[Install]' 'WantedBy=timers.target'
    } >"$temp"
    install -m 644 "$temp" "$MO_SYNC_TIMER_FILE"
    rm -f "$temp"
    mo_cron_write_service
    mo_ensure_user_systemd_env
    systemctl --user daemon-reload
    systemctl --user enable --now "$MO_SYNC_SERVICE_NAME.timer"
}

mo_cron_normalize_time() {
    local value
    value="$(mo_trim "$1")"
    [[ "$value" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || return 1
    local hour=$((10#${BASH_REMATCH[1]})) minute=$((10#${BASH_REMATCH[2]}))
    [ "$hour" -le 23 ] && [ "$minute" -le 59 ] || return 1
    printf '%02d:%02d\n' "$hour" "$minute"
}

# mo cron daily 06:00,18:00
mo_cron_set_daily() {
    local input="${1:-}" item normalized lines=() shown=()
    [ -n "$input" ] || { mo_error "请提供时间点，例如 06:00,18:00"; return 2; }
    input="${input//，/,}"; input="${input// /,}"
    local IFS=','
    for item in $input; do
        [ -n "$item" ] || continue
        normalized="$(mo_cron_normalize_time "$item")" || { mo_error "无效的时间点：$item（格式 HH:MM）"; return 2; }
        lines+=("OnCalendar=*-*-* $normalized:00")
        shown+=("$normalized")
    done
    unset IFS
    [ "${#lines[@]}" -gt 0 ] || { mo_error "没有有效的时间点"; return 2; }
    lines+=("Persistent=true" "RandomizedDelaySec=2min")
    mo_require_command systemctl || return
    mo_cron_write_timer "${lines[@]}" || return
    mo_log "已设置每日同步：${shown[*]}"
}

# mo cron every 6
mo_cron_set_every() {
    local hours="${1:-}"
    [[ "$hours" =~ ^[0-9]+$ ]] && [ "$hours" -ge 1 ] && [ "$hours" -le 168 ] || {
        mo_error "间隔必须是 1-168 之间的整数小时"
        return 2
    }
    mo_require_command systemctl || return
    mo_cron_write_timer "OnBootSec=10min" "OnUnitActiveSec=${hours}h" || return
    mo_log "已设置每 ${hours} 小时同步一次"
}

mo_cron_disable() {
    mo_require_command systemctl || return
    mo_ensure_user_systemd_env
    if [ -f "$MO_SYNC_TIMER_FILE" ]; then
        systemctl --user disable --now "$MO_SYNC_SERVICE_NAME.timer" 2>/dev/null || true
    fi
    mo_log "已取消自动同步订阅"
}

# Human readable description of the current schedule.
mo_cron_describe() {
    mo_ensure_user_systemd_env
    if [ ! -f "$MO_SYNC_TIMER_FILE" ]; then
        printf '未设置\n'
        return
    fi
    if ! systemctl --user is-enabled --quiet "$MO_SYNC_SERVICE_NAME.timer" 2>/dev/null; then
        printf '已取消\n'
        return
    fi
    local calendars every
    calendars="$(sed -n 's/^OnCalendar=\*-\*-\* \([0-9:]*\):00$/\1/p' "$MO_SYNC_TIMER_FILE" | paste -sd' ' -)"
    every="$(sed -n 's/^OnUnitActiveSec=\(.*\)$/\1/p' "$MO_SYNC_TIMER_FILE")"
    if [ -n "$calendars" ]; then
        printf '每天 %s\n' "$calendars"
    elif [ -n "$every" ]; then
        printf '每 %s\n' "$every"
    else
        printf '已启用（自定义）\n'
    fi
}

mo_cron_status() {
    mo_require_command systemctl || return
    mo_ensure_user_systemd_env
    printf '自动同步：%s\n' "$(mo_cron_describe)"
    printf '订阅源：%s\n' "$(mo_subscription_saved_source 2>/dev/null | sed -E 's#(https?://[^/]+/).*#\1***#')"
    if [ -f "$MO_SYNC_TIMER_FILE" ]; then
        systemctl --user list-timers "$MO_SYNC_SERVICE_NAME.timer" --no-pager 2>/dev/null || true
    fi
}

# Install the default schedule on first setup (remote subscriptions only).
mo_cron_ensure_default() {
    [ -f "$MO_SYNC_TIMER_FILE" ] && return 0
    case "$(mo_subscription_saved_source 2>/dev/null)" in
        http://*|https://*) mo_cron_set_daily "$MO_DEFAULT_SYNC_TIME" ;;
        *) mo_cron_write_service ;;
    esac
}

mo_cron_menu() {
    local choice value
    while true; do
        cat <<EOF

========== 订阅自动同步 ==========
当前：$(mo_cron_describe)
1) 设置每日同步时间点（可多个，如 06:00,18:00）
2) 设置每隔 N 小时同步
3) 立即同步一次
4) 取消自动同步
5) 查看定时器状态
0) 返回
==================================
EOF
        read -r -p '请选择 [0-5]：' choice || return 0
        case "$choice" in
            1) read -r -p '请输入时间点（HH:MM，多个用逗号分隔）：' value; mo_cron_set_daily "$value" || true ;;
            2) read -r -p '请输入间隔小时数（1-168）：' value; mo_cron_set_every "$value" || true ;;
            3) mo_subscription_sync || true ;;
            4) mo_cron_disable || true ;;
            5) mo_cron_status || true ;;
            0|'') return 0 ;;
            *) mo_error "无效选项：$choice" ;;
        esac
    done
}

mo_cron() {
    case "${1:-}" in
        '') mo_cron_menu ;;
        status) mo_cron_status ;;
        daily) mo_cron_set_daily "${2:-}" ;;
        every) mo_cron_set_every "${2:-}" ;;
        off|disable) mo_cron_disable ;;
        *) mo_error "用法：mo cron [status|daily HH:MM[,HH:MM]|every 小时数|off]"; return 2 ;;
    esac
}
