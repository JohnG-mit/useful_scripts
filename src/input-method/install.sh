#!/bin/bash

set -e

# One-click fcitx5 + rime Chinese input method installer.
# - Installs fcitx5 and the rime engine via apt
# - Sets fcitx5 as the system input method framework (env vars + autostart)
# - Makes rime the default input schema (simplified Chinese)
# - Applies custom rime config so special symbols never trigger a
#   full/half-width candidate menu, and comma/period adapt to CN/EN mode

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/apt-retry.sh
source "$SCRIPT_DIR/../lib/apt-retry.sh"
RIME_TEMPLATE_DIR="$SCRIPT_DIR/rime"
RIME_USER_DIR="$HOME/.local/share/fcitx5/rime"
FCITX5_CONFIG_DIR="$HOME/.config/fcitx5"
FCITX5_PROFILE="$FCITX5_CONFIG_DIR/profile"
AUTOSTART_DIR="$HOME/.config/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/fcitx5.desktop"
ENV_DIR="$HOME/.config/environment.d"
ENV_FILE="$ENV_DIR/fcitx5.conf"
XPROFILE="$HOME/.xprofile"
INSTALL_DIR="$HOME/.local/bin"
IM_SCRIPT="$SCRIPT_DIR/im.sh"

RIME_CONFIG_FILES=(
    "default.custom.yaml"
    "luna_pinyin.custom.yaml"
    "symbols.custom.yaml"
)

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

require_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "缺少命令：$cmd"
        exit 1
    fi
}

install_packages() {
    if ! command -v apt-get >/dev/null 2>&1; then
        warn "未找到 apt-get，将跳过软件包安装。"
        warn "请使用系统包管理器确认已安装 fcitx5 和 fcitx5-rime。"
        return
    fi

    local packages=(fcitx5 fcitx5-chinese-addons fcitx5-rime fcitx5-config-qt)
    local missing=()
    local pkg

    for pkg in "${packages[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        log "Fcitx 5 和 Rime 软件包已安装"
        return
    fi

    local -a sudo_cmd=()
    if [ "$(id -u)" -ne 0 ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            error "安装以下软件包需要 root 权限：${missing[*]}"
            error "请手动安装：apt-get install -y ${missing[*]}"
            exit 1
        fi
        sudo_cmd=(sudo)
    fi

    log "正在安装软件包：${missing[*]}"
    apt_update_retry "${sudo_cmd[@]}"
    apt_get_retry "${sudo_cmd[@]}" -- install -y "${missing[@]}"
}

set_environment() {
    mkdir -p "$ENV_DIR"

    log "正在将输入法环境变量写入 $ENV_FILE..."
    cat > "$ENV_FILE" <<'EOF'
# Set fcitx5 as the input method framework (managed by useful_scripts)
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
GLFW_IM_MODULE=ibus
EOF

    # X11 sessions may not read environment.d; mirror into ~/.xprofile.
    local marker="# useful_scripts fcitx5 input method"
    if [ -f "$XPROFILE" ] && grep -Fq "$marker" "$XPROFILE"; then
        log "$XPROFILE 中已存在 Fcitx 5 环境配置"
    else
        log "正在将 Fcitx 5 环境配置追加到 $XPROFILE..."
        {
            echo ""
            echo "$marker"
            echo 'export GTK_IM_MODULE=fcitx'
            echo 'export QT_IM_MODULE=fcitx'
            echo 'export XMODIFIERS=@im=fcitx'
        } >> "$XPROFILE"
    fi
}

setup_autostart() {
    mkdir -p "$AUTOSTART_DIR"

    log "正在配置 Fcitx 5 自动启动：$AUTOSTART_FILE..."
    cat > "$AUTOSTART_FILE" <<'EOF'
[Desktop Entry]
Type=Application
Name=Fcitx 5
Exec=fcitx5
Icon=fcitx
Terminal=false
X-GNOME-Autostart-Phase=Applications
X-GNOME-Autostart-enabled=true
EOF
}

set_default_profile() {
    mkdir -p "$FCITX5_CONFIG_DIR"

    log "正在 $FCITX5_PROFILE 中将 Rime 设为默认输入法..."
    cat > "$FCITX5_PROFILE" <<'EOF'
[Groups/0]
# Group Name
Name=默认
# Layout
Default Layout=us
# Default Input Method
DefaultIM=rime

[Groups/0/Items/0]
# Name
Name=rime
# Layout
Layout=

[Groups/0/Items/1]
# Name
Name=keyboard-us
# Layout
Layout=

[GroupOrder]
0=默认
EOF
}

install_rime_config() {
    mkdir -p "$RIME_USER_DIR"

    local file src dest backup
    for file in "${RIME_CONFIG_FILES[@]}"; do
        src="$RIME_TEMPLATE_DIR/$file"
        dest="$RIME_USER_DIR/$file"

        if [ ! -f "$src" ]; then
            error "未找到 Rime 配置模板：$src"
            exit 1
        fi

        if [ -f "$dest" ] && ! cmp -s "$src" "$dest"; then
            backup="$dest.bak.$(date +%Y%m%d_%H%M%S)"
            cp "$dest" "$backup"
            log "已创建备份：$backup"
        fi

        install -m 644 "$src" "$dest"
        log "已安装 Rime 配置：$dest"
    done
}

deploy_rime() {
    if [ ! -f "$IM_SCRIPT" ]; then
        error "未找到 im 辅助脚本：$IM_SCRIPT"
        exit 1
    fi

    log "正在安装 im 命令到 $INSTALL_DIR/im..."
    mkdir -p "$INSTALL_DIR"
    install -m 755 "$IM_SCRIPT" "$INSTALL_DIR/im"

    log "正在重新编译 Rime 配置并重载 Fcitx 5..."
    bash "$INSTALL_DIR/im" deploy || warn "Rime 部署出现问题，请检查 'im deploy' 的输出。"
}

activate_rime_now() {
    log "正在当前桌面会话中启动 Fcitx 5 并激活 Rime..."

    if ! pgrep -x fcitx5 >/dev/null 2>&1; then
        (fcitx5 -d >/dev/null 2>&1 &) || true
        sleep 1
    fi

    if command -v fcitx5-remote >/dev/null 2>&1 && fcitx5-remote -s rime >/dev/null 2>&1; then
        log "Rime 已在当前会话中激活"
    else
        warn "当前不是可用的桌面会话；Rime 将在下次登录时自动激活。"
    fi
}

print_summary() {
    log "Fcitx 5 + Rime 输入法安装完成。"
    log "默认方案：Rime 朙月拼音（简体中文）"
    log "中英文切换：Shift   |   输入法切换：Ctrl+Space   |   方案菜单：F4"
    warn "请注销后重新登录（或重启），使桌面会话加载输入法环境变量。"
    log "可随时运行以下命令重新编译配置：im deploy"
}

main() {
    require_command install

    install_packages
    set_environment
    setup_autostart
    set_default_profile
    install_rime_config
    deploy_rime
    activate_rime_now
    print_summary
}

main "$@"
