#!/bin/bash

# Proxy management script for sing-box

SERVICE_NAME="sing-box"
WORK_DIR="$HOME/service/$SERVICE_NAME"
CONFIG_FILE="$WORK_DIR/config.json"

get_mixed_port() {
    if [ ! -f "$CONFIG_FILE" ] || ! command -v python3 >/dev/null 2>&1; then
        echo "7897"
        return
    fi

    python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null || echo "7897"
import json
import sys

config_path = sys.argv[1]

try:
    with open(config_path, "r", encoding="utf-8") as f:
        data = json.load(f)
    for inbound in data.get("inbounds", []):
        if inbound.get("type") == "mixed":
            port = inbound.get("listen_port")
            if isinstance(port, int) and port > 0:
                print(port)
                raise SystemExit(0)
except Exception:
    pass

print(7897)
PY
}

# Function to set proxy
set_proxy() {
    local PROXY_HOST="127.0.0.1"
    local PROXY_PORT
    PROXY_PORT="$(get_mixed_port)"
    local HTTP_PROXY="http://${PROXY_HOST}:${PROXY_PORT}"
    local SOCKS_PROXY="socks5://${PROXY_HOST}:${PROXY_PORT}"
    
    # Set HTTP/HTTPS proxy
    export http_proxy="${HTTP_PROXY}"
    export https_proxy="${HTTP_PROXY}"
    export HTTP_PROXY="${HTTP_PROXY}"
    export HTTPS_PROXY="${HTTP_PROXY}"
    
    # Set SOCKS proxy
    export all_proxy="${SOCKS_PROXY}"
    export ALL_PROXY="${SOCKS_PROXY}"
    
    # Set no proxy for local addresses
    export no_proxy="localhost,127.0.0.1,172.18.0.0/16,192.168.0.0/16,10.0.0.0/8"
    export NO_PROXY="localhost,127.0.0.1,172.18.0.0/16,192.168.0.0/16,10.0.0.0/8"
    
    echo "✓ Proxy enabled:"
    echo "  HTTP/HTTPS: ${HTTP_PROXY}"
    echo "  SOCKS5: ${SOCKS_PROXY}"
    echo "  No proxy: ${no_proxy}"
}

# Function to unset proxy
unset_proxy() {
    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset all_proxy
    unset ALL_PROXY
    unset no_proxy
    unset NO_PROXY
    
    echo "✓ Proxy disabled"
}

# Function to show current proxy status
show_proxy() {
    echo "Current proxy settings:"
    if [ -n "$http_proxy" ]; then
        echo "  http_proxy: ${http_proxy}"
        echo "  https_proxy: ${https_proxy}"
        echo "  all_proxy: ${all_proxy}"
        echo "  no_proxy: ${no_proxy}"
    else
        echo "  No proxy configured"
    fi
}

# Show usage if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "This script should be sourced, not executed directly."
    echo "Usage:"
    echo "  source $0"
    echo "  set_proxy    # Enable proxy"
    echo "  unset_proxy  # Disable proxy"
    echo "  show_proxy   # Show current proxy status"
    exit 1
fi
