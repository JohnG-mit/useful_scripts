#!/usr/bin/env bash

# mo l [-g 组] [节点序号或名称]
#   without arguments: list the selector groups/nodes and pick interactively.
mo_proxy_list() {
    local group='' target=''
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -g|--group) [ "$#" -ge 2 ] || { mo_error "$1 需要参数值"; return 2; }; group="$2"; shift 2 ;;
            -h|--help) printf '用法：mo l [-g 代理组] [节点序号或名称]\n'; return ;;
            *) [ -z "$target" ] || { mo_error "只能指定一个节点"; return 2; }; target="$1"; shift ;;
        esac
    done
    mo_service_require_running && mo_select_python_basic || return
    mo_pyconfig api --base "$(mo_api_base)" --secret "$(mo_get_secret)" --group "$group" "$target"
}
