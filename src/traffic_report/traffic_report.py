#!/usr/bin/env python3
"""
traffic_report module (moved from root traffic_report.py)
"""
import os
import sys
import subprocess
import requests
import datetime
import json
from dotenv import load_dotenv
import time
import argparse
import logging
from logging.handlers import RotatingFileHandler
import smtplib
from email.message import EmailMessage
import hmac
import hashlib
import base64
import socket
from typing import Optional

# Load environment variables from .env if present
load_dotenv()  # load default .env if present

def read_config():
    """Read configuration from environment into module-level variables.

    Call this after load_dotenv() so CLI-provided env file can be reloaded.
    """
    global INTERFACE, MONTHLY_LIMIT_GB, MONTHLY_LIMIT_MODE, MACHINE_NAME
    global FEISHU_WEBHOOK_URL, FEISHU_SECRET
    global TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
    global SMTP_SERVER, SMTP_PORT, SMTP_USER, SMTP_PASSWORD, SMTP_FROM, SMTP_TO, SMTP_USE_TLS
    global LOG_FILE, LOG_MAX_BYTES, LOG_BACKUP_COUNT

    INTERFACE = os.getenv("INTERFACE", "")
    try:
        MONTHLY_LIMIT_GB = float(os.getenv("MONTHLY_LIMIT_GB", "100"))
    except ValueError:
        MONTHLY_LIMIT_GB = 100.0
    MONTHLY_LIMIT_MODE = os.getenv("MONTHLY_LIMIT_MODE", "tx").lower()  # 'tx' or 'total'
    MACHINE_NAME = os.getenv("MACHINE_NAME") or socket.gethostname()

    # 飞书机器人配置 (从 .env 文件加载)
    FEISHU_WEBHOOK_URL = os.getenv("FEISHU_WEBHOOK_URL")
    FEISHU_SECRET = os.getenv("FEISHU_SECRET")

    # Telegram config
    TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
    TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID")

    # SMTP config (email)
    SMTP_SERVER = os.getenv("SMTP_SERVER")
    SMTP_PORT = int(os.getenv("SMTP_PORT", "0")) if os.getenv("SMTP_PORT") else None
    SMTP_USER = os.getenv("SMTP_USER")
    SMTP_PASSWORD = os.getenv("SMTP_PASSWORD")
    SMTP_FROM = os.getenv("SMTP_FROM")
    SMTP_TO = os.getenv("SMTP_TO")  # comma separated list
    SMTP_USE_TLS = os.getenv("SMTP_USE_TLS", "true").lower() in ("1", "true", "yes")

    # Logging
    LOG_FILE = os.getenv("LOG_FILE") or os.path.expanduser("~/traffic_report.log")
    log_max_bytes_env = os.getenv("LOG_MAX_BYTES")
    LOG_MAX_BYTES = int(log_max_bytes_env) if log_max_bytes_env and log_max_bytes_env.strip() else 5 * 1024 * 1024
    log_backup_env = os.getenv("LOG_BACKUP_COUNT")
    LOG_BACKUP_COUNT = int(log_backup_env) if log_backup_env and log_backup_env.strip() else 3

# Read config after initial default .env load
read_config()

# --------------------------
# Configuration (via environment variables) - easy to override per host
# - INTERFACE: Network interface name. If empty, the script will auto-detect.
# - MONTHLY_LIMIT_GB: Monthly limit in GB (defaults to 100)
# - MONTHLY_LIMIT_MODE: 'tx' (default) to count only tx, 'total' to count rx+tx
# - MACHINE_NAME: Human-friendly machine name. Falls back to hostname if not provided.
# - FEISHU_WEBHOOK_URL, FEISHU_SECRET: Feishu webhook config (optional)
# --------------------------

INTERFACE = os.getenv("INTERFACE", "")
try:
    MONTHLY_LIMIT_GB = float(os.getenv("MONTHLY_LIMIT_GB", "100"))
except ValueError:
    MONTHLY_LIMIT_GB = 100.0
