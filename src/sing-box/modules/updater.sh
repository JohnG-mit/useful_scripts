#!/usr/bin/env bash

sb_core_version() {
    sb_require_binary || return
    "$SB_BINARY" version 2>/dev/null || "$SB_BINARY" -version
}

sb_core_upgrade() {
    sb_artifact_install_core "$SB_BINARY" || return
    [ -f "$SB_SERVICE_FILE" ] && sb_service_restart
    sb_log "sing-box 核心已更新到仓库锁定版本"
    sb_core_version
}

sb_self_update_validate() {
    local tree="$1" file
    for file in cli/sb modules/core.sh modules/artifacts.sh modules/service.sh modules/subscription.sh modules/desktop-proxy.sh modules/log-rotation.sh python/singbox_config/__main__.py python/singbox_config/singbox_json.py resources/config-template.json resources/artifacts.lock; do
        [ -f "$tree/$file" ] || { sb_error "更新内容缺少 $file"; return 1; }
    done
    while IFS= read -r file; do bash -n "$file" || return; done < <(find "$tree" -type f -name '*.sh' -o -path '*/cli/sb')
    PYTHONPATH="$tree/python" "$SB_PYTHON" -m py_compile "$tree"/python/singbox_config/*.py || return
    PYTHONPATH="$tree/python" "$SB_PYTHON" -c 'import singbox_config' || return
    "$SB_PYTHON" -m json.tool "$tree/resources/config-template.json" >/dev/null
}

sb_self_update() {
    sb_require_command curl && sb_require_command tar && sb_select_python || return
    local repo="${SB_UPDATE_REPO:-JohnG-mit/useful_scripts}" ref="${SB_UPDATE_REF:-main}"
    local archive_url="${SB_UPDATE_ARCHIVE_URL:-https://github.com/$repo/archive/refs/heads/$ref.tar.gz}"
    local subdir="${SB_UPDATE_SUBDIR:-sing-box}" temp_dir archive extracted source release previous link
    temp_dir="$(sb_make_temp_dir)"; archive="$temp_dir/source.tar.gz"
    curl -fsSL "$archive_url" -o "$archive" || { rm -rf "$temp_dir"; return 1; }
    tar -xzf "$archive" -C "$temp_dir" || { rm -rf "$temp_dir"; return 1; }
    extracted="$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d | head -n1)"
    source="$extracted/$subdir"
    sb_self_update_validate "$source" || { rm -rf "$temp_dir"; return 1; }

    release="$SB_RUNTIME_BASE/releases/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$release"/{cli,modules,python,shell,resources} "$SB_BIN_DIR"
    cp -R "$source/modules/." "$release/modules/"
    cp -R "$source/python/." "$release/python/"
    cp -R "$source/shell/." "$release/shell/"
    install -m 755 "$source/cli/sb" "$release/cli/sb"
    install -m 644 "$source/resources/config-template.json" "$release/resources/config-template.json"
    install -m 644 "$source/resources/artifacts.lock" "$release/resources/artifacts.lock"
    install -m 755 "$source/cli/sb" "$SB_BIN_DIR/sb.new"
    install -m 755 "$source/modules/log-rotation.sh" "$SB_BIN_DIR/sing-box-log-rotate.new"
    previous="$(readlink "$SB_RUNTIME_BASE/current" 2>/dev/null || true)"
    link="$SB_RUNTIME_BASE/.current.$$"
    ln -s "$release" "$link"
    mv -Tf "$link" "$SB_RUNTIME_BASE/current"
    mv "$SB_BIN_DIR/sb.new" "$SB_BIN_DIR/sb"
    mv "$SB_BIN_DIR/sing-box-log-rotate.new" "$SB_BIN_DIR/sing-box-log-rotate"
    [ -z "$previous" ] || ln -sfn "$previous" "$SB_RUNTIME_BASE/previous"
    rm -rf "$temp_dir"
    sb_artifact_install_ui "$SB_WORK_DIR/ui" || sb_warn "Zashboard 下载或校验失败，保留现有面板文件"
    sb_log "sb 运行环境已更新：$release"
}
