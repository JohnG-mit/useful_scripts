#!/usr/bin/env bash

sb_subscription_help() {
    cat <<'EOF'
用法：sb subscription update [选项]

选项：
  -f, --file 文件      读取本地订阅文件
  -u, --url URL        下载远程订阅
  -a, --append         合并到当前配置（默认）
  -r, --replace        使用内置模板重新生成配置
  -n, --no-restart     不重启服务
  -c, --check          只验证，不应用更改
  -h, --help           显示帮助
EOF
}

sb_subscription_download() {
    local url="$1" output="$2"
    case "$url" in
        https://*) ;;
        *) sb_error "订阅 URL 必须使用 HTTPS"; return 1 ;;
    esac
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$output"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$url" -O "$output"
    else
        sb_error "读取 URL 订阅需要 curl 或 wget"
        return 1
    fi
}

sb_subscription_decode() {
    local file="$1" decoded
    if head -1 "$file" | grep -qE '^[A-Za-z0-9+/=]+$' && ! head -1 "$file" | grep -q '://'; then
        decoded="$(mktemp "${TMPDIR:-/tmp}/sing-box-decoded.XXXXXX")"
        if base64 -d "$file" >"$decoded" 2>/dev/null; then
            mv "$decoded" "$file"
        else
            rm -f "$decoded"
            sb_warn "Base64 解码失败，将输入按纯文本处理"
        fi
    fi
}

sb_subscription_validate_content() {
    awk 'BEGIN { n=0 } { gsub(/\r/, ""); if ($0 !~ /^[[:space:]]*(#|$)/) n++ } END { exit(n == 0) }' "$1" || {
        sb_error "订阅为空或仅包含注释"
        return 1
    }
}

sb_subscription_generate() {
    local source="$1" output="$2" mode="$3"
    local args=("$SB_CONFIG_TEMPLATE" "$source" "$output")
    if [ "$mode" = append ] && [ -f "$SB_CONFIG_FILE" ]; then
        args+=(--append "$SB_CONFIG_FILE")
    fi
    PYTHONPATH="$SB_RUNTIME_DIR/python${PYTHONPATH:+:$PYTHONPATH}" \
        "$SB_PYTHON" -m singbox_config "${args[@]}"
}

sb_subscription_check_generated() {
    local candidate="$1" check_dir
    if [ ! -x "$SB_BINARY" ]; then
        sb_warn "sing-box 二进制文件不可用，将跳过原生配置检查"
        return 0
    fi
    check_dir="$(sb_make_temp_dir)"
    cp "$candidate" "$check_dir/config.json"
    if "$SB_BINARY" check -D "$SB_WORK_DIR" -C "$check_dir"; then
        rm -rf "$check_dir"
        return 0
    fi
    rm -rf "$check_dir"
    sb_error "生成的 sing-box 配置未通过验证"
    return 1
}

sb_subscription_update() (
    local source_type='' source_path='' mode=append restart=true check_only=false
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -f|--file) [ "$#" -ge 2 ] || { sb_error "$1 需要参数值"; return 2; }; source_type=file; source_path="$2"; shift 2 ;;
            -u|--url) [ "$#" -ge 2 ] || { sb_error "$1 需要参数值"; return 2; }; source_type=url; source_path="$2"; shift 2 ;;
            -a|--append) mode=append; shift ;;
            -r|--replace) mode=replace; shift ;;
            -n|--no-restart) restart=false; shift ;;
            -c|--check) check_only=true; shift ;;
            -h|--help) sb_subscription_help; return ;;
            *)
                if [ -z "$source_path" ]; then
                    source_path="$1"
                    case "$source_path" in http://*|https://*) source_type=url ;; *) source_type=file ;; esac
                    shift
                else
                    sb_error "未知订阅选项：$1"; return 2
                fi ;;
        esac
    done

    if [ -z "$source_path" ]; then
        read -r -p "请输入订阅文件路径或 URL：" source_path
        source_path="$(sb_trim "$source_path")"
        case "$source_path" in http://*|https://*) source_type=url ;; *) source_type=file ;; esac
    fi
    [ -n "$source_path" ] || { sb_error "必须提供订阅文件路径或 URL"; return 2; }

    sb_select_python || return
    local temp_dir source_file candidate backup
    temp_dir="$(sb_make_temp_dir)"
    source_file="$temp_dir/subscription"
    candidate="$temp_dir/config.json"
    trap 'rm -rf "$temp_dir"' EXIT

    if [ "$source_type" = url ]; then
        sb_log "正在下载订阅..."
        sb_subscription_download "$source_path" "$source_file" || return
    else
        source_path="${source_path/#\~/$HOME}"
        [ -f "$source_path" ] || { sb_error "未找到订阅文件：$source_path"; return 1; }
        cp "$source_path" "$source_file"
    fi

    sb_subscription_decode "$source_file"
    sb_subscription_validate_content "$source_file" || return
    sb_subscription_generate "$source_file" "$candidate" "$mode" || return
    sb_subscription_check_generated "$candidate" || return

    if [ "$check_only" = true ]; then
        sb_log "订阅配置验证通过，未修改任何文件"
        return 0
    fi

    mkdir -p "$SB_WORK_DIR"
    if [ -f "$SB_CONFIG_FILE" ]; then
        backup="$SB_CONFIG_FILE.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$SB_CONFIG_FILE" "$backup"
        sb_log "已创建备份：$backup"
    fi
    install -m 600 "$candidate" "$SB_CONFIG_FILE.new"
    mv "$SB_CONFIG_FILE.new" "$SB_CONFIG_FILE"
    sb_log "配置已更新：$SB_CONFIG_FILE"

    if [ "$restart" = true ] && [ -f "$SB_SERVICE_FILE" ]; then
        sb_service_restart
    fi
)
