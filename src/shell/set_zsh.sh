#!/bin/bash

# 仅启用出错退出，避免未定义的外部环境变量中断配置流程。
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/apt-retry.sh
source "$SCRIPT_DIR/../lib/apt-retry.sh"

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(eval echo "~${TARGET_USER}")"
USER_BIN_DIR="$TARGET_HOME/bin"

export PATH="$USER_BIN_DIR:$PATH"

if [ ! -d "$TARGET_HOME" ]; then
    echo "错误：未找到用户 ${TARGET_USER} 的家目录。"
    exit 1
fi

OH_MY_ZSH_DIR="$TARGET_HOME/.oh-my-zsh"
ZSH_CUSTOM="${ZSH_CUSTOM:-$OH_MY_ZSH_DIR/custom}"
ZSHRC_FILE="$TARGET_HOME/.zshrc"
TMUX_CONF_FILE="$TARGET_HOME/.tmux.conf"
VSCODE_USER_DIR="$TARGET_HOME/.config/Code/User"
VSCODE_SETTINGS_FILE="$VSCODE_USER_DIR/settings.json"

OS_TYPE="unknown"
ZSH_RELEASE_VERSION="${ZSH_RELEASE_VERSION:-5.9}"
ZSH_SOURCE_URL="${ZSH_SOURCE_URL:-https://gh-proxy.org/sourceforge/https://sourceforge.net/projects/zsh/files/zsh/${ZSH_RELEASE_VERSION}/zsh-${ZSH_RELEASE_VERSION}.tar.xz/download}"
ZSH_INSTALL_PREFIX="$TARGET_HOME/.local/opt/zsh-${ZSH_RELEASE_VERSION}"
ZSH_BUILD_ROOT="$TARGET_HOME/.cache/zsh-build"

print_step() {
    echo "--- $1 ---"
}

backup_file() {
    local file_path="$1"
    if [ -f "$file_path" ]; then
        cp "$file_path" "${file_path}.bak"
        echo "已备份 ${file_path} -> ${file_path}.bak"
    fi
}

append_if_missing() {
    local file_path="$1"
    local line="$2"
    if ! grep -Fqx "$line" "$file_path" 2>/dev/null; then
        echo "$line" >> "$file_path"
    fi
}

sed_in_place() {
    local expression="$1"
    local file_path="$2"
    sed -i.bak "$expression" "$file_path"
    rm -f "${file_path}.bak"
}

detect_os() {
    case "$(uname -s)" in
        Linux)
            OS_TYPE="linux"
            ;;
        Darwin)
            OS_TYPE="macos"
            ;;
        *)
            OS_TYPE="unknown"
            ;;
    esac
    echo "检测到操作系统：$OS_TYPE"
}

check_dependencies() {
    print_step "检查依赖"
    if ! command -v git >/dev/null 2>&1; then
        echo "错误：git 未安装。请先安装 git 后重试。"
        exit 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "错误：curl 未安装。请先安装 curl 后重试。"
        exit 1
    fi
}

check_zsh_build_tools() {
    if ! command -v tar >/dev/null 2>&1; then
        echo "错误：tar 未安装。请先安装 tar 后重试。"
        exit 1
    fi

    if ! command -v make >/dev/null 2>&1; then
        echo "错误：make 未安装。zsh 需要本地编译工具。"
        exit 1
    fi

    if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
        echo "错误：未检测到 cc 或 gcc，无法本地编译 zsh。"
        exit 1
    fi
}

download_zsh_source() {
    local download_dir="$1"
    local archive_path="$download_dir/zsh-${ZSH_RELEASE_VERSION}.tar.xz"

    mkdir -p "$download_dir"
    echo "正在从公开源下载 zsh ${ZSH_RELEASE_VERSION}..." >&2
    if ! curl -fsSL --retry 3 --connect-timeout 15 -o "$archive_path" "$ZSH_SOURCE_URL"; then
        echo "错误：下载 zsh 源码失败。" >&2
        exit 1
    fi

    printf '%s\n' "$archive_path"
}

build_and_install_zsh() {
    local archive_path="$1"
    local build_dir="$2"

    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    tar -xJf "$archive_path" -C "$build_dir"

    local source_dir
    source_dir="$build_dir/zsh-${ZSH_RELEASE_VERSION}"

    if [ ! -d "$source_dir" ]; then
        echo "错误：无法找到解压后的 zsh 源码目录。"
        exit 1
    fi

    echo "正在本地编译 zsh 到 $ZSH_INSTALL_PREFIX ..."
    (cd "$source_dir" && ./configure --prefix="$ZSH_INSTALL_PREFIX" && make && make install)
}

