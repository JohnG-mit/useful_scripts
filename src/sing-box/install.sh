#!/bin/bash

set -e

# Variables
SERVICE_NAME="sing-box"
INSTALL_DIR="$HOME/bin"
WORK_DIR="$HOME/service/$SERVICE_NAME"
CONFIG_FILE="$WORK_DIR/config.json"
TEMPLATE_FILE="$(dirname "$0")/config_template.json"
GENERATE_SCRIPT="$(dirname "$0")/generate_config.py"
IMPORT_JSON_SCRIPT="$(dirname "$0")/import_outbounds_json.py"
SETUP_SERVICE_SCRIPT="$(dirname "$0")/setup_user_service.sh"
SETUP_LOGROTATE_SCRIPT="$(dirname "$0")/setup_user_logrotate.sh"
SB_SCRIPT="$(dirname "$0")/sb.sh"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

is_port_in_use() {
    local port="$1"

    if command -v ss >/dev/null 2>&1; then
        ss -ltn "sport = :$port" 2>/dev/null | tail -n +2 | grep -q .
        return
    fi

    if command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
        return
    fi

    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | grep -E "[.:]$port[[:space:]]" >/dev/null
        return
    fi

    error "Neither ss, lsof nor netstat is available to detect port usage."
    exit 1
}

find_available_port() {
    local start_port="$1"
    local port="$start_port"

    while is_port_in_use "$port"; do
        port=$((port + 1))
    done

    echo "$port"
}

stop_existing_singbox() {
    local service_active="false"
    local process_exists="false"

    if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        service_active="true"
    fi

    if command -v pgrep >/dev/null 2>&1 && pgrep -u "$USER" -x sing-box >/dev/null 2>&1; then
        process_exists="true"
    fi

    if [ "$service_active" = "false" ] && [ "$process_exists" = "false" ]; then
        return
    fi

    if [ "$service_active" = "true" ]; then
        log "Stopping existing user-level sing-box service..."
        systemctl --user stop "$SERVICE_NAME" || true
    fi

    if [ "$process_exists" = "true" ]; then
        log "Terminating existing sing-box process..."
        pkill -u "$USER" -x sing-box || true
    fi
}

# Check Python
if ! command -v python3 &> /dev/null; then
    error "Python3 is required but not found."
    exit 1
fi

mkdir -p "$INSTALL_DIR"

# 1. Get Subscription File
echo "Please provide one of the following input sources:"
echo "1) Subscription links file path (txt, one link per line: vless://, hysteria2://, tuic://)"
echo "2) JSON file path prefixed with @ (example: @sub.json)"
read -p "Path: " INPUT_PATH

# Trim leading/trailing whitespace to avoid accidental parse failures.
INPUT_PATH="$(printf '%s' "$INPUT_PATH" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

SOURCE_MODE="links"

case "$INPUT_PATH" in
    @*)
        SOURCE_MODE="json"
        INPUT_PATH="${INPUT_PATH#@}"
        ;;
esac

# Expand ~ to home directory
SUBSCRIPTION_PATH="${INPUT_PATH/#\~/$HOME}"

if [ "$SOURCE_MODE" = "links" ] && [ "${SUBSCRIPTION_PATH%.json}" != "$SUBSCRIPTION_PATH" ]; then
    SOURCE_MODE="json"
    log "Detected .json file path, switching to JSON import mode."
fi

# Safety fallback: if path still contains @ prefix, strip it and force JSON mode.
if [ ! -f "$SUBSCRIPTION_PATH" ] && [ "${SUBSCRIPTION_PATH#@}" != "$SUBSCRIPTION_PATH" ]; then
    SOURCE_MODE="json"
    SUBSCRIPTION_PATH="${SUBSCRIPTION_PATH#@}"
fi

if [ ! -f "$SUBSCRIPTION_PATH" ]; then
    error "File not found: $SUBSCRIPTION_PATH"
    exit 1
fi

# Stop any running user-level sing-box before reinstalling.
stop_existing_singbox

# 2. Download and Install sing-box
if [ -f "$INSTALL_DIR/sing-box" ]; then
    log "sing-box binary already exists at $INSTALL_DIR/sing-box. Skipping download."
