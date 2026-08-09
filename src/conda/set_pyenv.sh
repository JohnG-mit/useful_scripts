#!/bin/bash

# 脚本出错时立即退出
set -e

check_dependencies() {
    if ! command -v curl >/dev/null 2>&1; then
        echo "错误：curl 未安装。请先安装 curl 后重试。"
        exit 1
    fi

    if ! command -v git >/dev/null 2>&1; then
        echo "错误：git 未安装。请先安装 git 后重试。"
        exit 1
    fi
}

detect_shell() {
    USER_SHELL="$(basename "${BRINGUP_SHELL:-${SHELL:-}}")"

    case "$USER_SHELL" in
        bash)
            SHELL_RC_FILE="$HOME/.bashrc"
            ;;
        zsh)
            SHELL_RC_FILE="$HOME/.zshrc"
            ;;
        *)
            echo "错误：无法识别受支持的终端 Shell（当前为：${USER_SHELL:-未知}）。"
            echo "目前仅支持 Bash 和 Zsh，请确认 SHELL 环境变量设置正确后重试。"
            exit 1
            ;;
    esac
}

check_dependencies
detect_shell


# --- 1. 运行 pyenv-installer ---
echo "--- 正在运行 pyenv-installer ---"
if [ -x "$HOME/.pyenv/bin/pyenv" ]; then
    echo "Pyenv 已安装，跳过安装器。"
else
    curl -fsSL https://pyenv.run | bash
fi


# --- 2. 安装 uv 到 ~/.local/bin ---
echo "--- 正在安装 uv 到 ~/.local/bin ---"
mkdir -p "$HOME/.local/bin"
if [ -x "$HOME/.local/bin/uv" ]; then
    echo "uv 已安装，跳过安装器。"
else
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$HOME/.local/bin" sh
fi


# --- 3. 配置当前 Shell ---
if [ ! -f "$SHELL_RC_FILE" ]; then
    touch "$SHELL_RC_FILE"
fi

# 检查配置是否已存在，防止重复添加
if ! grep -q 'pyenv init' "$SHELL_RC_FILE"; then
    echo "正在配置 pyenv 到 $SHELL_RC_FILE..."
    
    # 使用 cat 和 EOF 追加配置，使用 \$ 确保变量作为字面量写入文件。
    cat <<EOF >> "$SHELL_RC_FILE"

# pyenv 配置
export PYENV_ROOT="\$HOME/.pyenv"
[[ -d \$PYENV_ROOT/bin ]] && export PATH="\$PYENV_ROOT/bin:\$PATH"
eval "\$(pyenv init - $USER_SHELL)"
EOF
    echo "Pyenv 配置已添加。"
else
    echo "Pyenv 配置已在 $SHELL_RC_FILE 中找到, 跳过配置。"
fi

# 添加 ~/.local/bin 到 PATH (用于 uv)
if ! grep -q 'export PATH="\$HOME/.local/bin:\$PATH"' "$SHELL_RC_FILE"; then
    echo "正在配置 ~/.local/bin 路径到 $SHELL_RC_FILE..."
    cat <<EOF >> "$SHELL_RC_FILE"

# ~/.local/bin 路径配置 (用于 uv 等工具)
export PATH="\$HOME/.local/bin:\$PATH"
EOF
    echo "~/.local/bin 路径配置已添加。"
else
    echo "~/.local/bin 路径配置已在 $SHELL_RC_FILE 中找到, 跳过配置。"
fi


# --- 完成 ---
echo "---------------------------------"
echo "✅ Pyenv 和 uv 安装脚本执行完毕！"
echo ""
echo "要完成安装并加载环境，请执行以下操作之一："
echo "   1. (推荐) 重启您的终端。"
echo "   2. (临时) 在当前终端中运行: source $SHELL_RC_FILE"