try_install_zsh_with_apt() {
    if [ "$OS_TYPE" != "linux" ] || ! command -v apt-get >/dev/null 2>&1; then
        return 1
    fi

    local -a privilege_command=()
    if [ "$(id -u)" -ne 0 ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            echo "未找到 sudo，将回落到本地编译安装。"
            return 1
        fi

        echo "正在请求 sudo 权限以通过 apt 安装 zsh（密码最多尝试 3 次）..."
        # sudo 默认在连续 3 次密码验证失败后返回非零状态。
        if ! sudo -v; then
            echo "sudo 验证失败或当前用户无 sudo 权限，将回落到本地编译安装。"
            return 1
        fi
        privilege_command=(sudo)
    fi

    echo "正在通过 apt 安装 zsh..."
    if ! apt_update_retry "${privilege_command[@]}"; then
        echo "apt-get update 失败，将回落到本地编译安装。"
        return 1
    fi
    if ! apt_get_retry "${privilege_command[@]}" -- install -y zsh; then
        echo "apt-get install zsh 失败，将回落到本地编译安装。"
        return 1
    fi

    hash -r
    if command -v zsh >/dev/null 2>&1; then
        echo "已通过 apt 安装 zsh：$(command -v zsh)"
        return 0
    fi

    echo "apt 已完成安装，但 PATH 中仍未找到 zsh，将回落到本地编译安装。"
    return 1
}

install_zsh() {
    print_step "步骤 0: 确保可用 zsh"

    if command -v zsh >/dev/null 2>&1; then
        echo "zsh 已安装，跳过安装。"
        mkdir -p "$USER_BIN_DIR"
        return
    fi

    mkdir -p "$USER_BIN_DIR"
    mkdir -p "$ZSH_BUILD_ROOT"

    if try_install_zsh_with_apt; then
        return
    fi

    echo "开始下载源码并将 zsh 编译安装到用户目录。"
    check_zsh_build_tools

    case "$OS_TYPE" in
        linux|macos)
            ;;
        *)
            echo "未识别的平台，仍将尝试从公开源编译 zsh。"
            ;;
    esac

    local archive_path
    archive_path="$(download_zsh_source "$ZSH_BUILD_ROOT")"

    if ! build_and_install_zsh "$archive_path" "$ZSH_BUILD_ROOT/build"; then
        echo "错误：本地编译 zsh 失败。请确认系统已安装基础构建工具和头文件。"
        exit 1
    fi

    if [ -x "$ZSH_INSTALL_PREFIX/bin/zsh" ]; then
        ln -sf "$ZSH_INSTALL_PREFIX/bin/zsh" "$USER_BIN_DIR/zsh"
    fi

    if ! command -v zsh >/dev/null 2>&1 && [ -x "$USER_BIN_DIR/zsh" ]; then
        export PATH="$USER_BIN_DIR:$PATH"
    fi

    if ! command -v zsh >/dev/null 2>&1; then
        echo "错误：zsh 安装后仍未能在 PATH 中找到。"
        exit 1
    fi

    echo "zsh 安装/检测完成，当前可用路径：$(command -v zsh)"
}

install_oh_my_zsh() {
    print_step "步骤 1: 安装 Oh My Zsh"

    if [ -d "$OH_MY_ZSH_DIR" ]; then
        echo "Oh My Zsh 目录 ($OH_MY_ZSH_DIR) 已存在，跳过 clone。"
    else
        git clone https://github.com/robbyrussell/oh-my-zsh.git "$OH_MY_ZSH_DIR"
    fi

    if [ -f "$ZSHRC_FILE" ]; then
        echo "发现已存在的 .zshrc，备份为 .zshrc.bak..."
        cp "$ZSHRC_FILE" "${ZSHRC_FILE}.bak"
    fi

    cp "$OH_MY_ZSH_DIR/templates/zshrc.zsh-template" "$ZSHRC_FILE"
    echo "Oh My Zsh 安装并配置 .zshrc 完毕。"
}

configure_theme() {
    print_step "步骤 2: 配置 Ubuntu Bash 风格主题"

    local theme_dir="$ZSH_CUSTOM/themes"
    local theme_file="$theme_dir/ubuntu-bash.zsh-theme"

    mkdir -p "$theme_dir"
    cat > "$theme_file" <<'EOF'
# Ubuntu 24.04 Bash-like prompt: bold green user@host, bold blue cwd,
# optional yellow Git branch, and the conventional $/# suffix.
setopt prompt_subst
ZSH_THEME_GIT_PROMPT_PREFIX=' %F{yellow}('
ZSH_THEME_GIT_PROMPT_SUFFIX=')%f'
PROMPT='%B%F{green}%n@%m%f%b:%B%F{blue}%~%f%b$(git_prompt_info)%(!.#.$) '
EOF

    sed_in_place 's/^ZSH_THEME=.*/ZSH_THEME="ubuntu-bash"/' "$ZSHRC_FILE"
    echo "主题已设置为 Ubuntu 24.04 Bash 风格。"
}

