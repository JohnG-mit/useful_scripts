#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
DEFAULT_ROOT="$HOME/.vscode-server"

# Defaults
ROOT="$DEFAULT_ROOT"
SCOPE="versions"
KEEP=2
EXT_KEEP=1
OLDER_THAN_DAYS=0
DRY_RUN=false
ASSUME_YES=false
VERBOSE=false

# Internal counters
DELETE_COUNT=0
DELETE_BYTES=0

print_help() {
        cat <<'EOF'
清理 VS Code Remote Server 历史残留文件（旧版本、缓存、日志）。

用法:
    cleanup_vscode_server.sh [选项]

核心说明:
    1) 默认只清理版本残留（scope=versions），并保留最近 2 个版本目录。
    2) 支持按范围清理：versions / cache / logs / cli-logs / extensions / all。
    3) 支持按时间过滤：--older-than N（仅清理 N 天前的内容）。
    4) 默认会交互确认；可通过 --yes 跳过确认。
    5) 可先用 --dry-run 预览将删除的内容，确保安全。

选项:
    -h, --help
            打印本帮助信息并退出。

    -r, --root DIR
            指定 .vscode-server 根目录。
            默认: ~/.vscode-server

    -s, --scope SCOPE
            指定清理范围，可选：
            - versions   : 旧版本目录（默认）
            - cache      : 扩展缓存（CachedExtensionVSIXs）
            - logs       : 历史日志目录（data/logs）
            - cli-logs   : .vscode-server 根目录下的 .cli.*.log
            - extensions : ~/.vscode-server/extensions 中旧扩展版本
            - all        : 清理以上全部

    -k, --keep N
            仅对 versions 生效：保留每一类最近 N 个目录。
            类别包括：
            - code-*（如 code-585eba...）
            - cli/servers/Stable-*（如 Stable-585eba...）
            默认: 2

    -e, --ext-keep N
            仅对 extensions 生效：每个扩展保留最近 N 个版本目录。
            默认: 1
            说明：按目录修改时间排序，而不是按语义版本号排序。

    -o, --older-than DAYS
            仅删除“最后修改时间早于 DAYS 天”的条目。
            0 表示不按天数限制（默认）。

    -n, --dry-run
            仅预览，不实际删除。

    -y, --yes
            跳过确认提示，直接执行。

    -v, --verbose
            输出更详细日志。

示例:
    # 1) 预览默认清理（旧版本，保留最近2个）
    cleanup_vscode_server.sh --dry-run

    # 2) 清理旧版本，保留最近3个
    cleanup_vscode_server.sh --scope versions --keep 3

    # 3) 清理 30 天前的日志
    cleanup_vscode_server.sh --scope logs --older-than 30

    # 4) 清理全部范围，且仅删 15 天前内容（先预览）
    cleanup_vscode_server.sh --scope all --older-than 15 --dry-run

    # 5) 无交互直接清理（谨慎）
    cleanup_vscode_server.sh --scope all --older-than 30 --yes

    # 6) 清理 .cli 日志
    cleanup_vscode_server.sh --scope cli-logs

    # 7) 清理扩展旧版本（每个扩展保留 1 个最新版本）
    cleanup_vscode_server.sh --scope extensions --ext-keep 1

