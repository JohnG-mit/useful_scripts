#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/apt-retry.sh
source "$SCRIPT_DIR/../lib/apt-retry.sh"

readonly DOCKER_APT_URL="https://download.docker.com/linux/ubuntu"
readonly DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
readonly DOCKER_SOURCE="/etc/apt/sources.list.d/docker.sources"
readonly DOCKER_DAEMON_DIR="/etc/docker"
readonly DOCKER_DAEMON_CONFIG="$DOCKER_DAEMON_DIR/daemon.json"
readonly DOCKER_PROXY_DIR="/etc/systemd/system/docker.service.d"
readonly DOCKER_PROXY_CONFIG="$DOCKER_PROXY_DIR/10-real-robot-eval-proxy.conf"
DOCKER_REPOSITORY_NEW=0

log() {
    printf '[INFO] %s\n' "$*"
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "缺少必需命令：$1"
}

configure_privileges() {
    if (( EUID == 0 )); then
        SUDO=()
        return
    fi

    require_command sudo
    SUDO=(sudo)
    log "需要管理员权限，正在请求 sudo 授权。"
    sudo -v
}

check_ubuntu() {
    [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"

    # shellcheck source=/etc/os-release
    source /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || die "此安装器仅支持 Ubuntu（检测到：${ID:-未知}）。"

    UBUNTU_RELEASE_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    [[ -n "$UBUNTU_RELEASE_CODENAME" ]] || die "无法确定 Ubuntu 发行版代号。"
}

remove_conflicting_packages() {
    local package
    local -a conflicts=(
        docker.io
        docker-doc
        docker-compose
        docker-compose-v2
        podman-docker
        containerd
        runc
    )
    local -a installed=()

    for package in "${conflicts[@]}"; do
        if dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii'; then
            installed+=("$package")
        fi
    done

    if (( ${#installed[@]} > 0 )); then
        log "正在移除冲突软件包：${installed[*]}"
        apt_get_retry "${SUDO[@]}" -- remove -y "${installed[@]}"
    else
        log "未发现冲突软件包。"
    fi
}

configure_docker_repository() {
    local architecture temp_keyring
    architecture="$(dpkg --print-architecture)"

    if ! "${SUDO[@]}" test -s "$DOCKER_KEYRING" || ! "${SUDO[@]}" test -s "$DOCKER_SOURCE"; then
        DOCKER_REPOSITORY_NEW=1
    fi

    log "正在安装软件源依赖。"
    apt_update_retry "${SUDO[@]}"
    apt_get_retry "${SUDO[@]}" -- install -y ca-certificates curl

    log "正在安装 Docker 官方 GPG 密钥。"
    temp_keyring="$(mktemp)"
    if ! curl -fsSL "$DOCKER_APT_URL/gpg" -o "$temp_keyring"; then
        rm -f -- "$temp_keyring"
        die "下载 Docker 官方 GPG 密钥失败。"
    fi

    "${SUDO[@]}" install -m 0755 -d /etc/apt/keyrings
    if ! "${SUDO[@]}" install -m 0644 "$temp_keyring" "$DOCKER_KEYRING"; then
        rm -f -- "$temp_keyring"
        die "安装 Docker 官方 GPG 密钥失败。"
    fi
    rm -f -- "$temp_keyring"

    log "正在配置 Docker 官方稳定版 apt 软件源。"
    printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: %s\n' \
        "$DOCKER_APT_URL" "$UBUNTU_RELEASE_CODENAME" "$architecture" "$DOCKER_KEYRING" \
        | "${SUDO[@]}" tee "$DOCKER_SOURCE" >/dev/null
}

install_docker() {
    local -a packages=(
        docker-ce
        docker-ce-cli
        containerd.io
        docker-buildx-plugin
        docker-compose-plugin
    )

    log "正在安装 Docker Engine 和插件。"
    if (( DOCKER_REPOSITORY_NEW )); then
        log "检测到新增的 Docker 软件源，强制刷新一次软件包索引。"
        apt_update_retry_force "${SUDO[@]}"
    else
        apt_update_retry "${SUDO[@]}"
    fi
    apt_get_retry "${SUDO[@]}" -- install -y "${packages[@]}"
}

escape_systemd_environment_value() {
    local value="$1"

    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] \
        || die "代理地址不能包含换行符。"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//%/%%}"
    printf '%s' "$value"
}

configure_docker_daemon_proxy() {
    local http_proxy_value https_proxy_value no_proxy_value
    local escaped_http_proxy escaped_https_proxy escaped_no_proxy

    http_proxy_value="${http_proxy:-${HTTP_PROXY:-}}"
    https_proxy_value="${https_proxy:-${HTTPS_PROXY:-$http_proxy_value}}"

    if [[ -z "$http_proxy_value" && -z "$https_proxy_value" ]]; then
        log "当前 Shell 未配置 HTTP/HTTPS 代理，跳过 Docker daemon 代理配置。"
        return
    fi

    no_proxy_value="${no_proxy:-${NO_PROXY:-localhost,127.0.0.1,::1}}"
    escaped_http_proxy="$(escape_systemd_environment_value "$http_proxy_value")"
    escaped_https_proxy="$(escape_systemd_environment_value "$https_proxy_value")"
    escaped_no_proxy="$(escape_systemd_environment_value "$no_proxy_value")"

    log "正在为 Docker daemon 配置当前 Shell 的代理。"
    "${SUDO[@]}" install -m 0755 -d "$DOCKER_PROXY_DIR"
    {
        printf '[Service]\n'
        [[ -z "$escaped_http_proxy" ]] \
            || printf 'Environment="HTTP_PROXY=%s"\n' "$escaped_http_proxy"
        [[ -z "$escaped_https_proxy" ]] \
            || printf 'Environment="HTTPS_PROXY=%s"\n' "$escaped_https_proxy"
        printf 'Environment="NO_PROXY=%s"\n' "$escaped_no_proxy"
    } | "${SUDO[@]}" tee "$DOCKER_PROXY_CONFIG" >/dev/null
}

configure_docker_daemon() {
    log "正在配置 Docker daemon（Harbor、NVIDIA runtime 和镜像加速）。"
    "${SUDO[@]}" install -m 0755 -d "$DOCKER_DAEMON_DIR"
    cat <<'JSON' | "${SUDO[@]}" tee "$DOCKER_DAEMON_CONFIG" >/dev/null
{
    "insecure-registries": ["harbor.lightwheel.net"],
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "args": []
        }
    },
    "registry-mirrors": [
        "https://docker.m.daocloud.io",
        "https://dockerproxy.com",
        "https://mirror.ccs.tencentyun.com"
    ]
}
JSON
}

restart_docker_daemon() {
    log "正在重载并重启 Docker daemon。"
    "${SUDO[@]}" systemctl daemon-reload
    "${SUDO[@]}" systemctl restart docker
}

verify_installation() {
    log "正在通过 hello-world 镜像验证安装。"
    "${SUDO[@]}" docker run --rm hello-world
}

configure_non_root_access() {
    local target_user

    if (( EUID == 0 )); then
        target_user="${SUDO_USER:-}"
    else
        target_user="$(id -un)"
    fi

    if [[ -z "$target_user" ]]; then
        log "未检测到可配置的非 root 登录用户，跳过 docker 用户组配置。"
        return
    fi

    if [[ "$(id -u "$target_user")" == 0 ]]; then
        log "未检测到可配置的非 root 登录用户，跳过 docker 用户组配置。"
        return
    fi

    if id -nG "$target_user" | grep -qw docker; then
        log "用户 $target_user 已在 docker 用户组中。"
    else
        log "正在将用户 $target_user 加入 docker 用户组。"
        "${SUDO[@]}" usermod -aG docker "$target_user"
    fi

    log "docker 用户组权限将在用户重新登录后生效。"
}

main() {
    require_command apt-get
    require_command dpkg
    require_command dpkg-query
    require_command grep
    require_command id
    require_command install
    require_command mktemp
    require_command rm
    require_command systemctl
    require_command tee
    require_command usermod

    check_ubuntu
    configure_privileges
    remove_conflicting_packages
    configure_docker_repository
    install_docker
    configure_docker_daemon
    configure_docker_daemon_proxy
    restart_docker_daemon
    configure_non_root_access
    verify_installation

    log "Docker Engine 安装成功。"
    log "Docker Compose 命令：docker compose"
}

main "$@"
