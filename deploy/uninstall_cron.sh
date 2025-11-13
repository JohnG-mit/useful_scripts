#!/usr/bin/env bash
set -euo pipefail

# Uninstall cron job created by install_cron.sh
# Usage: sudo ./uninstall_cron.sh [user]

USER=${1:-$(whoami)}
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/traffic_report.py"

tmpfile=$(mktemp)
# Remove lines referencing the script
crontab -u "$USER" -l 2>/dev/null | grep -v "$SCRIPT" > "$tmpfile" || true
crontab -u "$USER" "$tmpfile"
rm -f "$tmpfile"

echo "Cron job entries referencing $SCRIPT have been removed for user $USER (if any existed)."