MONTHLY_LIMIT_MODE = os.getenv("MONTHLY_LIMIT_MODE", "tx").lower()  # 'tx' or 'total'
MACHINE_NAME = os.getenv("MACHINE_NAME") or socket.gethostname()

# 飞书机器人配置 (从 .env 文件加载)
FEISHU_WEBHOOK_URL = os.getenv("FEISHU_WEBHOOK_URL")
FEISHU_SECRET = os.getenv("FEISHU_SECRET")

# Telegram config
TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID")

# SMTP config (email)
SMTP_SERVER = os.getenv("SMTP_SERVER")
SMTP_PORT = int(os.getenv("SMTP_PORT", "0")) if os.getenv("SMTP_PORT") else None
SMTP_USER = os.getenv("SMTP_USER")
SMTP_PASSWORD = os.getenv("SMTP_PASSWORD")
SMTP_FROM = os.getenv("SMTP_FROM")
SMTP_TO = os.getenv("SMTP_TO")  # comma separated list
SMTP_USE_TLS = os.getenv("SMTP_USE_TLS", "true").lower() in ("1", "true", "yes")

# Logging
LOG_FILE = os.getenv("LOG_FILE", os.path.expanduser("~/traffic_report.log"))
LOG_MAX_BYTES = int(os.getenv("LOG_MAX_BYTES", str(5 * 1024 * 1024)))
LOG_BACKUP_COUNT = int(os.getenv("LOG_BACKUP_COUNT", "3"))

# --------------------------

def get_vnstat_json(interface, mode):
    """获取 vnstat 的 JSON 格式输出"""
    try:
        result = subprocess.run(
            ["vnstat", "-i", interface, f"--json", mode],
            capture_output=True, text=True, check=True, encoding='utf-8'
        )
        return json.loads(result.stdout)
    except (subprocess.CalledProcessError, FileNotFoundError, json.JSONDecodeError) as e:
        logging.warning(f"获取 vnstat 数据时出错: {e}")
        return None


def interface_is_up_and_routable(iface: str) -> bool:
    """Check whether interface is UP and routable to the internet (approx).

    Strategy:
      - check `ip link show "iface"` for 'state UP'
      - check `ip -4 addr show dev "iface"` has an IPv4 address (not loopback, not link-local 169.254)
      - check `ip route get 8.8.8.8 dev <iface>` returns success
    """
    try:
        # Check interface state
        rr = subprocess.run(["/usr/bin/ip", "link", "show", iface], capture_output=True, text=True, check=True)
        link_out = rr.stdout
        if 'state UP' not in link_out and 'state UNKNOWN' not in link_out:
            return False
        # Check IPv4 address assigned
        rr = subprocess.run(["/usr/bin/ip", "-4", "addr", "show", "dev", iface], capture_output=True, text=True, check=True)
        if 'inet ' not in rr.stdout:
            return False
        # Check route to 8.8.8.8 via this iface (best-effort)
        try:
            rr = subprocess.run(["/usr/bin/ip", "route", "get", "8.8.8.8", "dev", iface], capture_output=True, text=True, check=True)
            if iface in rr.stdout:
                return True
            else:
                return False
        except Exception:
            # if route get fails, treat as not routable
            return False
    except Exception:
        return False


def format_bytes(Bytes):
    """将 Bytes 转换为可读格式"""
    if Bytes < 1024:
        return f"{Bytes} B"
    elif Bytes < 1024**2:
        return f"{Bytes/1024:.2f} KiB"
    elif Bytes < 1024**3:
        return f"{Bytes/1024**2:.2f} MiB"
    elif Bytes < 1024**4:
        return f"{Bytes/1024**3:.2f} GiB"
    else:
        return f"{Bytes/1024**4:.2f} TiB"


def create_progress_bar(percentage, length=100):
    """创建文本进度条"""
    percentage_clamped = max(0.0, min(1.0, percentage))
    filled_length = int(length * percentage_clamped)
    bar = '█' * filled_length + '-' * (length - filled_length)
    return f"[{bar}] {percentage_clamped:.1%}"


