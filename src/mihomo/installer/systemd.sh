#!/usr/bin/env bash

mo_install_systemd_units() {
    mo_require_command systemctl || return
    mo_ensure_user_systemd_env
    mkdir -p "$MO_SYSTEMD_DIR" "$MO_WORK_DIR"
    local temp
    temp="$(mktemp)"
    printf '%s\n' \
        '[Unit]' 'Description=mihomo proxy service' 'Documentation=https://wiki.metacubex.one' \
        'After=network-online.target nss-lookup.target' 'Wants=network-online.target' \
        'StartLimitIntervalSec=120' 'StartLimitBurst=3' '' '[Service]' \
        "WorkingDirectory=$MO_WORK_DIR" \
        "ExecStartPre=$MO_BINARY -t -d $MO_WORK_DIR -f $MO_CONFIG_FILE" \
        "ExecStart=$MO_BINARY -d $MO_WORK_DIR -f $MO_CONFIG_FILE" \
        'Restart=on-failure' 'RestartSec=5s' 'TimeoutStartSec=300' \
        'UMask=0077' 'LimitNOFILE=1048576' '' \
        '[Install]' 'WantedBy=default.target' >"$temp"
    install -m 644 "$temp" "$MO_SERVICE_FILE"
    rm -f "$temp"

    mo_cron_write_service
    systemctl --user daemon-reload
    systemctl --user enable "$MO_SERVICE_NAME.service"
    systemctl --user reset-failed "$MO_SERVICE_NAME.service" 2>/dev/null || true
    mo_service_restart || return
    mo_cron_ensure_default || mo_warn "未能设置订阅自动同步，可稍后执行 mo cron"
}

# Let the user service start at boot without an interactive login.
mo_install_linger() {
    command -v loginctl >/dev/null 2>&1 || return 0
    local user="${USER:-$(id -un)}"
    if [ "$(loginctl show-user "$user" -p Linger --value 2>/dev/null)" = yes ]; then
        return 0
    fi
    if loginctl enable-linger "$user" 2>/dev/null; then
        mo_log "已启用 linger：开机后无需登录即可启动 mihomo"
    elif command -v sudo >/dev/null 2>&1 && sudo loginctl enable-linger "$user"; then
        mo_log "已启用 linger：开机后无需登录即可启动 mihomo"
    else
        mo_warn "未能启用 linger：mihomo 将在用户首次登录后启动。可手动执行：sudo loginctl enable-linger $user"
    fi
}
