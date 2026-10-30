#!/usr/bin/env bash

mo_service_require_unit() {
    [ -f "$MO_SERVICE_FILE" ] || {
        mo_error "未找到用户服务文件：$MO_SERVICE_FILE"
        return 1
    }
    mo_require_command systemctl || return
    mo_ensure_user_systemd_env
}

mo_service_is_active() {
    systemctl --user is-active --quiet "$MO_SERVICE_NAME" 2>/dev/null
}

mo_service_require_running() {
    mo_service_require_unit && mo_service_is_active || {
        mo_error "mihomo 服务未运行（可尝试 mo r）"
        return 1
    }
}

# mo t: validate config.yaml (or the file given as $1) with the core itself.
mo_config_test() {
    local file="${1:-$MO_CONFIG_FILE}" output status
    mo_require_binary || return
    [ -f "$file" ] || { mo_error "未找到配置文件：$file"; return 1; }
    mo_log "正在测试配置文件：$file"
    output="$(timeout "${MO_TEST_TIMEOUT:-180}" "$MO_BINARY" -t -d "$MO_WORK_DIR" -f "$file" 2>&1)" && status=0 || status=$?
    printf '%s\n' "$output"
    if [ "$status" -eq 0 ]; then
        mo_log "配置文件测试通过"
    elif [ "$status" -eq 124 ]; then
        mo_error "配置文件测试超时（可能在下载 GeoIP/规则数据，请检查网络或 MO_GH_PROXY）"
    else
        mo_error "配置文件测试失败（退出码 $status）"
    fi
    return "$status"
}

# Runs once after a failed start/restart: config test first, then the latest journal lines.
mo_service_diagnose() {
    printf '\n'
    mo_warn "服务未能正常运行，自动执行配置文件测试..."
    if [ -x "$MO_BINARY" ] && [ -f "$MO_CONFIG_FILE" ]; then
        mo_config_test || true
    fi
    if command -v journalctl >/dev/null 2>&1; then
        printf '\n--- 最近 20 行服务日志 ---\n'
        journalctl --user -u "$MO_SERVICE_NAME" -n 20 --no-pager 2>&1 || true
    fi
}

mo_service_status() {
    mo_service_require_unit || return
    if mo_service_is_active; then
        mo_log "$MO_SERVICE_NAME 服务正在运行"
        systemctl --user status "$MO_SERVICE_NAME" --no-pager || true
        local enabled
        enabled="$(systemctl --user is-enabled "$MO_SERVICE_NAME" 2>/dev/null || true)"
        mo_log "开机自启：${enabled:-未知}；混合代理端口：$(mo_get_mixed_port)；面板：$(mo_api_base)/ui/"
    else
        mo_warn "$MO_SERVICE_NAME 服务未运行"
        systemctl --user status "$MO_SERVICE_NAME" --no-pager || true
        mo_service_diagnose
        return 1
    fi
}

mo_service_restart() {
    mo_service_require_unit || return
    mo_log "正在重启 $MO_SERVICE_NAME..."
    systemctl --user reset-failed "$MO_SERVICE_NAME" 2>/dev/null || true
    if ! systemctl --user restart "$MO_SERVICE_NAME"; then
        mo_error "$MO_SERVICE_NAME 重启失败"
        mo_service_diagnose
        return 1
    fi
    sleep 2
    if ! mo_service_is_active; then
        mo_error "$MO_SERVICE_NAME 启动后退出"
        mo_service_diagnose
        return 1
    fi
    mo_log "$MO_SERVICE_NAME 重启成功"
}

mo_service_log() {
    mo_service_require_unit || return
    mo_require_command journalctl || return
    case "${1:-}" in
        -f|--follow) journalctl --user -u "$MO_SERVICE_NAME" -f --no-pager ;;
        '') journalctl --user -u "$MO_SERVICE_NAME" -n 100 --no-pager ;;
        *[!0-9]*) mo_error "用法：mo log [-f|行数]"; return 2 ;;
        *) journalctl --user -u "$MO_SERVICE_NAME" -n "$1" --no-pager ;;
    esac
}
