#!/bin/bash

set -e

SERVICE_NAME="sing-box"
WORK_DIR="$HOME/service/$SERVICE_NAME"

# Default policy:
# - Check all *.log files under $WORK_DIR
# - Rotate when size exceeds 20 MB
# - Keep compressed archives for 14 days
MAX_SIZE_MB="${SINGBOX_LOG_MAX_SIZE_MB:-20}"
RETENTION_DAYS="${SINGBOX_LOG_RETENTION_DAYS:-14}"

if [ ! -d "$WORK_DIR" ]; then
    exit 0
fi

if ! [[ "$MAX_SIZE_MB" =~ ^[0-9]+$ ]] || [ "$MAX_SIZE_MB" -le 0 ]; then
    MAX_SIZE_MB=20
fi

if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || [ "$RETENTION_DAYS" -lt 0 ]; then
    RETENTION_DAYS=14
fi

max_bytes=$((MAX_SIZE_MB * 1024 * 1024))
timestamp="$(date +%Y%m%d_%H%M%S)"

for log_file in "$WORK_DIR"/*.log; do
    [ -f "$log_file" ] || continue

    size_bytes="$(wc -c < "$log_file")"
    if [ "$size_bytes" -lt "$max_bytes" ]; then
        continue
    fi

    rotated_file="${log_file}.${timestamp}"

    # copytruncate avoids reopening file descriptors held by sing-box.
    cp -f "$log_file" "$rotated_file"
    : > "$log_file"
    gzip -f "$rotated_file"
done

find "$WORK_DIR" -maxdepth 1 -type f -name "*.log.*.gz" -mtime +"$RETENTION_DAYS" -delete
