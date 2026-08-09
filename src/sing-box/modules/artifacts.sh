#!/usr/bin/env bash

sb_artifact_record() {
    local artifact="$1" arch="$2" record count
    [ -r "$SB_ARTIFACT_LOCK" ] || { sb_error "缺少制品锁定清单：$SB_ARTIFACT_LOCK"; return 1; }
    record="$(awk -F '\t' -v artifact="$artifact" -v arch="$arch" '
        $1 == artifact && ($4 == arch || $4 == "any") { print; count++ }
        END { if (count != 1) exit 1 }
    ' "$SB_ARTIFACT_LOCK")" || {
        sb_error "制品锁定清单中没有唯一匹配项：$artifact/$arch"
        return 1
    }
    printf '%s\n' "$record"
}

sb_artifact_url() {
    local filename="$1" source_url="$2"
    if [ -n "${SB_ARTIFACT_BASE_URL:-}" ]; then
        case "$SB_ARTIFACT_BASE_URL" in
            https://*) printf '%s/%s\n' "${SB_ARTIFACT_BASE_URL%/}" "$filename" ;;
            *) sb_error "SB_ARTIFACT_BASE_URL 必须使用 HTTPS"; return 1 ;;
        esac
    else
        printf '%s\n' "$source_url"
    fi
}

sb_artifact_download() {
    local url="$1" output="$2"
    case "$url" in
        https://*) ;;
        *) sb_error "拒绝从非 HTTPS 地址下载制品：$url"; return 1 ;;
    esac
    if command -v curl >/dev/null 2>&1; then
        curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$output"
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only -q "$url" -O "$output"
    else
        sb_error "下载制品需要 curl 或 wget"
        return 1
    fi
}

sb_artifact_verify() {
    local file="$1" expected="$2" actual
    sb_require_command sha256sum || return
    case "$expected" in
        *[!0-9a-f]*|'') sb_error "锁定清单包含无效的 SHA256"; return 1 ;;
    esac
    [ "${#expected}" -eq 64 ] || { sb_error "锁定清单包含无效的 SHA256"; return 1; }
    actual="$(sha256sum "$file")"
    actual="${actual%% *}"
    [ "$actual" = "$expected" ] || {
        sb_error "制品 SHA256 校验失败"
        return 1
    }
}

sb_core_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        armv7l) echo armv7 ;;
        i386|i686) echo 386 ;;
        *) sb_error "不支持的架构：$machine"; return 1 ;;
    esac
}

sb_artifact_install_core() (
    set -e
    local target="$1" arch record artifact version os locked_arch filename sha source_url license license_url
    local url temp_dir archive extracted version_output staged
    arch="$(sb_core_arch)" || return 1
    record="$(sb_artifact_record sing-box "$arch")" || return 1
    IFS=$'\t' read -r artifact version os locked_arch filename sha source_url license license_url <<<"$record"
    url="$(sb_artifact_url "$filename" "$source_url")" || return 1
    temp_dir="$(sb_make_temp_dir)" || return 1
    trap 'rm -rf "$temp_dir"' EXIT
    archive="$temp_dir/$filename"
    sb_log "正在下载锁定版本 sing-box $version ($arch)..."
    sb_artifact_download "$url" "$archive" || return 1
    sb_artifact_verify "$archive" "$sha" || return 1
    sb_require_command tar || return 1
    tar -xzf "$archive" -C "$temp_dir" || return 1
    extracted="$temp_dir/sing-box-$version-linux-$arch/sing-box"
    [ -x "$extracted" ] || { sb_error "sing-box 归档结构与锁定版本不匹配"; return 1; }
    version_output="$("$extracted" version 2>/dev/null | head -n 1)" || return 1
    [ "$version_output" = "sing-box version $version" ] || {
        sb_error "sing-box 版本校验失败：期望 $version"
        return 1
    }
    mkdir -p "$(dirname "$target")" || return 1
    staged="$target.new.$$"
    install -m 755 "$extracted" "$staged" || return 1
    mv -f "$staged" "$target" || return 1
    sb_log "sing-box $version 已安装：$target"
)

sb_artifact_install_ui() (
    set -e
    local target="$1" record artifact version os arch filename sha source_url license license_url
    local url temp_dir archive extracted source staged backup
    record="$(sb_artifact_record zashboard any)" || return 1
    IFS=$'\t' read -r artifact version os arch filename sha source_url license license_url <<<"$record"
    url="$(sb_artifact_url "$filename" "$source_url")" || return 1
    temp_dir="$(sb_make_temp_dir)" || return 1
    trap 'rm -rf "$temp_dir"' EXIT
    archive="$temp_dir/$filename"
    extracted="$temp_dir/extracted"
    sb_log "正在下载锁定版本 Zashboard $version..."
    sb_artifact_download "$url" "$archive" || return 1
    sb_artifact_verify "$archive" "$sha" || return 1
    sb_require_command unzip || return 1
    mkdir -p "$extracted" || return 1
    unzip -q "$archive" -d "$extracted" || return 1
    if [ -f "$extracted/index.html" ]; then
        source="$extracted"
    elif [ -f "$extracted/dist/index.html" ]; then
        source="$extracted/dist"
    else
        sb_error "Zashboard 归档结构与锁定版本不匹配"
        return 1
    fi
    mkdir -p "$(dirname "$target")" || return 1
    staged="$(dirname "$target")/.ui.new.$$"
    backup="$(dirname "$target")/.ui.old.$$"
    mkdir -p "$staged" || return 1
    cp -R "$source/." "$staged/" || return 1
    if [ -e "$target" ]; then mv "$target" "$backup" || return 1; fi
    if mv "$staged" "$target"; then
        rm -rf "$backup"
    else
        [ ! -e "$backup" ] || mv "$backup" "$target"
        return 1
    fi
    sb_log "Zashboard $version 已安装：$target"
)
