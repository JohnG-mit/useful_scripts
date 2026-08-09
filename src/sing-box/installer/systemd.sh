#!/usr/bin/env bash

sb_install_systemd_units() {
    sb_require_command systemctl || return
    mkdir -p "$SB_SYSTEMD_DIR" "$SB_WORK_DIR/ui"
    local service_temp rotate_temp timer_temp
    service_temp="$(mktemp)"; rotate_temp="$(mktemp)"; timer_temp="$(mktemp)"
    printf '%s\n' \
        '[Unit]' 'Description=sing-box service' 'Documentation=https://sing-box.sagernet.org' \
        'After=network-online.target nss-lookup.target' 'Wants=network-online.target' \
        'StartLimitIntervalSec=120' 'StartLimitBurst=3' '' '[Service]' \
        "ExecStart=$SB_BINARY -D $SB_WORK_DIR -C $SB_WORK_DIR run" \
        "WorkingDirectory=$SB_WORK_DIR" 'Restart=on-failure' 'RestartSec=5s' \
        'UMask=0077' 'LimitNOFILE=infinity' '' \
        '[Install]' 'WantedBy=default.target' >"$service_temp"
    printf '%s\n' '[Unit]' 'Description=Rotate sing-box file logs' '' '[Service]' 'Type=oneshot' \
        "ExecStart=$SB_BIN_DIR/sing-box-log-rotate" >"$rotate_temp"
    printf '%s\n' '[Unit]' 'Description=Periodic sing-box file log rotation' '' '[Timer]' \
        'OnCalendar=hourly' 'Persistent=true' 'RandomizedDelaySec=5m' '' '[Install]' \
        'WantedBy=timers.target' >"$timer_temp"
    install -m 644 "$service_temp" "$SB_SYSTEMD_DIR/sing-box.service"
    install -m 644 "$rotate_temp" "$SB_SYSTEMD_DIR/sing-box-log-rotate.service"
    install -m 644 "$timer_temp" "$SB_SYSTEMD_DIR/sing-box-log-rotate.timer"
    rm -f "$service_temp" "$rotate_temp" "$timer_temp"
    systemctl --user daemon-reload
    systemctl --user enable sing-box.service
    systemctl --user enable --now sing-box-log-rotate.timer
    systemctl --user reset-failed sing-box.service
    systemctl --user restart sing-box.service
}