configure_sing_box_in_zshrc() {
    print_step "配置 sing-box Shell 环境"

    append_if_missing "$ZSHRC_FILE" 'export PATH="$HOME/.local/bin:$PATH"'
    append_if_missing "$ZSHRC_FILE" \
        '[ ! -r "$HOME/.local/lib/sing-box/current/shell/vpn.sh" ] || . "$HOME/.local/lib/sing-box/current/shell/vpn.sh"'
}

set_default_shell() {
    print_step "步骤 3: 设置默认 shell"

    local zsh_path
    local current_shell=""
    local switch_succeeded=false
    zsh_path="$(command -v zsh 2>/dev/null || true)"

    if [ -z "$zsh_path" ]; then
        echo "未找到 zsh，无法更改 shell。"
        return
    fi

    if command -v getent >/dev/null 2>&1; then
        current_shell="$(getent passwd "$TARGET_USER" 2>/dev/null | awk -F: '{print $7}')"
    elif [ "$OS_TYPE" = "macos" ] && command -v dscl >/dev/null 2>&1; then
        current_shell="$(dscl . -read "/Users/$TARGET_USER" UserShell 2>/dev/null | awk '{print $2}')"
    fi
    if [ -z "$current_shell" ]; then
        current_shell="${SHELL:-}"
    fi

    if [ "${current_shell##*/}" = "zsh" ]; then
        echo "用户 $TARGET_USER 的默认 shell 已经是 zsh：$current_shell"
        return
    fi

    if ! command -v chsh >/dev/null 2>&1; then
        echo "未找到 chsh 命令，无法自动切换默认 shell。"
    elif [ "$(id -u)" -eq 0 ]; then
        echo "正在将用户 $TARGET_USER 的默认 shell 切换为 $zsh_path ..."
        if chsh -s "$zsh_path" "$TARGET_USER"; then
            switch_succeeded=true
        fi
    elif [ "$(id -un)" = "$TARGET_USER" ]; then
        if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
            echo "正在使用已授权的 sudo 将用户 $TARGET_USER 的默认 shell 切换为 $zsh_path ..."
            if sudo chsh -s "$zsh_path" "$TARGET_USER"; then
                switch_succeeded=true
            fi
        else
            echo "正在将当前用户的默认 shell 切换为 $zsh_path ..."
            if chsh -s "$zsh_path"; then
                switch_succeeded=true
            fi
        fi
    else
        echo "当前身份不是目标用户 $TARGET_USER，无法自动执行 chsh。"
    fi

    if [ "$switch_succeeded" = true ]; then
        echo "默认 shell 已成功切换为 $zsh_path，重新登录后生效。"
        return
    fi

    echo "自动切换默认 shell 失败，请根据实际权限自行选择执行以下命令："
    if [ -r /etc/shells ] && ! grep -Fqx "$zsh_path" /etc/shells; then
        echo "  当前 zsh 路径不在 /etc/shells，先注册："
        echo "     echo '$zsh_path' | sudo tee -a /etc/shells"
    fi
    echo "  以当前用户切换："
    echo "     chsh -s '$zsh_path'"
    echo "  由管理员为目标用户切换："
    echo "     sudo chsh -s '$zsh_path' '$TARGET_USER'"
    echo "  仅在当前会话中进入 zsh："
    echo "     exec '$zsh_path'"
    echo "也可以在 .bashrc 中添加以下内容，在交互式 Bash 中自动进入 zsh："
    printf '%s\n' \
        '# Auto-start zsh for interactive shells' \
        'if [ -t 1 ] && [ -n "$PS1" ] && [ -z "$ZSH_VERSION" ] && command -v zsh >/dev/null 2>&1; then' \
        '    exec zsh' \
        'fi'
}

