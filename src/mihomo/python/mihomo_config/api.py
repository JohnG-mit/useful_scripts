"""Small interactive client for the mihomo REST API (standard library only)."""

from __future__ import annotations

import json
import sys
import urllib.error
import urllib.parse
import urllib.request

TEST_URL = "https://www.gstatic.com/generate_204"


class ApiError(RuntimeError):
    pass


def request(base: str, secret: str, method: str, path: str, body: dict | None = None, timeout: float = 15):
    headers = {"Content-Type": "application/json"}
    if secret:
        headers["Authorization"] = f"Bearer {secret}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(base.rstrip("/") + path, data=data, method=method, headers=headers)
    # The API is local; never route it through an HTTP proxy from the environment.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=timeout) as response:
            payload = response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise ApiError(f"HTTP {exc.code}: {detail or exc.reason}") from exc
    except (urllib.error.URLError, OSError) as exc:
        raise ApiError(f"无法连接 mihomo API（{base}）：{exc}") from exc
    return json.loads(payload) if payload else None


def selector_groups(proxies: dict) -> list[str]:
    names = [name for name, item in proxies.items() if item.get("type") == "Selector"]
    # Prefer user-visible groups; the built-in GLOBAL group goes last.
    return [n for n in names if n != "GLOBAL"] + [n for n in names if n == "GLOBAL"]


def delay_label(item: dict) -> str:
    history = item.get("history") or []
    if not history:
        return "-"
    delay = history[-1].get("delay", 0)
    return f"{delay}ms" if delay else "超时"


def print_nodes(proxies: dict, group: str) -> list[str]:
    info = proxies[group]
    nodes = list(dict.fromkeys(info.get("all") or []))
    current = info.get("now")
    print(f"代理组：{group}（当前：{current}）")
    for index, name in enumerate(nodes, 1):
        item = proxies.get(name, {})
        marker = "（当前）" if name == current else ""
        print(f"  {index}) {name}  [{item.get('type', '?')}] {delay_label(item)}{marker}")
    return nodes


def choose(prompt: str) -> str:
    try:
        return input(prompt).strip()
    except EOFError:
        return ""


def select_node(base: str, secret: str, group: str, name: str) -> None:
    request(base, secret, "PUT", "/proxies/" + urllib.parse.quote(group, safe=""), {"name": name})
    print(f"代理组 {group} 已切换为：{name}")


def run_delay_test(base: str, secret: str, group: str) -> None:
    query = urllib.parse.urlencode({"url": TEST_URL, "timeout": 5000})
    print("正在测速，请稍候...")
    try:
        request(base, secret, "GET", f"/group/{urllib.parse.quote(group, safe='')}/delay?{query}", timeout=30)
    except ApiError as exc:
        print(f"测速失败：{exc}", file=sys.stderr)


def interactive(base: str, secret: str, group: str = "", target: str = "") -> int:
    proxies = request(base, secret, "GET", "/proxies")["proxies"]
    groups = selector_groups(proxies)
    if not groups:
        print("未找到可切换的 Selector 代理组", file=sys.stderr)
        return 1

    if group:
        if group not in groups:
            print(f"未找到可切换的代理组：{group}", file=sys.stderr)
            return 1
    elif len(groups) == 1 or not sys.stdin.isatty():
        group = groups[0]
    else:
        print("代理组：")
        for index, name in enumerate(groups, 1):
            print(f"  {index}) {name}（当前：{proxies[name].get('now')}）")
        answer = choose("请选择代理组 [1]：")
        if not answer:
            group = groups[0]
        elif answer.isdigit() and 0 < int(answer) <= len(groups):
            group = groups[int(answer) - 1]
        elif answer in groups:
            group = answer
        else:
            print(f"无效选择：{answer}", file=sys.stderr)
            return 2

    while True:
        nodes = print_nodes(proxies, group)
        if not nodes:
            print("代理组中没有节点", file=sys.stderr)
            return 1
        answer = target
        if not answer:
            if not sys.stdin.isatty():
                return 0
            answer = choose("输入序号或名称切换，t 测速，回车取消：")
        if not answer:
            return 0
        if answer.lower() == "t":
            run_delay_test(base, secret, group)
            proxies = request(base, secret, "GET", "/proxies")["proxies"]
            continue
        if answer.isdigit() and 0 < int(answer) <= len(nodes):
            answer = nodes[int(answer) - 1]
        if answer not in nodes:
            print(f"未知节点：{answer}", file=sys.stderr)
            return 2
        select_node(base, secret, group, answer)
        return 0
