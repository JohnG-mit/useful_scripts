# sing-box 用户态 VPN 工具

本目录提供按功能拆分的 sing-box 安装器和管理命令。

## 安装

安装时可传入本地订阅文件或订阅 URL；不传参数则进入交互输入：

```bash
bash sing-box/installer/install.sh --file '~/subscription.txt'
bash sing-box/installer/install.sh --url 'https://example.com/subscription'
```

安装器会将命令写入 `~/.local/bin`，将带版本的运行文件写入 `~/.local/lib/sing-box`，将服务数据写入 `~/service/sing-box`，并在 `~/.config/systemd/user` 中创建用户级 systemd 单元。

安装器从官方 Release 下载仓库锁定版本的 sing-box 与 Zashboard，并在 SHA256、归档结构和版本检查通过后安装。已校验的归档缓存于 `~/.local/lib/sing-box/artifacts`，重复安装会复用缓存；若锁定清单中的 SHA256 变化或缓存损坏，则自动重新下载。Zashboard 下载失败时核心安装继续进行，但管理面板暂不可用。`cache.db` 由 sing-box 在服务目录中运行时生成，重复安装不会覆盖现有缓存。

安装过程需要 Python 3、systemd 用户会话、`tar`、`unzip`、`sha256sum`，以及 `curl` 或 `wget`。若订阅为 Clash/Mihomo YAML，则 Python 环境需要 PyYAML。

默认下载地址来自 `resources/artifacts.lock`。受限网络可将其中完全相同的文件同步到批准的 HTTPS 制品库，再设置 `SB_ARTIFACT_BASE_URL`；版本和 SHA256 不能通过环境变量覆盖。

真实订阅、节点密码、订阅令牌和控制器密钥必须存放在仓库外，并设置为仅当前用户可读：

```bash
chmod 600 "$HOME/subscription.txt"
bash sing-box/installer/install.sh --file "$HOME/subscription.txt"
```

安装器会在动态端口确定且 sing-box 服务启动后，交互询问是否通过 `sudo` 写入 `/etc/apt/apt.conf.d/99sing-box-proxy`；直接回车表示启用，输入 `n` 表示跳过。启用后直接执行 `sudo apt update` 或 `sudo apt install ...` 时，APT 的 HTTP/HTTPS 请求会使用 sing-box mixed 代理。该配置随重复安装更新，不依赖 `sudo` 保留当前 Shell 的代理环境变量。非交互安装默认启用；若不希望配置 APT，可在安装前设置：

```bash
export SB_CONFIGURE_APT_PROXY=0
```

APT 配置指向本机 sing-box 服务；服务未运行时，APT 的联网请求也会失败。

## 管理命令

```text
sb service status|restart
sb core version|upgrade
sb subscription update [--file FILE|--url URL] [--append|--replace] [--no-restart|--check]
sb proxy list|use TAG|ip|speedtest
sb desktop-proxy enable|disable|status
sb panel open [--host HOST] [--local-port PORT] [--print-only]
sb workdir
sb self-update
```

直接运行 `sb` 会打开中文交互菜单，运行 `sb help` 可查看命令摘要。

订阅更新选项：

- `--file FILE`：读取本地订阅文件。
- `--url URL`：下载远程订阅。
- `--append`：合并到当前配置，默认行为。
- `--replace`：基于内置模板重新生成配置。
- `--no-restart`：更新后不重启服务。
- `--check`：只验证，不写入配置。

订阅解析支持逐行的 `anytls://`、`hysteria2://`、`ss://`、`trojan://`、`tuic://`、`vless://`、`vmess://` 节点链接，也支持 Base64 订阅、Clash/Mihomo YAML 和 sing-box JSON。

## 桌面与终端代理

在 Ubuntu GNOME 上，安装器默认将桌面手动代理指向 sing-box 实际使用的 mixed 端口。现有的忽略主机列表会被保留，并补充本地和私有网络规则。安装前设置以下变量可跳过此步骤：

```bash
export SB_CONFIGURE_DESKTOP_PROXY=0
```

安装后可通过以下命令单独管理：

```bash
sb desktop-proxy enable
sb desktop-proxy disable
sb desktop-proxy status
```

这些命令应在已登录的图形桌面会话中运行，以便访问其 D-Bus 会话。

安装器还会为 Bash 或 Zsh 加载 VPN 辅助函数。重新加载 Shell 后使用：

```bash
vpn_on
vpn_status
vpn_off
```

它们只修改当前 Shell 的代理环境变量，不会启停 sing-box 服务。

## 面板访问

在安装 sing-box 的本机直接运行 `sb panel open`，会读取本机配置中的 Clash API 地址并打开浏览器。使用 `--print-only` 可只输出 URL：

```bash
sb panel open
sb panel open --local
sb panel open --print-only
```

要从另一台计算机访问远端 Clash API 面板，可通过 SSH 本地端口转发：

```bash
sb panel open --host user@example.com
sb panel open --host user@example.com --local-port 19090 --print-only
sb panel open --set-default user@example.com
```

`--host` 接受 IP、主机名和 `用户@主机`；默认远端主机保存在 `~/.config/sb/config`。已配置默认远端主机时，可用 `--local` 强制打开本机面板。在 SSH 远程会话中直接运行该命令时，会根据当前 SSH 连接输出可复制的端口转发命令和隧道建立后的本地访问地址。

## 代码边界

- `cli/` 只负责命令解析。
- `modules/` 按功能域存放 Shell 模块。
- `python/singbox_config/` 负责订阅解析和配置生成。
- `installer/` 负责部署、Shell 启动配置和 systemd 单元。
- `resources/` 只存放脱敏配置模板和第三方制品锁定清单。

各功能模块依赖 `modules/core.sh`，功能模块之间不应互相 `source`。CLI 和安装器负责确定运行目录并显式加载依赖。

`sb self-update` 默认从历史公开仓库更新。若本目录发布在其他位置，可在更新前设置 `SB_UPDATE_REPO`、`SB_UPDATE_REF` 和 `SB_UPDATE_SUBDIR`；也可通过 `SB_UPDATE_ARCHIVE_URL` 指定归档地址。

## 制品升级

升级第三方制品时，必须在独立 MR 中更新 `resources/artifacts.lock`：使用上游固定版本 Release URL，从官方 Release 元数据核对 SHA256，确认发布说明和许可证，再运行完整测试。`sb core upgrade` 只安装清单锁定的版本，不会查询或安装 `latest`。

## 测试

手动检查订阅解析：

```bash
bash sing-box/tests/manual_subscription_test.sh node
bash sing-box/tests/manual_subscription_test.sh file ./nodes.txt
bash sing-box/tests/manual_subscription_test.sh url
```

该脚本不会修改已安装的 sing-box 配置。它会保留并输出原始订阅、解码内容和完整生成配置的路径；默认输出到 `/tmp`，也可通过 `SB_TEST_OUTPUT_DIR` 指定目录。

运行自动测试和静态检查：

```bash
/usr/bin/python3 -m unittest discover -s sing-box/tests
find sing-box -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
bash -n sing-box/cli/sb
python3 -m json.tool sing-box/resources/config-template.json >/dev/null
```
