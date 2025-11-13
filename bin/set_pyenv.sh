#!/bin/bash

# 脚本出错时立即退出
set -e

# --- 预先处理 Sudo 权限 ---
echo "脚本需要 sudo 权限来安装依赖 (curl 和 git)。"
# 检查 sudo 权限，仅在凭据过期时提示输入密码。
if sudo -v; then
    echo "Sudo 权限已确认，将尝试安装缺失的依赖..."
else
    echo "获取 sudo 权限失败。脚本终止。"
    exit 1
fi

# --- 自动安装依赖 (curl 和 git) ---
# 使用 dpkg-query 检查依赖，并使用 sudo 一次性安装
if ! dpkg-query -W -f='${Status}' curl 2>/dev/null | grep -q "ok installed" || ! dpkg-query -W -f='${Status}' git 2>/dev/null | grep -q "ok installed"; then
    echo "正在安装缺失的依赖: curl 和 git (需要 sudo)..."
    if ! (sudo apt update && sudo apt install curl git -y); then
        echo "依赖安装失败。脚本终止。"
        exit 1
    fi
else
    echo "依赖 (curl 和 git) 已安装。"
fi


# --- 1. 运行 pyenv-installer ---
echo "--- 正在运行 pyenv-installer ---"
curl https://pyenv.run | bash


# --- 2. 配置 .zshrc ---
ZSHRC_FILE="$HOME/.zshrc"

if [ ! -f "$ZSHRC_FILE" ]; then
    touch "$ZSHRC_FILE"
fi

# 检查配置是否已存在，防止重复添加
if ! grep -q 'pyenv init' "$ZSHRC_FILE"; then
    echo "正在配置 .zshrc..."
    
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


# --- 完成 ---
echo "---------------------------------"
echo "✅ Pyenv 脚本执行完毕！"
echo ""
echo "要完成安装并加载 pyenv，请执行以下操作之一："
echo "   1. (推荐) 重启您的终端。"
echo "   2. (临时) 在当前终端中运行: source $ZSHRC_FILE"
