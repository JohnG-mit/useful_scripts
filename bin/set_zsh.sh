#!/bin/bash

# 避免 set -u 与 VS Code zsh 集成场景冲突，仅启用出错退出。
set -e

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
VSCODE_ZSHRC_DIR="$TARGET_HOME/.zshrc_vscode"
VSCODE_ZSHRC_FILE="$VSCODE_ZSHRC_DIR/.zshrc"

OS_TYPE="unknown"
ZSH_RELEASE_VERSION="${ZSH_RELEASE_VERSION:-5.9}"
ZSH_SOURCE_URL="${ZSH_SOURCE_URL:-https://sourceforge.net/projects/zsh/files/zsh/${ZSH_RELEASE_VERSION}/zsh-${ZSH_RELEASE_VERSION}.tar.xz/download}"
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

install_zsh() {
    print_step "步骤 0: 确保可用 zsh"

    if command -v zsh >/dev/null 2>&1; then
        echo "zsh 已安装，跳过安装。"
        mkdir -p "$USER_BIN_DIR"
        return
    fi

    mkdir -p "$USER_BIN_DIR"
    mkdir -p "$ZSH_BUILD_ROOT"

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
    print_step "步骤 2: 修改 Zsh 主题"
    sed_in_place 's/^ZSH_THEME=.*/ZSH_THEME="af-magic"/' "$ZSHRC_FILE"
    echo "主题已设置为 af-magic。"
}

set_default_shell() {
    print_step "步骤 3: 设置默认 shell"

    local zsh_path
    zsh_path="$(command -v zsh)"

    if [ -z "$zsh_path" ]; then
        echo "未找到 zsh，无法更改 shell。"
        return
    fi

    if [ "${SHELL:-}" = "$zsh_path" ]; then
        echo "当前 shell 已经是 zsh，跳过。"
        return
    fi

    echo "检测到非 zsh 默认 shell。由于当前脚本不依赖 sudo，将仅提示你手动切换："
    echo "chsh -s $zsh_path"
    echo "或者在当前会话中直接执行：exec zsh"
}

configure_tmux_default_shell() {
    print_step "步骤 4: 设置 tmux 默认 shell"

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

generate_vscode_zshrc() {
    print_step "步骤 9: 生成 VS Code 专用 zshrc"

    mkdir -p "$VSCODE_ZSHRC_DIR"
    if [ -f "$VSCODE_ZSHRC_FILE" ]; then
        backup_file "$VSCODE_ZSHRC_FILE"
    fi

    cat > "$VSCODE_ZSHRC_FILE" <<'EOF'
echo "loading ~/.zshrc_vscode" >&2

alias ll='ls -alFh'
alias la='ls -A'
alias l='ls -CF'
alias map="mamba activate pytorch"
alias cin="mamba activate"
alias cout="mamba deactivate"

# VS Code 专用（精简）
export PATH="$HOME/.local/bin:$HOME/.pyenv/bin:$PATH"

# Initialize pyenv only when available
export PYENV_ROOT="$HOME/.pyenv"
if [ -d "$PYENV_ROOT/bin" ]; then
  export PATH="$PYENV_ROOT/bin:$PATH"
fi
if command -v pyenv >/dev/null 2>&1; then
  eval "$(pyenv init - zsh)" 2>/dev/null || true
fi

# Optional user script
if [ -f "$HOME/script/vpn.zsh" ]; then
  . "$HOME/script/vpn.zsh"
fi

# mamba shell hook (keeps activation behavior)
if command -v mamba >/dev/null 2>&1; then
  export MAMBA_EXE="$(command -v mamba)"
elif [ -x "$HOME/.pyenv/versions/miniforge3-latest/bin/mamba" ]; then
  export MAMBA_EXE="$HOME/.pyenv/versions/miniforge3-latest/bin/mamba"
else
  unset MAMBA_EXE
fi

if [ -n "${MAMBA_EXE:-}" ]; then
  export MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-$HOME/.local/share/mamba}"
  __mamba_setup="$($MAMBA_EXE shell hook --shell zsh --root-prefix "$MAMBA_ROOT_PREFIX" 2>/dev/null)" || true
  if [ -n "$__mamba_setup" ]; then
    eval "$__mamba_setup"
  else
    alias mamba="$MAMBA_EXE"
  fi
  unset __mamba_setup
  alias conda='mamba'
fi

# Simple, clean prompt to avoid noisy output
PROMPT='%n@%m:%~ %# '

# Optional: source VS Code shell integration if available
if [ "${TERM_PROGRAM:-}" = "vscode" ] && command -v code >/dev/null 2>&1; then
  . "$(code --locate-shell-integration-path zsh)" 2>/dev/null || true
fi

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"
EOF

    echo "已生成 VS Code 专用 zshrc：$VSCODE_ZSHRC_FILE"
}

main() {
    detect_os
    check_dependencies
    install_zsh
    install_oh_my_zsh
    configure_theme
    set_default_shell
    configure_tmux_default_shell
    install_plugins
    configure_plugins_in_zshrc
    add_aliases_to_zshrc
    generate_vscode_zshrc

    echo "---------------------------------"
    echo "✅ Zsh 环境配置脚本执行完毕！"
    echo "目标用户: $TARGET_USER"
    echo "主配置: $ZSHRC_FILE"
    echo "VS Code 专用配置: $VSCODE_ZSHRC_FILE"
    echo "zsh 可执行文件: $(command -v zsh)"
    echo ""
    echo "重要：要使更改完全生效，建议重新登录终端，或先执行 'exec zsh' 启动新会话。"
}

main
