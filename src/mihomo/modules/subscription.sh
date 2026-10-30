#!/usr/bin/env bash

MO_SUB_USER_AGENT="${MO_SUB_USER_AGENT:-clash.meta}"

mo_subscription_help() {
    cat <<'EOF'
用法：mo sub [选项] [订阅URL|订阅文件]

支持 Clash/Mihomo YAML、节点链接（vless:// ss:// ...）和 Base64 订阅。
不带参数时交互输入。

选项：
  -f, --file 文件      读取本地订阅/yaml 文件
  -u, --url URL        下载远程订阅
  -n, --no-restart     不重启服务
  -c, --check          只验证，不应用更改
  -h, --help           显示帮助
EOF
}

mo_subscription_saved_source() {
    [ -f "$MO_SOURCE_FILE" ] && head -n1 "$MO_SOURCE_FILE" || true
}

# Download a subscription: direct first, then through the local proxy if mihomo is running.
mo_subscription_download() {
    local url="$1" output="$2" port
    mo_require_command curl || return 1
    case "$url" in
        https://*) ;;
        http://*) mo_warn "订阅 URL 使用明文 HTTP，令牌可能泄露" ;;
        *) mo_error "订阅 URL 必须以 https:// 开头"; return 1 ;;
    esac
    local base=(-fsSL --connect-timeout 15 --max-time 60) err='' attempt
    local env_proxy="${https_proxy:-${HTTPS_PROXY:-${all_proxy:-${ALL_PROXY:-}}}}"
    # Attempts, in order: the shell's own proxy settings (same as a manual curl), forced direct,
    # curl's default User-Agent, and finally the local mihomo proxy when the service is running.
    for attempt in env direct plain-ua local; do
        case "$attempt" in
            env)
                [ -n "$env_proxy" ] || continue
                err="$(curl "${base[@]}" -A "$MO_SUB_USER_AGENT" "$url" -o "$output" 2>&1)" && return 0 ;;
            direct)
                err="$(curl "${base[@]}" --noproxy '*' -A "$MO_SUB_USER_AGENT" "$url" -o "$output" 2>&1)" && return 0 ;;
            plain-ua)
                err="$(curl "${base[@]}" "$url" -o "$output" 2>&1)" && return 0 ;;
            local)
                systemctl --user is-active --quiet "$MO_SERVICE_NAME" 2>/dev/null || continue
                port="$(mo_get_mixed_port)"
                err="$(curl "${base[@]}" -A "$MO_SUB_USER_AGENT" -x "http://127.0.0.1:$port" "$url" -o "$output" 2>&1)" && return 0 ;;
        esac
        mo_warn "下载订阅失败（方式：$attempt）：${err##*$'\n'}"
    done
    mo_error "下载订阅失败。可先手动 curl 保存为文件，再用 mo sub --file 文件 导入"
    return 1
}

mo_subscription_prune_backups() {
    local file count=0
    # shellcheck disable=SC2012
    for file in $(ls -1t "$MO_CONFIG_FILE".bak.* 2>/dev/null); do
        count=$((count + 1))
        [ "$count" -le 5 ] || rm -f "$file"
    done
}

