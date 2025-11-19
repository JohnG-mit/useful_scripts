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
3. 根据提供的订阅文件（包含 `vless://`, `hysteria2://`, `tuic://` 链接）生成最终配置文件 `config.json`。
4. 配置 systemd user service 实现开机自启和自动重启。
5. 日志通过 systemd journal 管理，自动轮转。

### 使用方法

1. 准备一个包含订阅链接的文本文件（例如 `subscribe.txt`），每行一个链接。
2. 运行安装脚本：

```bash
bash src/sing-box/install.sh
```

3. 脚本会提示输入订阅文件的路径。
4. 安装完成后，服务会自动启动。

### 管理命令

- 启动服务: `systemctl --user start sing-box`
- 停止服务: `systemctl --user stop sing-box`
- 重启服务: `systemctl --user restart sing-box`
- 查看状态: `systemctl --user status sing-box`
- 查看日志: `journalctl --user -u sing-box -f`

### 注意事项
- 确保 `~/bin` 在你的 PATH 环境变量中（脚本会自动尝试添加）。
- 默认监听端口为 7897 (SOCKS/Mixed)。
