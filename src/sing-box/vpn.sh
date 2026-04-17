#!/bin/bash

# Proxy management script for sing-box
# Port: 7897 (mixed proxy)

# Function to set proxy
set_proxy() {
    local PROXY_HOST="127.0.0.1"
    local PROXY_PORT="7897"
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
