#!/usr/bin/env bash

MO_CORE_REPO="${MO_CORE_REPO:-MetaCubeX/mihomo}"
MO_UI_REPO="${MO_UI_REPO:-Zephyruso/zashboard}"
MO_UI_NAME="zashboard"

# Prefix a GitHub URL with the configured mirror.
mo_mirror_url() {
    local url="$1"
    if [ -n "${MO_GH_PROXY:-}" ]; then
        printf '%s%s\n' "${MO_GH_PROXY%/}/" "$url"
    else
        printf '%s\n' "$url"
    fi
}

# Download with mirror first, then direct GitHub as a fallback.
mo_download() {
    local url="$1" output="$2" mirrored
    case "$url" in
        https://*) ;;
        *) mo_error "拒绝从非 HTTPS 地址下载：$url"; return 1 ;;
    esac
    mo_require_command curl || return 1
    mirrored="$(mo_mirror_url "$url")"
    # Abort stalled transfers (< 2 KB/s for 20 s) so a slow mirror falls back to GitHub quickly.
    local opts=(--proto '=https' --tlsv1.2 -fL --retry 2 --connect-timeout 15 --max-time 300
        --speed-time 20 --speed-limit 2048 -sS)
    if curl "${opts[@]}" "$mirrored" -o "$output"; then
        return 0
    fi
    if [ "$mirrored" != "$url" ]; then
        mo_warn "镜像下载失败，回退到直连 GitHub：$url"
        curl "${opts[@]}" "$url" -o "$output"
        return
    fi
    return 1
}

mo_latest_version() {
    local temp version
    if [ -n "${MO_VERSION:-}" ]; then
        printf '%s\n' "$MO_VERSION"
        return 0
    fi
    temp="$(mktemp "${TMPDIR:-/tmp}/mihomo-version.XXXXXX")" || return 1
    if mo_download "https://github.com/$MO_CORE_REPO/releases/latest/download/version.txt" "$temp" 2>/dev/null; then
        version="$(tr -d '[:space:]' <"$temp")"
    fi
    rm -f "$temp"
    case "${version:-}" in
        v[0-9]*) printf '%s\n' "$version"; return 0 ;;
    esac
    # Fallback: resolve the /releases/latest redirect.
    version="$(curl -fsSIL --max-time 20 -o /dev/null -w '%{url_effective}' \
        "https://github.com/$MO_CORE_REPO/releases/latest" 2>/dev/null | sed 's#.*/tag/##')"
    case "$version" in
        v[0-9]*) printf '%s\n' "$version"; return 0 ;;
    esac
    mo_error "无法获取 mihomo 最新版本号"
    return 1
}

mo_current_version() {
    [ -x "$MO_BINARY" ] || return 1
    "$MO_BINARY" -v 2>/dev/null | head -n1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9._-]*' | head -n1
}

# Highest amd64 micro-architecture level supported by this CPU: v3, v2 or v1.
mo_amd64_level() {
    local flags
    flags="$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null || true)"
    has() { case " $flags " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
    if has avx2 && has bmi1 && has bmi2 && has fma && has movbe && has f16c && has xsave && { has abm || has lzcnt; }; then
        echo v3
    elif has sse4_1 && has sse4_2 && has ssse3 && has popcnt && has cx16 && has lahf_lm; then
        echo v2
    else
        echo v1
    fi
    unset -f has
}

# Print candidate asset arch suffixes, best first (one per line).
mo_core_arch_candidates() {
    local machine level
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64)
            level="$(mo_amd64_level)"
            case "$level" in
                v3) printf 'amd64-v3\namd64-v2\namd64-v1\n' ;;
                v2) printf 'amd64-v2\namd64-v1\n' ;;
                *) printf 'amd64-v1\n' ;;
            esac ;;
        aarch64|arm64) echo arm64 ;;
        armv7l|armv8l|armhf) echo armv7 ;;
        armv6l) echo armv6 ;;
        armv5*) echo armv5 ;;
        i386|i686) printf '386\n386-softfloat\n' ;;
        riscv64) echo riscv64 ;;
        loongarch64|loong64) echo loong64-abi1 ;;
        ppc64le) echo ppc64le ;;
        s390x) echo s390x ;;
        mips64le) echo mips64le ;;
        *) mo_error "不支持的架构：$machine"; return 1 ;;
    esac
}