configure_tmux_default_shell() {
    print_step "步骤 4: 设置 tmux 默认 shell并打开鼠标支持"

    local zsh_path
    zsh_path="$(command -v zsh)"

    if [ ! -f "$TMUX_CONF_FILE" ]; then
        touch "$TMUX_CONF_FILE"
    else
        backup_file "$TMUX_CONF_FILE"
    fi

    append_if_missing "$TMUX_CONF_FILE" ""
    append_if_missing "$TMUX_CONF_FILE" "# 设置 zsh 为默认 shell (由 set_zsh.sh 添加)"

    if grep -q '^set-option -g default-shell ' "$TMUX_CONF_FILE"; then
        sed_in_place "s|^set-option -g default-shell .*|set-option -g default-shell $zsh_path|" "$TMUX_CONF_FILE"
    else
        echo "set-option -g default-shell $zsh_path" >> "$TMUX_CONF_FILE"
    fi
    echo "set-option -g mouse on" >> "$TMUX_CONF_FILE"

    echo "已将 tmux 默认 shell 设置为 $zsh_path。"
}

install_plugins() {
    print_step "步骤 5 & 6: 安装 zsh 插件"

    local plugins_dir
    plugins_dir="$ZSH_CUSTOM/plugins"
    mkdir -p "$plugins_dir"

    if [ -d "$plugins_dir/zsh-autosuggestions" ]; then
        echo "zsh-autosuggestions 插件已存在，跳过。"
    else
        git clone https://github.com/zsh-users/zsh-autosuggestions "$plugins_dir/zsh-autosuggestions"
    fi

    if [ -d "$plugins_dir/zsh-syntax-highlighting" ]; then
        echo "zsh-syntax-highlighting 插件已存在，跳过。"
    else
        git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$plugins_dir/zsh-syntax-highlighting"
    fi

    echo "插件安装完毕。"
}

configure_plugins_in_zshrc() {
    print_step "步骤 7: 配置插件"

    if grep -q '^plugins=' "$ZSHRC_FILE"; then
        sed_in_place 's/^plugins=.*/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' "$ZSHRC_FILE"
    else
        echo "plugins=(git zsh-autosuggestions zsh-syntax-highlighting)" >> "$ZSHRC_FILE"
    fi

    append_if_missing "$ZSHRC_FILE" "source \$ZSH_CUSTOM/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
    append_if_missing "$ZSHRC_FILE" "source \$ZSH_CUSTOM/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
    echo "插件已在 .zshrc 中配置。"
}

add_aliases_to_zshrc() {
    print_step "步骤 8: 添加 Alias"

    append_if_missing "$ZSHRC_FILE" "alias ll='ls -alFh'"
    append_if_missing "$ZSHRC_FILE" "alias la='ls -A'"
    append_if_missing "$ZSHRC_FILE" "alias l='ls -CF'"
    append_if_missing "$ZSHRC_FILE" "alias cin=\"mamba activate\""
    append_if_missing "$ZSHRC_FILE" "alias cout=\"mamba deactivate\""
    echo "Alias 添加完毕。"
}

