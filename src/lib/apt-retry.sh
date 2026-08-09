#!/usr/bin/env bash

# Shared retry wrapper for apt-get operations. Callers may override these
# values through the environment before sourcing this file.
APT_RETRY_ATTEMPTS="${APT_RETRY_ATTEMPTS:-5}"
APT_RETRY_DELAY="${APT_RETRY_DELAY:-3}"
APT_DOWNLOAD_RETRIES="${APT_DOWNLOAD_RETRIES:-3}"
APT_DOWNLOAD_TIMEOUT="${APT_DOWNLOAD_TIMEOUT:-30}"
APT_UPDATE_MAX_AGE="${APT_UPDATE_MAX_AGE:-3600}"
APT_UPDATE_STAMP="${APT_UPDATE_STAMP:-${XDG_CACHE_HOME:-$HOME/.cache}/real_robot_eval/apt-update.stamp}"

apt_retry_validate_number() {
    local name="$1" value="$2"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
        printf '[APT][ERROR] %s 必须是正整数（当前值：%s）\n' "$name" "$value" >&2
        return 2
    }
}

apt_retry_command() {
    local attempt=1 status

    apt_retry_validate_number APT_RETRY_ATTEMPTS "$APT_RETRY_ATTEMPTS" || return
    apt_retry_validate_number APT_RETRY_DELAY "$APT_RETRY_DELAY" || return

    while (( attempt <= APT_RETRY_ATTEMPTS )); do
        printf '[APT] 执行尝试 %d/%d：' "$attempt" "$APT_RETRY_ATTEMPTS"
        printf ' %q' "$@"
        printf '\n'

        if "$@"; then
            return 0
        else
            status=$?
        fi

        if (( attempt == APT_RETRY_ATTEMPTS )); then
            printf '[APT][ERROR] 已达到最大重试次数，最后退出码：%d\n' "$status" >&2
            return "$status"
        fi

        printf '[APT][WARN] 命令失败，%d 秒后重试。\n' "$APT_RETRY_DELAY" >&2
        sleep "$APT_RETRY_DELAY"
        attempt=$(( attempt + 1 ))
    done
}

apt_get_retry() {
    local -a privilege_command=()

    apt_retry_validate_number APT_DOWNLOAD_RETRIES "$APT_DOWNLOAD_RETRIES" || return
    apt_retry_validate_number APT_DOWNLOAD_TIMEOUT "$APT_DOWNLOAD_TIMEOUT" || return

    while (( $# > 0 )) && [[ "$1" != -- ]]; do
        privilege_command+=("$1")
        shift
    done
    [[ "${1:-}" == -- ]] || {
        printf '[APT][ERROR] apt_get_retry 缺少参数分隔符 --\n' >&2
        return 2
    }
    shift
    (( $# > 0 )) || {
        printf '[APT][ERROR] apt_get_retry 缺少 apt-get 子命令\n' >&2
        return 2
    }

    apt_retry_command \
        "${privilege_command[@]}" \
        apt-get \
        -o "Acquire::Retries=$APT_DOWNLOAD_RETRIES" \
        -o "Acquire::http::Timeout=$APT_DOWNLOAD_TIMEOUT" \
        -o "Acquire::https::Timeout=$APT_DOWNLOAD_TIMEOUT" \
        "$@"
}

apt_update_validate_cache() {
    [[ "$APT_UPDATE_MAX_AGE" =~ ^[0-9]+$ ]] || {
        printf '[APT][ERROR] APT_UPDATE_MAX_AGE 必须是非负整数秒数。\n' >&2
        return 2
    }
}

apt_update_is_fresh() {
    local modified now max_age
    apt_update_validate_cache || return
    max_age="$((10#$APT_UPDATE_MAX_AGE))"
    (( max_age > 0 )) || return 1
    [[ -f "$APT_UPDATE_STAMP" ]] || return 1
    modified="$(stat -c %Y "$APT_UPDATE_STAMP" 2>/dev/null)" || return 1
    now="$(date +%s)"
    (( modified <= now && now - modified < max_age ))
}

apt_update_record_success() {
    local stamp_dir
    stamp_dir="$(dirname "$APT_UPDATE_STAMP")"
    if ! mkdir -p "$stamp_dir" || ! touch "$APT_UPDATE_STAMP"; then
        printf '[APT][WARN] 无法写入更新时间标记；下次将重新更新索引：%s\n' \
            "$APT_UPDATE_STAMP" >&2
    fi
}

apt_update_invalidate() {
    rm -f -- "$APT_UPDATE_STAMP"
}

apt_update_retry() {
    apt_update_validate_cache || return
    if apt_update_is_fresh; then
        printf '[APT] 近期已成功更新索引，跳过 apt-get update（缓存 %s 秒）。\n' \
            "$APT_UPDATE_MAX_AGE"
        return
    fi
    apt_get_retry "$@" -- update
    apt_update_record_success
}

apt_update_retry_force() {
    apt_update_validate_cache || return
    apt_update_invalidate
    apt_get_retry "$@" -- update
    apt_update_record_success
}