# Generate, test and apply the config.
#   mo_subscription_update [-f FILE|-u URL|SOURCE] [-n] [-c]
#   mo_subscription_update --saved     (mo sync: re-download the saved source)
#   mo_subscription_update --raw       (regenerate from the cached raw subscription)
mo_subscription_update() (
    local source_type='' source_path='' restart=true check_only=false use_saved=false use_raw=false quiet=false
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -f|--file) [ "$#" -ge 2 ] || { mo_error "$1 需要参数值"; return 2; }; source_type=file; source_path="$2"; shift 2 ;;
            -u|--url) [ "$#" -ge 2 ] || { mo_error "$1 需要参数值"; return 2; }; source_type=url; source_path="$2"; shift 2 ;;
            -n|--no-restart) restart=false; shift ;;
            -c|--check) check_only=true; shift ;;
            --saved) use_saved=true; shift ;;
            --raw) use_raw=true; shift ;;
            --quiet) quiet=true; shift ;;
            -h|--help) mo_subscription_help; return ;;
            -*) mo_error "未知订阅选项：$1"; return 2 ;;
            *)
                [ -z "$source_path" ] || { mo_error "只能指定一个订阅源"; return 2; }
                source_path="$1"
                case "$source_path" in http://*|https://*) source_type=url ;; *) source_type=file ;; esac
                shift ;;
        esac
    done

    mo_select_python || return
    mkdir -p "$MO_WORK_DIR/providers"
    chmod 700 "$MO_WORK_DIR"
    mo_pyconfig override-init "$MO_OVERRIDE_FILE" "$MO_RUNTIME_DIR/resources/override.yaml" || return

    local temp_dir raw candidate backup='' provider_backup='' provider_staged="$MO_PROVIDER_FILE.new" new_source=false
    temp_dir="$(mo_make_temp_dir)"
    raw="$temp_dir/subscription"
    candidate="$temp_dir/config.yaml"
    trap 'rm -rf "$temp_dir"; rm -f "$MO_PROVIDER_FILE.new"' EXIT

    if [ "$use_raw" = true ]; then
        [ -f "$MO_RAW_FILE" ] || { mo_error "没有缓存的订阅内容，请先执行 mo sub"; return 1; }
        cp "$MO_RAW_FILE" "$raw"
    else
        if [ -z "$source_path" ] && { [ "$use_saved" = true ] || [ -f "$MO_SOURCE_FILE" ]; }; then
            if [ "$use_saved" = true ] || [ ! -t 0 ]; then
                source_path="$(mo_subscription_saved_source)"
            fi
            if [ -n "$source_path" ]; then
                case "$source_path" in http://*|https://*) source_type=url ;; *) source_type=file ;; esac
            fi
        else
            new_source=true
        fi
        if [ -z "$source_path" ]; then
            [ "$use_saved" = false ] || { mo_error "尚未配置订阅，请先执行 mo sub"; return 1; }
            [ -t 0 ] || { mo_error "必须提供订阅 URL 或文件"; return 2; }
            read -r -p "请输入订阅 URL 或 yaml/文本文件路径：" source_path
            source_path="$(mo_trim "$source_path")"
            case "$source_path" in http://*|https://*) source_type=url ;; *) source_type=file ;; esac
            new_source=true
        fi
        [ -n "$source_path" ] || { mo_error "必须提供订阅 URL 或文件"; return 2; }

        if [ "$source_type" = url ]; then
            [ "$quiet" = true ] || mo_log "正在下载订阅..."
            mo_subscription_download "$source_path" "$raw" || return
        else
            source_path="${source_path/#\~/$HOME}"
            [ -f "$source_path" ] || { mo_error "未找到订阅文件：$source_path"; return 1; }
            cp "$source_path" "$raw"
        fi
    fi

    [ -s "$raw" ] || { mo_error "订阅内容为空"; return 1; }

    local result
    result="$(mo_pyconfig generate \
        --source "$raw" \
        --template "$MO_RUNTIME_DIR/resources/config-template.yaml" \
        --override "$MO_OVERRIDE_FILE" \
        --output "$candidate" \
        --provider-file "$provider_staged" \
        --gh-proxy "$MO_GH_PROXY")" || { mo_error "生成 mihomo 配置失败"; return 1; }
    [ "$quiet" = true ] || mo_log "配置生成方式：${result#mode=}"

    # The provider file must be in place for the core test; restore it if anything fails.
    if [ -f "$provider_staged" ]; then
        if [ -f "$MO_PROVIDER_FILE" ]; then
            provider_backup="$temp_dir/sub.txt.bak"
            cp "$MO_PROVIDER_FILE" "$provider_backup"
        fi
        mv -f "$provider_staged" "$MO_PROVIDER_FILE"
    fi
    restore_provider() {
        if [ -n "$provider_backup" ]; then cp -f "$provider_backup" "$MO_PROVIDER_FILE"; fi
    }

    if [ -x "$MO_BINARY" ]; then
        if ! mo_config_test "$candidate"; then
            restore_provider
            mo_error "新配置未通过测试，已保留原有配置"
            return 1
        fi
    else
        mo_warn "未找到 mihomo 二进制文件，跳过配置测试"
    fi

    if [ "$check_only" = true ]; then
        restore_provider
        mo_log "订阅配置验证通过，未修改任何文件"
        return 0
    fi

    local changed=true
    if [ -f "$MO_CONFIG_FILE" ]; then
        if cmp -s "$candidate" "$MO_CONFIG_FILE"; then
            changed=false
        else
            backup="$MO_CONFIG_FILE.bak.$(date +%Y%m%d_%H%M%S)"
            cp -p "$MO_CONFIG_FILE" "$backup"
            [ "$quiet" = true ] || mo_log "已创建备份：$backup"
        fi
    fi
    if [ "$changed" = true ]; then
        install -m 600 "$candidate" "$MO_CONFIG_FILE.new"
        mv -f "$MO_CONFIG_FILE.new" "$MO_CONFIG_FILE"
        mo_log "配置已更新：$MO_CONFIG_FILE"
    else
        mo_log "配置无变化"
    fi
    if [ "$use_raw" = false ]; then
        install -m 600 "$raw" "$MO_RAW_FILE"
        if [ "$new_source" = true ] || [ ! -f "$MO_SOURCE_FILE" ]; then
            local saved="$source_path"
            if [ "$source_type" = file ]; then
                install -m 600 "$raw" "$MO_WORK_DIR/subscription.local"
                saved="$MO_WORK_DIR/subscription.local"
            fi
            printf '%s\n' "$saved" >"$MO_SOURCE_FILE.new"
            chmod 600 "$MO_SOURCE_FILE.new"
            mv -f "$MO_SOURCE_FILE.new" "$MO_SOURCE_FILE"
        fi
    fi
    mo_subscription_prune_backups

    if [ "$restart" = true ] && [ -f "$MO_SERVICE_FILE" ]; then
        if [ "$changed" = true ] || ! mo_service_is_active; then
            mo_service_restart || return
        fi
    fi
)

# mo sync: refresh the saved subscription (used by the systemd timer, so never interactive).
mo_subscription_sync() {
    [ -f "$MO_SOURCE_FILE" ] || { mo_error "尚未配置订阅，请先执行 mo sub"; return 1; }
    mo_subscription_update --saved "$@"
}