def gen_feishu_sign(timestamp, secret):
    """根据飞书文档计算签名"""
    string_to_sign = f"{timestamp}\n{secret}"
    hmac_code = hmac.new(string_to_sign.encode("utf-8"), digestmod=hashlib.sha256).digest()
    sign = base64.b64encode(hmac_code).decode('utf-8')
    return sign


def send_feishu_message(message):
    """发送飞书机器人消息"""
    if not FEISHU_WEBHOOK_URL:
        logging.info("飞书 Webhook URL 未配置，跳过发送。")
        return

    headers = {"Content-Type": "application/json"}
    payload = {
        "msg_type": "text",
        "content": {
            "text": message
        }
    }

    webhook_url = FEISHU_WEBHOOK_URL
    if FEISHU_SECRET:
        timestamp = int(time.time())
        sign = gen_feishu_sign(timestamp, FEISHU_SECRET)
        sep = '&' if '?' in webhook_url else '?'
        webhook_url = f"{webhook_url}{sep}timestamp={timestamp}&sign={sign}"

    try:
        response = requests.post(webhook_url, headers=headers, json=payload, timeout=15)
        response.raise_for_status()
        result = response.json()
        if result.get("code") == 0 or result.get("StatusCode") == 0:
            logging.info("飞书消息发送成功。")
        else:
            logging.warning(f"飞书消息发送失败: {result}")
    except requests.exceptions.RequestException as e:
        logging.warning(f"飞书消息发送失败: 网络请求错误 {e}")
    except Exception as e:
        logging.warning(f"飞书消息发送失败: {e}")


def send_telegram_message(message, dry_run=False):
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        logging.info("Telegram 配置未设置，跳过发送")
        return
    if dry_run:
        logging.info("dry-run: Telegram 消息发送被跳过")
        return
    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    payload = {
        "chat_id": TELEGRAM_CHAT_ID,
        "text": message
    }
    try:
        r = requests.post(url, json=payload, timeout=15)
        r.raise_for_status()
        logging.info("Telegram 消息发送成功")
    except Exception as e:
        logging.warning(f"Telegram 消息发送失败: {e}")


def send_email_message(subject, message, dry_run=False):
    if not SMTP_SERVER or not SMTP_TO:
        logging.info("SMTP 未配置，跳过发送")
        return
    if dry_run:
        logging.info("dry-run: Email 消息发送被跳过")
        return
    recipients = [s.strip() for s in SMTP_TO.split(',') if s.strip()]
    if not recipients:
        logging.info("SMTP_TO 未配置收件人，跳过发送")
        return
    msg = EmailMessage()
    msg['Subject'] = subject
    msg['From'] = SMTP_FROM or SMTP_USER or 'traffic_report@localhost'
    msg['To'] = ', '.join(recipients)
    msg.set_content(message)
    try:
        if SMTP_PORT and SMTP_USE_TLS:
            server = smtplib.SMTP(SMTP_SERVER, SMTP_PORT, timeout=15)
            server.starttls()
        elif SMTP_PORT:
            server = smtplib.SMTP(SMTP_SERVER, SMTP_PORT, timeout=15)
        else:
            server = smtplib.SMTP(SMTP_SERVER, timeout=15)
        if SMTP_USER and SMTP_PASSWORD:
            server.login(SMTP_USER, SMTP_PASSWORD)
        server.send_message(msg)
        server.quit()
        logging.info("Email 发送成功")
    except Exception as e:
        logging.warning(f"Email 发送失败: {e}")


def send_notifications(body, subject=None, channels=None, dry_run=False):
    if not channels:
        channels = []
        if FEISHU_WEBHOOK_URL:
            channels.append('feishu')
        if TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID:
            channels.append('telegram')
        if SMTP_SERVER and SMTP_TO:
            channels.append('email')
    if 'feishu' in channels:
        if dry_run:
            logging.info('dry-run: Feishu 消息发送被跳过')
        else:
            send_feishu_message(body)
    if 'telegram' in channels:
        send_telegram_message(body, dry_run=dry_run)
    if 'email' in channels:
        send_email_message(subject or '流量报告', body, dry_run=dry_run)


