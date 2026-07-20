#!/bin/bash

set -e

# One-click fcitx5 + rime Chinese input method installer.
# - Installs fcitx5 and the rime engine via apt
# - Sets fcitx5 as the system input method framework (env vars + autostart)
# - Makes rime the default input schema (simplified Chinese)
# - Applies custom rime config so special symbols never trigger a
#   full/half-width candidate menu, and comma/period adapt to CN/EN mode

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RIME_TEMPLATE_DIR="$SCRIPT_DIR/rime"
RIME_USER_DIR="$HOME/.local/share/fcitx5/rime"
FCITX5_CONFIG_DIR="$HOME/.config/fcitx5"
FCITX5_PROFILE="$FCITX5_CONFIG_DIR/profile"
AUTOSTART_DIR="$HOME/.config/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/fcitx5.desktop"
ENV_DIR="$HOME/.config/environment.d"
ENV_FILE="$ENV_DIR/fcitx5.conf"
XPROFILE="$HOME/.xprofile"
INSTALL_DIR="$HOME/bin"
IM_SCRIPT="$SCRIPT_DIR/im.sh"

RIME_CONFIG_FILES=(
    "default.custom.yaml"
    "luna_pinyin.custom.yaml"
    "symbols.custom.yaml"
)

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

require_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "Missing command: $cmd"
        exit 1
    fi
}

install_packages() {
    if ! command -v apt-get >/dev/null 2>&1; then
        warn "apt-get not found. Skipping package installation."
        warn "Please ensure fcitx5 and fcitx5-rime are installed by your package manager."
        return
    fi

    local packages=(fcitx5 fcitx5-chinese-addons fcitx5-rime fcitx5-config-qt)
    local missing=()
    local pkg

    for pkg in "${packages[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        log "fcitx5 and rime packages already installed"
        return
    fi

    local sudo_cmd=""
    if [ "$(id -u)" -ne 0 ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            error "Root privileges required to install: ${missing[*]}"
            error "Install them manually: apt-get install -y ${missing[*]}"
            exit 1
        fi
        sudo_cmd="sudo"
    fi

    log "Installing packages: ${missing[*]}"
    $sudo_cmd apt-get update
    $sudo_cmd apt-get install -y "${missing[@]}"
}

set_environment() {
    mkdir -p "$ENV_DIR"

    log "Writing input method environment variables to $ENV_FILE..."
    cat > "$ENV_FILE" <<'EOF'
# Set fcitx5 as the input method framework (managed by useful_scripts)
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
GLFW_IM_MODULE=ibus
EOF

    # X11 sessions may not read environment.d; mirror into ~/.xprofile.
    local marker="# useful_scripts fcitx5 input method"
    if [ -f "$XPROFILE" ] && grep -Fq "$marker" "$XPROFILE"; then
        log "fcitx5 env already present in $XPROFILE"
    else
        log "Appending fcitx5 env to $XPROFILE..."
        {
            echo ""
            echo "$marker"
            echo 'export GTK_IM_MODULE=fcitx'
            echo 'export QT_IM_MODULE=fcitx'
            echo 'export XMODIFIERS=@im=fcitx'
        } >> "$XPROFILE"
    fi
}

setup_autostart() {
    mkdir -p "$AUTOSTART_DIR"

    log "Configuring fcitx5 autostart at $AUTOSTART_FILE..."
    cat > "$AUTOSTART_FILE" <<'EOF'
[Desktop Entry]
Type=Application
Name=Fcitx 5
Exec=fcitx5
Icon=fcitx
Terminal=false
X-GNOME-Autostart-Phase=Applications
X-GNOME-Autostart-enabled=true
EOF
}

set_default_profile() {
    mkdir -p "$FCITX5_CONFIG_DIR"

    log "Setting rime as the default input method in $FCITX5_PROFILE..."
    cat > "$FCITX5_PROFILE" <<'EOF'
[Groups/0]
# Group Name
Name=默认
# Layout
Default Layout=us
# Default Input Method
DefaultIM=rime

[Groups/0/Items/0]
# Name
Name=keyboard-us
# Layout
Layout=

[Groups/0/Items/1]
# Name
Name=rime
# Layout
Layout=

[GroupOrder]
0=默认
EOF
}

install_rime_config() {
    mkdir -p "$RIME_USER_DIR"

    local file src dest backup
    for file in "${RIME_CONFIG_FILES[@]}"; do
        src="$RIME_TEMPLATE_DIR/$file"
        dest="$RIME_USER_DIR/$file"

        if [ ! -f "$src" ]; then
            error "Rime config template not found: $src"
            exit 1
        fi

        if [ -f "$dest" ] && ! cmp -s "$src" "$dest"; then
            backup="$dest.bak.$(date +%Y%m%d_%H%M%S)"
            cp "$dest" "$backup"
            log "Backup created: $backup"
        fi

        install -m 644 "$src" "$dest"
        log "Installed rime config: $dest"
    done
}

deploy_rime() {
    if [ ! -f "$IM_SCRIPT" ]; then
        error "im helper script not found: $IM_SCRIPT"
        exit 1
    fi

    log "Installing im command to $INSTALL_DIR/im..."
    mkdir -p "$INSTALL_DIR"
    install -m 755 "$IM_SCRIPT" "$INSTALL_DIR/im"

    log "Rebuilding rime and reloading fcitx5..."
    bash "$INSTALL_DIR/im" deploy || warn "Rime deploy reported an issue; check 'im deploy' output."
}

print_summary() {
    log "fcitx5 + rime input method installed."
    log "Default schema: rime luna_pinyin (simplified Chinese)"
    log "Toggle input method: Ctrl+Space   |   Schema menu: F4"
    warn "Log out and back in (or reboot) so the display server picks up the input method env vars."
    log "Rebuild config anytime with: im deploy"
}

main() {
    require_command install

    install_packages
    set_environment
    setup_autostart
    set_default_profile
    install_rime_config
    deploy_rime
    print_summary
}

main "$@"