configure_vscode_user_settings() {
    print_step "提前配置 VS Code 用户终端设置"

    if [ "$OS_TYPE" != "linux" ]; then
        echo "当前不是 Linux，跳过 terminal.integrated.profiles.linux 配置。"
        return
    fi

    local zsh_path
    zsh_path="$(command -v zsh 2>/dev/null || true)"
    if [ -z "$zsh_path" ]; then
        echo "未找到 zsh，无法配置 VS Code 默认终端。"
        return
    fi

    mkdir -p "$VSCODE_USER_DIR"

    if [ -f "$VSCODE_SETTINGS_FILE" ]; then
        backup_file "$VSCODE_SETTINGS_FILE"
    fi

    if command -v python3 >/dev/null 2>&1; then
        if ! python3 - "$VSCODE_SETTINGS_FILE" "$zsh_path" <<'PY'
import json
import os
import sys


def strip_jsonc_comments(text):
    result = []
    index = 0
    in_string = False
    escaped = False

    while index < len(text):
        char = text[index]
        next_char = text[index + 1] if index + 1 < len(text) else ""

        if in_string:
            result.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue

        if char == '"':
            in_string = True
            result.append(char)
            index += 1
        elif char == "/" and next_char == "/":
            index += 2
            while index < len(text) and text[index] not in "\r\n":
                index += 1
        elif char == "/" and next_char == "*":
            index += 2
            while index + 1 < len(text) and text[index:index + 2] != "*/":
                index += 1
            index = min(index + 2, len(text))
        else:
            result.append(char)
            index += 1

    return "".join(result)


def strip_trailing_commas(text):
    result = []
    index = 0
    in_string = False
    escaped = False

    while index < len(text):
        char = text[index]
        if in_string:
            result.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue

        if char == '"':
            in_string = True
        elif char == ",":
            lookahead = index + 1
            while lookahead < len(text) and text[lookahead].isspace():
                lookahead += 1
            if lookahead < len(text) and text[lookahead] in "}]":
                index += 1
                continue

        result.append(char)
        index += 1

    return "".join(result)


settings_path, zsh_path = sys.argv[1:3]
settings = {}
if os.path.isfile(settings_path) and os.path.getsize(settings_path) > 0:
    with open(settings_path, "r", encoding="utf-8") as settings_file:
        jsonc = settings_file.read()
    normalized_json = strip_trailing_commas(strip_jsonc_comments(jsonc)).strip()
    if normalized_json:
        try:
            settings = json.loads(normalized_json)
        except (json.JSONDecodeError, ValueError) as error:
            print(f"错误：无法解析现有 VS Code settings.json：{error}", file=sys.stderr)
            print("已保留原文件及 .bak 备份，未写入新配置。", file=sys.stderr)
            raise SystemExit(1)

if not isinstance(settings, dict):
    print("错误：VS Code settings.json 的顶层必须是对象。", file=sys.stderr)
    raise SystemExit(1)

profiles_key = "terminal.integrated.profiles.linux"
profiles = settings.get(profiles_key, {})
if not isinstance(profiles, dict):
    profiles = {}

profiles.update({
    "bash": {
        "path": "bash",
        "icon": "terminal-bash",
    },
    "zsh": {
        "path": zsh_path,
    },
    "fish": {
        "path": "fish",
    },
    "tmux": {
        "path": "tmux",
        "icon": "terminal-tmux",
    },
    "pwsh": {
        "path": "pwsh",
        "icon": "terminal-powershell",
    },
})
profiles.pop("zsh-vscode", None)

settings[profiles_key] = profiles
settings["terminal.integrated.defaultProfile.linux"] = "zsh"
settings["terminal.integrated.copyOnSelection"] = True
settings["terminal.integrated.rightClickBehavior"] = "paste"

temporary_path = f"{settings_path}.tmp"
with open(temporary_path, "w", encoding="utf-8") as settings_file:
    json.dump(settings, settings_file, ensure_ascii=False, indent=4)
    settings_file.write("\n")
os.replace(temporary_path, settings_path)
PY
        then
            echo "警告：VS Code 用户设置合并失败，跳过该步骤。"
            return
        fi
    elif [ ! -f "$VSCODE_SETTINGS_FILE" ]; then
        cat > "$VSCODE_SETTINGS_FILE" <<EOF
{
    "terminal.integrated.profiles.linux": {
        "bash": { "path": "bash", "icon": "terminal-bash" },
        "zsh": { "path": "$zsh_path" },
        "fish": { "path": "fish" },
        "tmux": { "path": "tmux", "icon": "terminal-tmux" },
        "pwsh": { "path": "pwsh", "icon": "terminal-powershell" }
    },
    "terminal.integrated.defaultProfile.linux": "zsh",
    "terminal.integrated.copyOnSelection": true,
    "terminal.integrated.rightClickBehavior": "paste"
}
EOF
    else
        echo "警告：未找到 python3，无法安全合并已有的 VS Code JSONC 配置。"
        echo "已保留原配置，请安装 python3 后重新运行此脚本。"
        return
    fi

    if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
        chown "$TARGET_USER" \
            "$TARGET_HOME/.config" \
            "$TARGET_HOME/.config/Code" \
            "$VSCODE_USER_DIR" \
            "$VSCODE_SETTINGS_FILE"
        if [ -f "${VSCODE_SETTINGS_FILE}.bak" ]; then
            chown "$TARGET_USER" "${VSCODE_SETTINGS_FILE}.bak"
        fi
    fi

    echo "已配置 VS Code 使用普通 zsh 及 $ZSHRC_FILE：$VSCODE_SETTINGS_FILE"
    echo "该文件会在 VS Code 安装后自动生效，安装器通常不会覆盖用户设置。"
}

main() {
    detect_os
    check_dependencies
    install_zsh
    configure_vscode_user_settings
    install_oh_my_zsh
    configure_theme
    configure_sing_box_in_zshrc
    set_default_shell
    configure_tmux_default_shell
    install_plugins
    configure_plugins_in_zshrc
    add_aliases_to_zshrc

    echo "---------------------------------"
    echo "✅ Zsh 环境配置脚本执行完毕！"
    echo "目标用户：$TARGET_USER"
    echo "主配置：$ZSHRC_FILE"
    echo "VS Code 与普通终端共用配置：$ZSHRC_FILE"
    echo "VS Code 用户设置：$VSCODE_SETTINGS_FILE"
    echo "Zsh 可执行文件：$(command -v zsh)"
    echo ""
    echo "重要：要使更改完全生效，建议重新登录终端，或先执行 'exec zsh' 启动新会话。"
}

main
