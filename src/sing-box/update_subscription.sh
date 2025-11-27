#!/bin/bash

set -e

# Variables
SERVICE_NAME="sing-box"
WORK_DIR="$HOME/service/$SERVICE_NAME"
CONFIG_FILE="$WORK_DIR/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_FILE="$SCRIPT_DIR/config_template.json"
GENERATE_SCRIPT="$SCRIPT_DIR/generate_config.py"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_help() {
    cat << EOF
用法: $(basename "$0") [选项] <订阅文件路径或订阅URL>

将新的订阅添加到 sing-box 配置中并重启服务。

选项:
    -h, --help          显示此帮助信息
    -f, --file FILE     从本地文件读取订阅链接
    -u, --url URL       从远程URL下载订阅链接
    -a, --append        追加模式：将新订阅追加到现有 config.json（默认）
    -r, --replace       替换模式：从模板重新生成配置，替换所有订阅
    -n, --no-restart    仅更新配置，不重启服务
    -c, --check         仅检查配置是否有效，不应用更改

注意: 每次更新前会自动备份当前配置到配置文件所在目录

示例:
    $(basename "$0") -f ~/subscriptions.txt           # 追加新订阅到现有配置
    $(basename "$0") -u "https://example.com/sub"     # 从URL下载并追加订阅
    $(basename "$0") -f ~/new_subs.txt -r             # 替换模式：从模板重新生成

订阅文件格式:
    每行一个订阅链接，支持以下协议：
    - vless://
    - hysteria2://
    - tuic://
    
    以 # 开头的行会被忽略（注释）
EOF
}

# 检查依赖
check_dependencies() {
    if ! command -v python3 &> /dev/null; then
        error "Python3 未安装"
        exit 1
    fi
    
    if [ ! -f "$GENERATE_SCRIPT" ]; then
        error "找不到配置生成脚本: $GENERATE_SCRIPT"
        exit 1
    fi
    
    if [ ! -f "$TEMPLATE_FILE" ]; then
        error "找不到配置模板: $TEMPLATE_FILE"
        exit 1
    fi
}

# 从URL下载订阅
download_subscription() {
    local url="$1"
    local output="$2"
    
    log "正在从URL下载订阅..."
    
    # 尝试使用 curl 或 wget
    if command -v curl &> /dev/null; then
        if curl -fsSL "$url" -o "$output"; then
            log "订阅下载成功"
            return 0
        fi
    elif command -v wget &> /dev/null; then
        if wget -q "$url" -O "$output"; then
            log "订阅下载成功"
            return 0
        fi
    fi
    
    error "下载订阅失败"
    return 1
}

# 解码 Base64 订阅（如果需要）
decode_subscription() {
    local file="$1"
    
    # 检查文件是否是 Base64 编码
    if head -1 "$file" | grep -qE '^[A-Za-z0-9+/=]+$' && ! head -1 "$file" | grep -qE '://'; then
        log "检测到 Base64 编码的订阅，正在解码..."
        local decoded_content
        decoded_content=$(base64 -d "$file" 2>/dev/null) || {
            warn "Base64 解码失败，尝试作为普通文本处理"
            return 0
        }
        echo "$decoded_content" > "$file"
        log "订阅解码完成"
    fi
}

