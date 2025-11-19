#!/bin/bash

set -e

# Variables
SERVICE_NAME="sing-box"
INSTALL_DIR="$HOME/bin"
WORK_DIR="$HOME/service/$SERVICE_NAME"
RULES_DIR="$WORK_DIR/rules"
CONFIG_FILE="$WORK_DIR/config.json"
TEMPLATE_FILE="$(dirname "$0")/config_template.json"
GENERATE_SCRIPT="$(dirname "$0")/generate_config.py"
SYSTEMD_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SYSTEMD_DIR/$SERVICE_NAME.service"

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

# Check Python
if ! command -v python3 &> /dev/null; then
    error "Python3 is required but not found."
    exit 1
fi

# 1. Get Subscription File
echo "Please provide the path to your subscription file (txt)."
echo "This file should contain a list of subscription links (vless://, hysteria2://, tuic://)."
read -p "Path: " SUBSCRIPTION_PATH

# Expand ~ to home directory
SUBSCRIPTION_PATH="${SUBSCRIPTION_PATH/#\~/$HOME}"

if [ ! -f "$SUBSCRIPTION_PATH" ]; then
    error "File not found: $SUBSCRIPTION_PATH"
    exit 1
fi

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

    log "Downloading sing-box from $DOWNLOAD_URL..."
    mkdir -p "$INSTALL_DIR"
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
mkdir -p "$RULES_DIR"

# 4. Download Rules
# Rules will be downloaded automatically by sing-box using remote rule-sets.
# We just ensure the directory exists.
log "Rules directory prepared at $RULES_DIR"

# 5. Generate Config
log "Generating config.json..."
python3 "$GENERATE_SCRIPT" "$TEMPLATE_FILE" "$SUBSCRIPTION_PATH" "$CONFIG_FILE"

# 6. Setup Systemd Service
log "Setting up systemd service..."
mkdir -p "$SYSTEMD_DIR"
mkdir -p "$WORK_DIR/ui"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
ExecStart=$INSTALL_DIR/sing-box -D $WORK_DIR -C $WORK_DIR run
WorkingDirectory=$WORK_DIR
Restart=always
LimitNOFILE=infinity

[Install]
WantedBy=default.target
EOF
# Reload systemd
systemctl --user daemon-reload
systemctl --user enable "$SERVICE_NAME"
systemctl --user restart "$SERVICE_NAME"


log "sing-box service installed and started!"
log "You can check the status with: systemctl --user status $SERVICE_NAME"
log "Logs are available via: journalctl --user -u $SERVICE_NAME -f"
