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

check_dependencies


# --- 1. 运行 pyenv-installer ---
echo "--- 正在运行 pyenv-installer ---"
curl -fsSL https://pyenv.run | bash


# --- 2. 安装 uv 到 ~/bin ---
echo "--- 正在安装 uv 到 ~/bin ---"
mkdir -p "$HOME/bin"
curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$HOME/bin" sh


# --- 3. 配置 .zshrc ---
ZSHRC_FILE="$HOME/.zshrc"

if [ ! -f "$ZSHRC_FILE" ]; then
    touch "$ZSHRC_FILE"
fi

# 检查配置是否已存在，防止重复添加
if ! grep -q 'pyenv init' "$ZSHRC_FILE"; then
    echo "正在配置 pyenv 到 .zshrc..."
    
    # 使用 cat 和 EOF 追加配置，使用 \$ 确保变量作为字面量写入文件。
    cat <<EOF >> "$ZSHRC_FILE"

# pyenv 配置
export PYENV_ROOT="\$HOME/.pyenv"
[[ -d \$PYENV_ROOT/bin ]] && export PATH="\$PYENV_ROOT/bin:\$PATH"
eval "\$(pyenv init - zsh)"
EOF
    echo "Pyenv 配置已添加。"
else
    echo "Pyenv 配置已在 .zshrc 中找到, 跳过配置。"
fi

# 添加 ~/bin 到 PATH (用于 uv)
if ! grep -q 'export PATH="\$HOME/bin:\$PATH"' "$ZSHRC_FILE"; then
    echo "正在配置 ~/bin 路径到 .zshrc..."
    cat <<EOF >> "$ZSHRC_FILE"

# ~/bin 路径配置 (用于 uv 等工具)
export PATH="\$HOME/bin:\$PATH"
EOF
    echo "~/bin 路径配置已添加。"
else
    echo "~/bin 路径配置已在 .zshrc 中找到, 跳过配置。"
fi


# --- 完成 ---
echo "---------------------------------"
echo "✅ Pyenv 和 uv 安装脚本执行完毕！"
echo ""
echo "要完成安装并加载环境，请执行以下操作之一："
echo "   1. (推荐) 重启您的终端。"
echo "   2. (临时) 在当前终端中运行: source $ZSHRC_FILE"
