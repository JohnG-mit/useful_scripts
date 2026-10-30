#!/usr/bin/env bash
# Idempotent dependency setup for the useful_scripts repository.
# Runs after the repository is checked out. Safe to run repeatedly.
set -euo pipefail

cd "$(dirname "$0")/.."

# System packages:
# - iproute2: provides /usr/bin/ip, required by traffic_report for interface detection
# - vnstat:   traffic accounting queried by traffic_report
# - shellcheck: static analysis for the shell scripts
# - jq:       JSON inspection used when validating generated sing-box configs
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq iproute2 vnstat shellcheck jq

# Python dependencies for the singbox_config converter and traffic_report.
# The shell tooling calls the system `python3` directly, so install for it.
python3 -m pip install -r requirements.txt

echo "install.sh: environment ready"