清理目标说明:
    versions:
        - ~/.vscode-server/code-*
        - ~/.vscode-server/cli/servers/Stable-*

    cache:
        - ~/.vscode-server/data/CachedExtensionVSIXs/*

    logs:
        - ~/.vscode-server/data/logs/*

    cli-logs:
        - ~/.vscode-server/.cli.*.log

    extensions:
        - ~/.vscode-server/extensions/<extension-id>-<version>

注意:
    - 本脚本不会删除 ~/.vscode-server/data/Machine 与 ~/.vscode-server/extensions 已安装扩展目录。
    - 推荐先执行 --dry-run 查看结果。
    - 如你同时连接多个 VS Code 会话，建议先关闭不用的会话再清理。
EOF
}

log() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

err() {
    printf '[ERROR] %s\n' "$*" >&2
}

vlog() {
    if [[ "$VERBOSE" == "true" ]]; then
        printf '[DEBUG] %s\n' "$*"
    fi
}

require_cmd() {
    local c="$1"
    command -v "$c" >/dev/null 2>&1 || {
        err "缺少命令: $c"
        exit 1
    }
}

is_positive_int() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

path_exists() {
    [[ -e "$1" ]]
}

mtime_days() {
    local path="$1"
    # GNU stat
    local now mtime
    now=$(date +%s)
    mtime=$(stat -c %Y "$path")
    echo $(( (now - mtime) / 86400 ))
}

bytes_of() {
    local path="$1"
    # GNU du
    du -sb -- "$path" 2>/dev/null | awk '{print $1}'
}

hr_bytes() {
    local bytes="$1"
    awk -v b="$bytes" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " ");
        i=1;
        while (b>=1024 && i<5) { b/=1024; i++ }
        printf "%.2f %s", b, u[i]
    }'
}

should_delete_by_age() {
    local path="$1"
    if [[ "$OLDER_THAN_DAYS" -le 0 ]]; then
        return 0
    fi
    local age
    age=$(mtime_days "$path")
    [[ "$age" -ge "$OLDER_THAN_DAYS" ]]
}

collect_top_level_matches() {
    local dir="$1"
    local pattern="$2"

    if [[ ! -d "$dir" ]]; then
        return 0
    fi

    find "$dir" -mindepth 1 -maxdepth 1 -name "$pattern" -print0 2>/dev/null
}

append_candidate() {
    local path="$1"

    if ! path_exists "$path"; then
        return 0
    fi

    if ! should_delete_by_age "$path"; then
        vlog "跳过(未达到天数): $path"
        return 0
    fi

    CANDIDATES+=("$path")
}

collect_versions_candidates() {
    local code_root="$ROOT"
    local stable_root="$ROOT/cli/servers"

    # code-* candidates: keep newest KEEP by mtime
    local -a code_items=()
    while IFS= read -r -d '' p; do
        code_items+=("$p")
    done < <(collect_top_level_matches "$code_root" 'code-*')

    if (( ${#code_items[@]} > 0 )); then
        mapfile -t code_sorted < <(
            for p in "${code_items[@]}"; do
                printf '%s\t%s\n' "$(stat -c %Y "$p")" "$p"
            done | sort -nr | cut -f2-
        )

        local i
        for (( i=KEEP; i<${#code_sorted[@]}; i++ )); do
            append_candidate "${code_sorted[$i]}"
        done
    fi

    # Stable-* candidates: keep newest KEEP by mtime
    local -a stable_items=()
    while IFS= read -r -d '' p; do
        stable_items+=("$p")
    done < <(collect_top_level_matches "$stable_root" 'Stable-*')

    if (( ${#stable_items[@]} > 0 )); then
        mapfile -t stable_sorted < <(
            for p in "${stable_items[@]}"; do
                printf '%s\t%s\n' "$(stat -c %Y "$p")" "$p"
            done | sort -nr | cut -f2-
        )

        local i
        for (( i=KEEP; i<${#stable_sorted[@]}; i++ )); do
            append_candidate "${stable_sorted[$i]}"
        done
    fi
}

collect_cache_candidates() {
    local cache_root="$ROOT/data/CachedExtensionVSIXs"
    local -a items=()

    while IFS= read -r -d '' p; do
        items+=("$p")
    done < <(collect_top_level_matches "$cache_root" '*')

    local p
    for p in "${items[@]}"; do
        append_candidate "$p"
    done
}

collect_logs_candidates() {
    local logs_root="$ROOT/data/logs"
    local -a items=()

    while IFS= read -r -d '' p; do
        items+=("$p")
    done < <(collect_top_level_matches "$logs_root" '*')

    local p
    for p in "${items[@]}"; do
        append_candidate "$p"
    done
}

collect_cli_logs_candidates() {
    local cli_pattern="$ROOT/.cli.*.log"
    local p

    for p in $cli_pattern; do
        append_candidate "$p"
    done
}

collect_extensions_candidates() {
    local ext_root="$ROOT/extensions"
    if [[ ! -d "$ext_root" ]]; then
        return 0
    fi

    local -a ext_dirs=()
    while IFS= read -r -d '' p; do
        ext_dirs+=("$p")
    done < <(find "$ext_root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

    if (( ${#ext_dirs[@]} == 0 )); then
        return 0
    fi

    # Group directories by extension id prefix: <publisher.name>-<version>
    # Example: ms-python.python-2026.2.0-linux-x64 => id=ms-python.python
    local name base
    local -A groups=()
    local p
    for p in "${ext_dirs[@]}"; do
        name="$(basename "$p")"
        if [[ "$name" =~ ^(.+)-([0-9][A-Za-z0-9._+-]*)$ ]]; then
            base="${BASH_REMATCH[1]}"
            groups["$base"]+="$p"$'\n'
        else
            vlog "跳过(无法识别版本格式): $p"
        fi
    done

    local key
    for key in "${!groups[@]}"; do
        local -a items=()
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            items+=("$p")
        done <<< "${groups[$key]}"

        if (( ${#items[@]} <= EXT_KEEP )); then
            continue
        fi

        local -a sorted=()
        mapfile -t sorted < <(
            for p in "${items[@]}"; do
                printf '%s\t%s\n' "$(stat -c %Y "$p")" "$p"
            done | sort -nr | cut -f2-
        )

        local i
        for (( i=EXT_KEEP; i<${#sorted[@]}; i++ )); do
            append_candidate "${sorted[$i]}"
        done
    done
}

print_plan() {
    if (( ${#CANDIDATES[@]} == 0 )); then
        log "没有匹配到可清理条目。"
        return 0
    fi

    local total=0
    local p sz
    printf '将处理以下条目 (%d):\n' "${#CANDIDATES[@]}"
    for p in "${CANDIDATES[@]}"; do
        sz=$(bytes_of "$p" || echo 0)
        total=$((total + sz))
        printf '  - %s (%s)\n' "$p" "$(hr_bytes "$sz")"
    done
    printf '预计释放: %s\n' "$(hr_bytes "$total")"
}

confirm_or_exit() {
    if [[ "$ASSUME_YES" == "true" || "$DRY_RUN" == "true" ]]; then
        return 0
    fi

    local ans
    read -r -p '确认执行删除? [y/N] ' ans
    case "$ans" in
        y|Y|yes|YES)
            ;;
        *)
            log "用户取消，未执行删除。"
            exit 0
            ;;
    esac
}

do_delete() {
    if (( ${#CANDIDATES[@]} == 0 )); then
        return 0
    fi

    local p sz
    for p in "${CANDIDATES[@]}"; do
        sz=$(bytes_of "$p" || echo 0)
        if [[ "$DRY_RUN" == "true" ]]; then
            printf '[DRY-RUN] rm -rf -- %q\n' "$p"
            continue
        fi

        rm -rf -- "$p"
        DELETE_COUNT=$((DELETE_COUNT + 1))
        DELETE_BYTES=$((DELETE_BYTES + sz))
        vlog "已删除: $p"
    done
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                print_help
                exit 0
                ;;
            -r|--root)
                ROOT="${2:-}"
                shift 2
                ;;
            -s|--scope)
                SCOPE="${2:-}"
                shift 2
                ;;
            -k|--keep)
                KEEP="${2:-}"
                shift 2
                ;;
            -e|--ext-keep)
                EXT_KEEP="${2:-}"
                shift 2
                ;;
            -o|--older-than)
                OLDER_THAN_DAYS="${2:-}"
                shift 2
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -y|--yes)
                ASSUME_YES=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            *)
                err "未知参数: $1"
                err "请使用 -h 查看帮助。"
                exit 1
                ;;
        esac
    done
}

validate_args() {
    if [[ -z "$ROOT" ]]; then
        err "--root 不能为空"
        exit 1
    fi

    if [[ ! -d "$ROOT" ]]; then
        err "目录不存在: $ROOT"
        exit 1
    fi

    case "$SCOPE" in
        versions|cache|logs|cli-logs|extensions|all)
            ;;
        *)
            err "--scope 仅支持: versions|cache|logs|cli-logs|extensions|all"
            exit 1
            ;;
    esac

    if ! is_positive_int "$KEEP"; then
        err "--keep 必须是 >=0 的整数"
        exit 1
    fi

    if ! is_positive_int "$EXT_KEEP"; then
        err "--ext-keep 必须是 >=0 的整数"
        exit 1
    fi

    if ! is_positive_int "$OLDER_THAN_DAYS"; then
        err "--older-than 必须是 >=0 的整数"
        exit 1
    fi
}

main() {
    require_cmd find
    require_cmd sort
    require_cmd awk
    require_cmd date
    require_cmd stat
    require_cmd du

    parse_args "$@"
    validate_args

    log "ROOT=$ROOT"
    log "SCOPE=$SCOPE"
    log "KEEP=$KEEP"
    log "EXT_KEEP=$EXT_KEEP"
    log "OLDER_THAN_DAYS=$OLDER_THAN_DAYS"
    log "DRY_RUN=$DRY_RUN"

    CANDIDATES=()

    case "$SCOPE" in
        versions)
            collect_versions_candidates
            ;;
        cache)
            collect_cache_candidates
            ;;
        logs)
            collect_logs_candidates
            ;;
        cli-logs)
            collect_cli_logs_candidates
            ;;
        extensions)
            collect_extensions_candidates
            ;;
        all)
            collect_versions_candidates
            collect_cache_candidates
            collect_logs_candidates
            collect_cli_logs_candidates
            collect_extensions_candidates
            ;;
    esac

    print_plan
    confirm_or_exit
    do_delete

    if [[ "$DRY_RUN" == "true" ]]; then
        log "预览结束（未实际删除）。"
    else
        log "清理完成: 删除 $DELETE_COUNT 个条目，释放 $(hr_bytes "$DELETE_BYTES")。"
    fi
}

main "$@"
