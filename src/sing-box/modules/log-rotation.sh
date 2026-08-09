#!/usr/bin/env bash
set -e

sb_rotate_logs() {
    local work_dir="${SB_WORK_DIR:-$HOME/service/sing-box}"
    local max_mb="${SINGBOX_LOG_MAX_SIZE_MB:-20}" retention="${SINGBOX_LOG_RETENTION_DAYS:-14}"
    local max_bytes timestamp log_file size rotated
    [ -d "$work_dir" ] || return 0
    [[ "$max_mb" =~ ^[0-9]+$ ]] && [ "$max_mb" -gt 0 ] || max_mb=20
    [[ "$retention" =~ ^[0-9]+$ ]] || retention=14
    max_bytes=$((max_mb * 1024 * 1024)); timestamp="$(date +%Y%m%d_%H%M%S)"
    for log_file in "$work_dir"/*.log; do
        [ -f "$log_file" ] || continue
        size="$(wc -c <"$log_file")"
        [ "$size" -ge "$max_bytes" ] || continue
        rotated="$log_file.$timestamp"
        cp -f "$log_file" "$rotated"
        : >"$log_file"
        gzip -f "$rotated"
    done
    find "$work_dir" -maxdepth 1 -type f -name '*.log.*.gz' -mtime +"$retention" -delete
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then sb_rotate_logs; fi