else
    log "Checking for latest sing-box release..."

    # Detect Arch
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            SB_ARCH="amd64"
            ;;
        aarch64)
            SB_ARCH="arm64"
            ;;
        *)
            error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac

    # Get Download URL using Python
    DOWNLOAD_URL=$(python3 -c "
import urllib.request, json, sys
try:
    url = 'https://api.github.com/repos/SagerNet/sing-box/releases/latest'
    with urllib.request.urlopen(url) as response:
        data = json.loads(response.read().decode())
        for asset in data['assets']:
            if 'linux-$SB_ARCH.tar.gz' in asset['name']:
                print(asset['browser_download_url'])
                sys.exit(0)
except Exception as e:
    print(e, file=sys.stderr)
    sys.exit(1)
")

    if [ -z "$DOWNLOAD_URL" ]; then
        error "Failed to find download URL for sing-box."
        exit 1
    fi
    DOWNLOAD_URL="https://ghproxy.net/${DOWNLOAD_URL}"

    log "Downloading sing-box from $DOWNLOAD_URL..."
    curl -L -o sing-box.tar.gz "$DOWNLOAD_URL"

    log "Installing sing-box..."
    tar -xzf sing-box.tar.gz
    # Find the binary inside the extracted folder
    EXTRACTED_DIR=$(tar -tf sing-box.tar.gz | head -1 | cut -f1 -d"/")
    mv "$EXTRACTED_DIR/sing-box" "$INSTALL_DIR/"
    rm -rf sing-box.tar.gz "$EXTRACTED_DIR"
    chmod +x "$INSTALL_DIR/sing-box"
fi

# Add to PATH if not present
if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
    log "Adding $HOME/bin to PATH in .zshrc..."
    echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.zshrc"
    export PATH="$HOME/bin:$PATH"
fi

# 3. Prepare Directories
log "Preparing directories..."
mkdir -p "$WORK_DIR"

# 4. Generate Config
if [ "$SOURCE_MODE" = "json" ]; then
    if [ ! -f "$IMPORT_JSON_SCRIPT" ]; then
        error "JSON import script not found: $IMPORT_JSON_SCRIPT"
        exit 1
    fi

    log "Generating config.json from JSON source..."
    python3 "$IMPORT_JSON_SCRIPT" "$TEMPLATE_FILE" "$SUBSCRIPTION_PATH" "$CONFIG_FILE"
else
    log "Generating config.json from subscription links..."
    python3 "$GENERATE_SCRIPT" "$TEMPLATE_FILE" "$SUBSCRIPTION_PATH" "$CONFIG_FILE"
fi

# 4.1 Resolve local port conflicts
MIXED_PORT=$(find_available_port 7897)
CLASH_API_PORT=$(find_available_port 9090)

if [ "$MIXED_PORT" -ne 7897 ]; then
    log "Port 7897 is in use, switched mixed inbound port to $MIXED_PORT"
else
    log "Port 7897 is available, using mixed inbound port 7897"
fi

if [ "$CLASH_API_PORT" -ne 9090 ]; then
    log "Port 9090 is in use, switched clash API port to $CLASH_API_PORT"
else
    log "Port 9090 is available, using clash API port 9090"
fi

python3 - "$CONFIG_FILE" "$MIXED_PORT" "$CLASH_API_PORT" <<'PY'
import json
import sys

config_path = sys.argv[1]
mixed_port = int(sys.argv[2])
clash_api_port = int(sys.argv[3])

with open(config_path, "r", encoding="utf-8") as f:
    config = json.load(f)

for inbound in config.get("inbounds", []):
    if inbound.get("type") == "mixed":
        inbound["listen_port"] = mixed_port
        break

clash_api = config.get("experimental", {}).get("clash_api", {})
external_controller = clash_api.get("external_controller")
if isinstance(external_controller, str) and ":" in external_controller:
    host = external_controller.rsplit(":", 1)[0]
else:
    host = "127.0.0.1"
clash_api["external_controller"] = f"{host}:{clash_api_port}"

if "experimental" not in config:
    config["experimental"] = {}
config["experimental"]["clash_api"] = clash_api

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
PY

# 5. Install sb command
if [ ! -f "$SB_SCRIPT" ]; then
    error "sb script not found: $SB_SCRIPT"
    exit 1
fi

log "Installing sb command to $INSTALL_DIR/sb..."
install -m 755 "$SB_SCRIPT" "$INSTALL_DIR/sb"

# 6. Setup Systemd Service
if [ ! -f "$SETUP_SERVICE_SCRIPT" ]; then
    error "Service setup script not found: $SETUP_SERVICE_SCRIPT"
    exit 1
fi

log "Setting up user-level systemd service..."
bash "$SETUP_SERVICE_SCRIPT"

# 7. Setup user-level log rotation timer
if [ ! -f "$SETUP_LOGROTATE_SCRIPT" ]; then
    error "Log rotation setup script not found: $SETUP_LOGROTATE_SCRIPT"
    exit 1
fi

log "Setting up user-level log rotation timer..."
bash "$SETUP_LOGROTATE_SCRIPT"

log "sing-box service installed and started!"
log "Run 'sb' to open the command menu."
log "You can check the status with: sb s"
log "Logs are available via: journalctl --user -u $SERVICE_NAME -f"
