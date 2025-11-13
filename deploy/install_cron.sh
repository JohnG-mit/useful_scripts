#!/usr/bin/env bash
set -euo pipefail

# Basic cron installer for traffic_report.py
# Usage: sudo ./install_cron.sh [user]

USER=${1:-$(whoami)}
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/src/traffic_report/traffic_report.py"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ $# -ge 2 ]]; then
	# optionally pass env file as argument: ./install_cron.sh user /path/to/.env
	ENV_FILE=${2}
fi
CRON_CMD="/usr/bin/env zsh -lc 'cd $SCRIPT_DIR && $(pyenv which python3) $SCRIPT --env-file $ENV_FILE >> $SCRIPT_DIR/logs/traffic_report.log 2>&1'"

echo "Installing cron job for user: $USER"
CRONENTRY="22 1 * * * $CRON_CMD"
	tmpfile=$(mktemp)
	# Remove any existing cron entries pointing to the script to avoid duplicates
	crontab -u "$USER" -l 2>/dev/null | grep -v "$SCRIPT" > "$tmpfile" || true
echo "$CRONENTRY" >> "$tmpfile"
crontab -u "$USER" "$tmpfile"
rm -f "$tmpfile"
echo "Cron job installed: $CRONENTRY"
echo "Ensure $ENV_FILE exists and contains your config (or set envs globally)."