# 验证订阅文件
validate_subscription() {
    local file="$1"
    local count=0
    
    while IFS= read -r line; do
        line=$(echo "$line" | tr -d '\r' | xargs)  # 去除空白和回车
        [ -z "$line" ] && continue
        [[ "$line" =~ ^# ]] && continue
        
        if [[ "$line" =~ ^(vless|hysteria2|tuic):// ]]; then
            ((count++))
        else
            warn "不支持的协议: ${line:0:30}..."
        fi
    done < "$file"
    
    if [ "$count" -eq 0 ]; then
        error "订阅文件中没有找到有效的链接"
        return 1
    fi
    
    log "找到 $count 个有效订阅链接"
    return 0
}

# 备份当前配置
backup_config() {
    if [ -f "$CONFIG_FILE" ]; then
        local backup_file="${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$CONFIG_FILE" "$backup_file"
        log "已备份当前配置到: $backup_file"
    fi
}

# 生成新配置
# 参数: $1 = 订阅文件, $2 = 模式 ("append" 或 "replace")
generate_config() {
    local subscription_file="$1"
    local mode="$2"
    local temp_config="$CONFIG_FILE.tmp"
    
    log "正在生成新配置（模式: $mode）..."
    
    local cmd_args=("$TEMPLATE_FILE" "$subscription_file" "$temp_config")
    
    # 追加模式：如果存在现有配置，传递给 Python 脚本
    if [ "$mode" = "append" ] && [ -f "$CONFIG_FILE" ]; then
        cmd_args+=("--append" "$CONFIG_FILE")
    fi
    
    if python3 "$GENERATE_SCRIPT" "${cmd_args[@]}"; then
        mv "$temp_config" "$CONFIG_FILE"
        log "配置生成成功: $CONFIG_FILE"
        return 0
    else
        rm -f "$temp_config"
        error "配置生成失败"
        return 1
    fi
}

# 检查配置有效性
check_config() {
    local sing_box_bin="$HOME/bin/sing-box"
    
    if [ ! -f "$sing_box_bin" ]; then
        warn "找不到 sing-box 二进制文件，跳过配置检查"
        return 0
    fi
    
    log "正在检查配置有效性..."
    
    if "$sing_box_bin" check -D "$WORK_DIR" -C "$WORK_DIR"; then
        log "配置检查通过"
        return 0
    else
        error "配置检查失败"
        return 1
    fi
}

# 重启服务
restart_service() {
    log "正在重启 sing-box 服务..."
    
    if systemctl --user restart "$SERVICE_NAME"; then
        log "服务重启成功"
        
        # 等待服务启动并检查状态
        sleep 2
        if systemctl --user is-active --quiet "$SERVICE_NAME"; then
            log "sing-box 服务运行正常"
        else
            error "服务启动后异常，请检查日志: journalctl --user -u $SERVICE_NAME -f"
            return 1
        fi
    else
        error "服务重启失败"
        return 1
    fi
}

# 主函数
main() {
    local mode="append"  # replace 或 append（默认追加模式）
    local source_type=""  # file 或 url
    local source_path=""
    local do_restart=true
    local check_only=false
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -f|--file)
                source_type="file"
                source_path="$2"
                shift 2
                ;;
            -u|--url)
                source_type="url"
                source_path="$2"
                shift 2
                ;;
            -a|--append)
                mode="append"
                shift
                ;;
            -r|--replace)
                mode="replace"
                shift
                ;;
            -n|--no-restart)
                do_restart=false
                shift
                ;;
            -c|--check)
                check_only=true
                shift
                ;;
            *)
                # 如果没有指定 -f 或 -u，默认当作文件路径处理
                if [ -z "$source_type" ]; then
                    if [[ "$1" =~ ^https?:// ]]; then
                        source_type="url"
                    else
                        source_type="file"
                    fi
                    source_path="$1"
                fi
                shift
                ;;
        esac
    done
    
    # 检查参数
    if [ -z "$source_path" ]; then
        error "请提供订阅文件路径或URL"
        echo ""
        show_help
        exit 1
    fi
    
    # 检查依赖
    check_dependencies
    
    # 确保工作目录存在
    mkdir -p "$WORK_DIR"
    
    # 创建临时文件
    local temp_sub_file=$(mktemp)
    trap "rm -f $temp_sub_file" EXIT
    
    # 获取订阅内容
    if [ "$source_type" = "url" ]; then
        download_subscription "$source_path" "$temp_sub_file" || exit 1
    else
        # 展开 ~ 到 home 目录
        source_path="${source_path/#\~/$HOME}"
        
        if [ ! -f "$source_path" ]; then
            error "找不到订阅文件: $source_path"
            exit 1
        fi
        cp "$source_path" "$temp_sub_file"
    fi
    
    # 解码订阅（如果是 Base64）
    decode_subscription "$temp_sub_file"
    
    # 验证订阅
    validate_subscription "$temp_sub_file" || exit 1
    
    # 仅检查模式 - 不修改任何真实文件
    if [ "$check_only" = true ]; then
        log "检查模式：生成临时配置..."
        local temp_config=$(mktemp)
        local cmd_args=("$TEMPLATE_FILE" "$temp_sub_file" "$temp_config")
        
        # 追加模式：如果存在现有配置，传递给 Python 脚本
        if [ "$mode" = "append" ] && [ -f "$CONFIG_FILE" ]; then
            cmd_args+=("--append" "$CONFIG_FILE")
        fi
        
        if python3 "$GENERATE_SCRIPT" "${cmd_args[@]}"; then
            log "配置生成成功（未应用）"
            rm -f "$temp_config"
            exit 0
        else
            rm -f "$temp_config"
            exit 1
        fi
    fi
    
    # 强制备份当前配置
    backup_config
    
    # 生成新配置（传递模式参数）
    generate_config "$temp_sub_file" "$mode" || exit 1
    
    # 检查配置
    check_config || exit 1
    
    # 重启服务
    if [ "$do_restart" = true ]; then
        restart_service || exit 1
    else
        log "配置已更新，服务未重启（使用 -n 选项）"
        log "手动重启: systemctl --user restart $SERVICE_NAME"
    fi
    
    log "✅ 订阅更新完成！"
}

main "$@"
