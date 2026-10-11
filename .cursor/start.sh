#!/usr/bin/env bash
# Per-boot service startup. The Cloud Agent VM does not run systemd as PID 1,
# so start vnstat's daemon directly. Idempotent: skips if already running.
set -euo pipefail

if pgrep -x vnstatd >/dev/null 2>&1; then
  echo "start.sh: vnstatd already running"
  exit 0
fi

# vnstatd needs root to read interface counters and write /var/lib/vnstat.
sudo vnstatd -d
echo "start.sh: vnstatd started"