def setup_logging(log_file: str, dry_run=False):
    # 清理旧的 handlers（避免重复）
    root = logging.getLogger()
    while root.handlers:
        root.handlers.pop()

    root.setLevel(logging.INFO)
    fmt = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')

    # 只当运行在交互式终端时显示到控制台（例如用户手动运行时）
    if sys.stdout.isatty():
        ch = logging.StreamHandler(sys.stdout)
        ch.setLevel(logging.INFO)
        ch.setFormatter(fmt)
        root.addHandler(ch)

    if not dry_run:
        try:
            fh = RotatingFileHandler(log_file, maxBytes=LOG_MAX_BYTES, backupCount=LOG_BACKUP_COUNT)
            fh.setLevel(logging.INFO)
            fh.setFormatter(fmt)
            root.addHandler(fh)
        except PermissionError:
            # 如果无法写文件，仍然保留 console 输出作为 fallback
            logging.warning(f"无法写入日志文件 {log_file}，将仅输出到控制台")


def main():
    parser = argparse.ArgumentParser(description="vnstat 流量报告脚本")
    parser.add_argument('--no-notify', action='store_true', help='不发送任何通知')
    parser.add_argument('--dry-run', action='store_true', help='测试模式：不发送通知，也不写入系统日志')
    parser.add_argument('--notify', type=str, default='', help='指定通知渠道, 逗号分隔: feishu,telegram,email')
    parser.add_argument('--log-file', type=str, default=LOG_FILE, help='日志文件路径')
    parser.add_argument('--allow-any-interface', action='store_true', help='允许不严格检测 interface（使用首个非 loopback)）')
    parser.add_argument('--env-file', type=str, default='', help='Path to .env file to load before running')
    args = parser.parse_args()

    dry_run = args.dry_run
    no_notify = args.no_notify
    channels = [c.strip() for c in args.notify.split(',') if c.strip()] if args.notify else None
    allow_any_interface = args.allow_any_interface
    env_file = args.env_file

    # If an env file is provided, load it and re-read the configuration
    if env_file:
        load_dotenv(dotenv_path=env_file, override=True)
        read_config()
    setup_logging(args.log_file, dry_run=dry_run)
    logging.info('Starting traffic_report')
    if dry_run:
        logging.info('dry-run: 启用')
    if no_notify:
        logging.info('no-notify: 禁用通知')

    yesterday = datetime.date.today() - datetime.timedelta(days=1)
    today = datetime.date.today()
    current_month_id = datetime.date.today().strftime("%Y-%m")

    def detect_interface(allow_any: bool = False) -> Optional[str]:
        if INTERFACE:
            if allow_any:
                return INTERFACE
            if interface_is_up_and_routable(INTERFACE):
                return INTERFACE
            return None

        try:
            rr = subprocess.run(["/usr/bin/ip", "route", "get", "8.8.8.8"], capture_output=True, text=True, check=True)
            out = rr.stdout.strip()
            parts = out.split()
            if 'dev' in parts:
                dev_index = parts.index('dev')
                if dev_index + 1 < len(parts):
                    return parts[dev_index + 1]
        except Exception:
            pass

        try:
            for iface in os.listdir('/sys/class/net'):
                if iface == 'lo':
                    continue
                if iface.startswith('docker') or iface.startswith('veth') or iface.startswith('br-') or iface.startswith('virbr'):
                    continue
                if interface_is_up_and_routable(iface):
                    return iface
                if allow_any:
                    return iface
        except Exception:
            pass
        return None

    detected_interface = detect_interface(allow_any=allow_any_interface)
    if not detected_interface:
        logging.warning("未能自动检测网络接口，请设置 INTERFACE 环境变量（例如 'eth0'）并重试。")
        detected_interface = ""

    INTERFACE_TO_USE = detected_interface

    monthly_limit_mode = MONTHLY_LIMIT_MODE
    if monthly_limit_mode not in {'tx', 'total'}:
        logging.warning(f"警告: MONTHLY_LIMIT_MODE 值不正确: {monthly_limit_mode}，使用默认 'tx'")
        monthly_limit_mode = 'tx'

    logging.info(f"配置: 机器名={MACHINE_NAME}, 网卡={INTERFACE_TO_USE or INTERFACE}, 限额={MONTHLY_LIMIT_GB}GB, 计量模式={monthly_limit_mode}")

    if INTERFACE_TO_USE:
        daily_data = get_vnstat_json(INTERFACE_TO_USE, 'd')
        monthly_data = get_vnstat_json(INTERFACE_TO_USE, 'm')
    else:
        daily_data = None
        monthly_data = None

    report_parts = ["<at user_id='all'>所有人</at> "]
    report_parts.append(f"{MACHINE_NAME} 服务器流量报告\n")

    yesterday_report = f"网卡 {INTERFACE_TO_USE or INTERFACE} 昨日 ({yesterday.strftime('%Y-%m-%d')}) 流量:\n"
    if daily_data and daily_data.get("interfaces"):
        daily_traffic_list = daily_data["interfaces"][0].get("traffic", {}).get("day", [])
        yesterday_entry = next(
            (d for d in daily_traffic_list
                if d.get('date', {}).get('year') == yesterday.year and \
                   d.get('date', {}).get('month') == yesterday.month and \
                   d.get('date', {}).get('day') == yesterday.day),
            None)
        if yesterday_entry:
            yesterday_report += f"  接收 (rx): {format_bytes(yesterday_entry['rx'])}\n"
            yesterday_report += f"  发送 (tx): {format_bytes(yesterday_entry['tx'])}\n"
            yesterday_report += f"  总计: {format_bytes(yesterday_entry['rx'] + yesterday_entry['tx'])}\n"
        else:
            yesterday_report += "  未找到昨日数据。\n"
    else:
        yesterday_report += "  无法获取流量数据。\n"
    report_parts.append(yesterday_report)

    limit_scope = "出网 (tx)" if monthly_limit_mode == 'tx' else "总计 (rx+tx)"
    monthly_report = f"本月 ({current_month_id}) 累计流量 (限额: {MONTHLY_LIMIT_GB} GB, 计量: {limit_scope}):\n"
    if monthly_data and monthly_data.get("interfaces"):
        monthly_traffic_list = monthly_data["interfaces"][0].get("traffic", {}).get("month", [])
        current_month_entry = next(
            (m for m in monthly_traffic_list
                if m.get('date', {}).get('year') == today.year and \
                   m.get('date', {}).get('month') == today.month),
            None)
        if current_month_entry:
            rx_Bytes = current_month_entry.get('rx', 0)
            tx_Bytes = current_month_entry.get('tx', 0)
            limit_Bytes = MONTHLY_LIMIT_GB * 1024**3 if MONTHLY_LIMIT_GB > 0 else 0
            if monthly_limit_mode == 'tx':
                usage_value = tx_Bytes
            else:
                usage_value = rx_Bytes + tx_Bytes
            usage_percent = (usage_value / limit_Bytes) if (limit_Bytes > 0) else 0
            monthly_report += f"  接收 (rx): {format_bytes(rx_Bytes)}\n"
            monthly_report += f"  发送 (tx): {format_bytes(tx_Bytes)}\n"
            monthly_report += f"  总计: {format_bytes(rx_Bytes + tx_Bytes)}\n\n"
            monthly_report += f"本月 {limit_scope} 使用情况:\n"
            monthly_report += create_progress_bar(usage_percent)
        else:
            monthly_report += "  未找到本月数据。\n"
    else:
        monthly_report += "  无法获取流量数据。\n"
    report_parts.append(monthly_report)

    subject = f"[流量日报] {yesterday.strftime('%Y-%m-%d')}"
    body = "\n".join(report_parts)

    logging.info("--- 流量报告 ---")
    logging.info(body)
    logging.info("----------------")

    if not no_notify:
        send_notifications(body, subject=subject, channels=channels, dry_run=dry_run)
    else:
        logging.info('通知被禁用 (no-notify) — 未发送任何通知')


if __name__ == "__main__":
    main()