# Install (or upgrade) the core binary. Keeps the previous binary as "<target>.old".
mo_artifact_install_core() (
    set -e
    local target="$1" version arch url temp_dir gz bin reported
    version="$(mo_latest_version)" || return 1
    temp_dir="$(mo_make_temp_dir)" || return 1
    trap 'rm -rf "$temp_dir"' EXIT
    gz="$temp_dir/mihomo.gz"
    bin="$temp_dir/mihomo"
    local candidates ok=0
    candidates="$(mo_core_arch_candidates)" || return 1
    for arch in $candidates; do
        url="https://github.com/$MO_CORE_REPO/releases/download/$version/mihomo-linux-$arch-$version.gz"
        mo_log "正在下载 mihomo $version（$arch）..."
        rm -f "$gz" "$bin"
        mo_download "$url" "$gz" || { mo_warn "下载 $arch 版本失败"; continue; }
        gzip -t "$gz" 2>/dev/null || { mo_warn "$arch 压缩包损坏"; continue; }
        gzip -dc "$gz" >"$bin"
        chmod 755 "$bin"
        reported="$("$bin" -v 2>/dev/null | head -n1 || true)"
        case "$reported" in
            *"$version"*) ok=1; break ;;
            *) mo_warn "$arch 版本无法在本机运行或版本不符，尝试下一个候选" ;;
        esac
    done
    [ "$ok" = 1 ] || { mo_error "未能获得可运行的 mihomo 二进制文件"; return 1; }
    mkdir -p "$(dirname "$target")"
    if [ -x "$target" ]; then
        cp -f "$target" "$target.old"
    fi
    install -m 755 "$bin" "$target.new.$$"
    mv -f "$target.new.$$" "$target"
    mo_log "mihomo $version 已安装：$target"
)

mo_artifact_install_ui() (
    set -e
    local target="$1" temp_dir archive extracted source staged backup url
    url="https://github.com/$MO_UI_REPO/releases/latest/download/dist.zip"
    temp_dir="$(mo_make_temp_dir)" || return 1
    trap 'rm -rf "$temp_dir"' EXIT
    archive="$temp_dir/ui.zip"
    extracted="$temp_dir/extracted"
    mo_log "正在下载 zashboard 面板..."
    mo_download "$url" "$archive" || return 1
    mkdir -p "$extracted"
    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$archive" -d "$extracted" || return 1
    else
        mo_select_python_basic || return 1
        "$MO_PYTHON" -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$archive" "$extracted" || return 1
    fi
    if [ -f "$extracted/index.html" ]; then
        source="$extracted"
    elif [ -f "$extracted/dist/index.html" ]; then
        source="$extracted/dist"
    else
        source="$(dirname "$(find "$extracted" -name index.html -print -quit)")"
        [ -f "$source/index.html" ] || { mo_error "zashboard 归档结构异常"; return 1; }
    fi
    mkdir -p "$(dirname "$target")"
    staged="$(dirname "$target")/.ui.new.$$"
    backup="$(dirname "$target")/.ui.old.$$"
    mkdir -p "$staged"
    cp -R "$source/." "$staged/"
    printf '%s\n' "$MO_UI_NAME" >"$staged/.mo-panel"
    if [ -e "$target" ]; then mv "$target" "$backup"; fi
    if mv "$staged" "$target"; then
        rm -rf "$backup"
    else
        [ ! -e "$backup" ] || mv "$backup" "$target"
        return 1
    fi
    mo_log "zashboard 面板已安装：$target"
)
