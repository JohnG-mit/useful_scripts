from __future__ import annotations

import argparse
import os
import sys
import tempfile


def write_atomic(path: str, text: str, mode: int = 0o600) -> None:
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    fd, temp = tempfile.mkstemp(dir=directory, prefix=".tmp.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(temp, mode)
        os.replace(temp, path)
    except BaseException:
        if os.path.exists(temp):
            os.unlink(temp)
        raise


def cmd_generate(args: argparse.Namespace) -> int:
    from . import merge

    with open(args.source, "r", encoding="utf-8", errors="replace") as handle:
        source_text = handle.read().lstrip("\ufeff")
    if not source_text.strip():
        merge.eprint("订阅内容为空")
        return 1
    template = merge.load_yaml_file(args.template) or {}
    override = (merge.load_yaml_file(args.override) if os.path.exists(args.override) else None) or {}
    config, provider_content = merge.build_config(
        source_text, template, override, provider_path=args.provider_path, gh_proxy=args.gh_proxy
    )
    if not config.get("proxies") and not config.get("proxy-providers"):
        merge.eprint("订阅中没有可用节点")
        return 1
    write_atomic(args.output, merge.dump_config(config))
    if provider_content is not None:
        if not args.provider_file:
            merge.eprint("内部错误：需要 --provider-file")
            return 2
        write_atomic(args.provider_file, provider_content)
        print("mode=provider")
    else:
        print("mode=clash")
    return 0


def cmd_override_get(args: argparse.Namespace) -> int:
    from . import merge

    data = (merge.load_yaml_file(args.file) if os.path.exists(args.file) else None) or {}
    value = merge.get_dotted(data, args.key)
    if value is None:
        return 1
    if isinstance(value, bool):
        value = str(value).lower()
    print(value)
    return 0


def cmd_override_set(args: argparse.Namespace) -> int:
    from . import merge

    data = (merge.load_yaml_file(args.file) if os.path.exists(args.file) else None) or {}
    for pair in args.pairs:
        key, sep, value = pair.partition("=")
        if not sep:
            merge.eprint(f"参数必须为 KEY=VALUE：{pair}")
            return 2
        merge.set_dotted(data, key, value)
    write_atomic(args.file, merge.dump_config(data))
    return 0


def cmd_override_init(args: argparse.Namespace) -> int:
    """Create the user override file from the shipped defaults unless it already exists."""
    from . import merge

    if os.path.exists(args.file):
        return 0
    data = merge.load_yaml_file(args.defaults) or {}
    write_atomic(args.file, merge.dump_config(data))
    return 0


def cmd_api(args: argparse.Namespace) -> int:
    from . import api

    try:
        return api.interactive(args.base, args.secret, args.group or "", args.target or "")
    except api.ApiError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print()
        return 130


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="mihomo_config")
    sub = parser.add_subparsers(dest="command", required=True)

    gen = sub.add_parser("generate")
    gen.add_argument("--source", required=True)
    gen.add_argument("--template", required=True)
    gen.add_argument("--override", required=True)
    gen.add_argument("--output", required=True)
    gen.add_argument("--provider-file")
    gen.add_argument("--provider-path", default="./providers/sub.txt")
    gen.add_argument("--gh-proxy", default="")
    gen.set_defaults(func=cmd_generate)

    get = sub.add_parser("override-get")
    get.add_argument("file")
    get.add_argument("key")
    get.set_defaults(func=cmd_override_get)

    set_ = sub.add_parser("override-set")
    set_.add_argument("file")
    set_.add_argument("pairs", nargs="+")
    set_.set_defaults(func=cmd_override_set)

    init = sub.add_parser("override-init")
    init.add_argument("file")
    init.add_argument("defaults")
    init.set_defaults(func=cmd_override_init)

    api_ = sub.add_parser("api")
    api_.add_argument("--base", required=True)
    api_.add_argument("--secret", default="")
    api_.add_argument("--group", default="")
    api_.add_argument("target", nargs="?", default="")
    api_.set_defaults(func=cmd_api)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
