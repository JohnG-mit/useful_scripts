# useful_scripts
Some useful scripts for linux operation and maintenance.

## traffic_report.py

快速部署说明：

1. 确保安装并初始化 vnstat (v2), requests, python-dotenv。
2. 配置 `.env`（或在系统环境变量中设置）以下字段：
	- MONTHLY_LIMIT_GB - 每月流量限额（默认 100）
	- MONTHLY_LIMIT_MODE - 'tx'（默认，仅计 tx）或 'total'（计 rx + tx）
	- MACHINE_NAME - 机器名（可选，如果不提供脚本会用 hostname）
	- INTERFACE - 指定网卡（可选，脚本会自动检测）
	- FEISHU_WEBHOOK_URL, FEISHU_SECRET - 飞书机器人（可选）
	- TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID - Telegram 通知（可选）
	- SMTP_SERVER, SMTP_PORT, SMTP_USER, SMTP_PASSWORD, SMTP_FROM, SMTP_TO - SMTP 邮件通知（可选）

示例 .env:
```
MONTHLY_LIMIT_GB=200
MONTHLY_LIMIT_MODE=total
MACHINE_NAME=my-prod-server
INTERFACE=
FEISHU_WEBHOOK_URL=https://open.feishu.cn/open-apis/bot/v2/hook/xxx
FEISHU_SECRET=xxx
``` 

运行:
```
python3 src/traffic_report/traffic_report.py
```

CLI 选项（支持 `--help`）:
    - `--env-file`：指定 dotenv 文件的路径，在运行前加载


安装 cron 示例:
```
sudo useful_scripts/deploy/install_cron.sh
```

卸载示例:
```
sudo useful_scripts/deploy/uninstall_cron.sh [user]
```

## sing-box 普通用户安装 (无 sudo)

该脚本允许普通用户在无 sudo 权限的情况下配置 sing-box 代理。

### 功能
1. 自动下载最新版 sing-box 并安装到 `~/bin`。
2. 自动下载 `geosite.dat` 和 `geoip.dat` 规则文件。
3. 根据提供的输入源生成最终配置文件 `config.json`（支持订阅链接文件，或 `@xxx.json` JSON 文件模式）。
4. 配置 systemd user service 实现开机自启和自动重启。
5. 日志通过 systemd journal 管理，自动轮转。

### 使用方法

1. 准备输入源（二选一）：
	- 订阅链接文本文件（例如 `subscribe.txt`），每行一个链接。
	- JSON 文件（例如 `sub.json`），在安装脚本提示时输入 `@sub.json`。
2. 运行安装脚本：

```bash
bash src/sing-box/install.sh
```

3. 脚本会提示输入路径：
	- 输入普通路径时按订阅链接文件处理。
	- 输入 `@xxx.json` 时按 JSON 模式处理。
4. 安装完成后，服务会自动启动。

JSON 模式会解析并应用 JSON 中的 `outbounds` 等核心字段到最终配置。

### 管理命令

- 启动服务: `systemctl --user start sing-box`
- 停止服务: `systemctl --user stop sing-box`
- 重启服务: `systemctl --user restart sing-box`
- 查看状态: `systemctl --user status sing-box`
- 查看日志: `journalctl --user -u sing-box -f`

### sb 命令菜单

安装脚本会自动安装 `sb` 命令到 `~/bin/sb`。

- `sb`：唤起交互菜单
- `sb s`：查看当前用户级 sing-box 服务状态
- `sb v`：查看当前 sing-box 内核版本
- `sb r`：重启当前用户级 sing-box 服务
- `sb upgrade`：更新 sing-box 内核（自动使用当前代理端口，更新后自动重启并打印新版本）
- `sb d`：打印当前 sing-box 工作目录
- `sb ip`：输出当前默认代理出口 IP（含地区信息）
- `sb speedtest`：测试当前默认代理速度
- `sb proxy`：打印当前可用代理并交互切换默认代理

代理切换补充：
- `sb proxy list`：仅打印当前可用代理和当前默认代理
- `sb proxy <序号>`：按序号切换默认代理
- `sb proxy <tag>`：按节点标签切换默认代理

`sb speedtest` 会优先调用本机已有的 `speedtest-cli`。
如果未找到 `speedtest-cli`，会根据系统架构自动下载官方 Ookla CLI 包：
`https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-$ARCH.tgz`

支持架构：`i386`、`x86_64`、`armel`、`armhf`、`aarch64`。
下载后会在 `~/bin` 安装 `speedtest`，并生成兼容入口 `speedtest-cli`。

### 注意事项
- 确保 `~/bin` 在你的 PATH 环境变量中（脚本会自动尝试添加）。
- 默认监听端口为 7897 (SOCKS/Mixed)。
