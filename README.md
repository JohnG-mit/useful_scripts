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
