#!/bin/bash

# 脚本出错时立即退出
set -e

# --- 预先请求 Sudo 权限 ---
echo "此脚本需要 sudo 权限来安装软件包 (zsh) 和更改默认 shell (chsh)。"
echo "将检查您的 sudo 权限，仅在凭据过期时提示输入密码。"

if sudo -v; then
    echo "Sudo 权限已确认。"
else
    echo "获取 sudo 权限失败。脚本终止。"
    exit 1
fi

# --- 检查依赖 ---
if ! command -v git &> /dev/null; then
    echo "错误：git 未安装。请先运行 'sudo apt install git' 安装。"
    exit 1
fi

# 确保 ZSH_CUSTOM 变量有默认值
ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

# --- 步骤 0: 安装 zsh ---
echo "--- 步骤 0: 安装 zsh ---"
echo "正在安装 zsh (需要 sudo)..."
if ! (sudo apt update && sudo apt install zsh -y); then
    echo "zsh 安装失败。脚本终止。"
    exit 1
fi
echo "zsh 安装成功。"

# --- 步骤 1: 安装 Oh My Zsh 并创建 .zshrc ---
echo "--- 步骤 1: 安装 Oh My Zsh ---"
if [ -d "$HOME/.oh-my-zsh" ]; then
    echo "Oh My Zsh 目录 ($HOME/.oh-my-zsh) 已存在, 跳过 clone。"
else
    git clone https://github.com/robbyrussell/oh-my-zsh.git "$HOME/.oh-my-zsh"
fi

if [ -f "$HOME/.zshrc" ]; then
    echo "发现已存在的 .zshrc 文件。正在备份为 .zshrc.bak..."
    mv "$HOME/.zshrc" "$HOME/.zshrc.bak"
fi
cp "$HOME/.oh-my-zsh/templates/zshrc.zsh-template" "$HOME/.zshrc"
echo "Oh My Zsh 安装并配置 .zshrc 完毕。"

# --- 步骤 2: 修改主题 ---
echo "--- 步骤 2: 修改 Zsh 主题 ---"
sed -i 's/^ZSH_THEME="robbyrussell"$/ZSH_THEME="af-magic"/' "$HOME/.zshrc"
echo "主题已设置为 af-magic。"

# --- 步骤 3: 设置默认 shell ---
echo "--- 步骤 3: 设置默认 shell ---"
ZSH_PATH=$(which zsh)
if [ -z "$ZSH_PATH" ]; then
    echo "未找到 zsh, 无法更改 shell。脚本终止。"
    exit 1
fi

if [ "$SHELL" == "$ZSH_PATH" ]; then
    echo "默认 shell 已经是 zsh, 跳过。"
else
    echo "正在更改默认 shell (需要 sudo)..."
    if ! sudo chsh -s "$ZSH_PATH" "$USER"; then
        echo "警告：更改默认 shell 失败。请检查您的设置。"
        # 不终止脚本，继续执行其他步骤
    else
        echo "默认 shell 已更改为 $ZSH_PATH。"
    fi
fi

# --- 步骤 4: 设置 tmux 默认 shell ---
echo "--- 步骤 4: 设置 tmux 默认 shell ---"
if [ -f "$HOME/.tmux.conf" ]; then
    echo "备份 .tmux.conf 为 .tmux.conf.bak"
    cp "$HOME/.tmux.conf" "$HOME/.tmux.conf.bak"
fi
echo "" >> "$HOME/.tmux.conf" # 添加一个换行符以防万一
echo "# 设置 zsh 为默认 shell (由 setup_zsh.sh 添加)" >> "$HOME/.tmux.conf"
echo "set-option -g default-shell $ZSH_PATH" >> "$HOME/.tmux.conf"
echo "已将 tmux 默认 shell 设置为 $ZSH_PATH。"

# --- 步骤 5 & 6: 安装插件 ---
echo "--- 步骤 5 & 6: 安装 zsh 插件 ---"
PLUGINS_DIR="$ZSH_CUSTOM/plugins"

# 插件 1: zsh-autosuggestions
if [ -d "$PLUGINS_DIR/zsh-autosuggestions" ]; then
    echo "zsh-autosuggestions 插件已存在, 跳过。"
else
    git clone https://github.com/zsh-users/zsh-autosuggestions "$PLUGINS_DIR/zsh-autosuggestions"
fi

# 插件 2: zsh-syntax-highlighting
if [ -d "$PLUGINS_DIR/zsh-syntax-highlighting" ]; then
    echo "zsh-syntax-highlighting 插件已存在, 跳过。"
else
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$PLUGINS_DIR/zsh-syntax-highlighting"
fi
echo "插件安装完毕。"

# --- 步骤 7: 配置插件 ---
echo "--- 步骤 7: 配置插件 ---"
# 修改 plugins=(...) 数组
sed -i 's/^plugins=(git)$/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' "$HOME/.zshrc"

# 添加 source 行
echo "
# --- 步骤 7 中添加的插件 source ---
source $ZSH_CUSTOM/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source $ZSH_CUSTOM/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
" >> "$HOME/.zshrc"
echo "插件已在 .zshrc 中配置。"

# --- 步骤 8: 添加 Alias ---
echo "--- 步骤 8: 添加 Alias ---"
# 使用 cat 和 EOF 来追加所有 alias
cat <<EOF >> "$HOME/.zshrc"

alias ll='ls -alFh'
alias la='ls -A'
alias l='ls -CF'
alias cin="mamba activate"
alias cout="mamba deactivate"
EOF
echo "Alias 添加完毕。"

# --- 完成 ---
echo "---------------------------------"
echo "✅ Zsh 环境配置脚本执行完毕！"
echo ""
echo "重要：要使更改完全生效，您需要注销当前会ht会话并重新登录。"
echo "或者，您可以先输入 'zsh' 来启动一个新的 zsh 会话。"
