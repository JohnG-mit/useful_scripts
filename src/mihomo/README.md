# mihomo 用户态 VPN 工具

本目录提供 mihomo（Clash.Meta）的用户级服务安装器和 `mo` 管理命令，结构与 `src/sing-box` 一致，并默认**替代**本机的 sing-box。

## 安装

```bash
bash src/mihomo/installer/install.sh --url 'https://example.com/subscription'
bash src/mihomo/installer/install.sh --file "$HOME/clash.yaml"
```

不带 `--url`/`--file` 时进入交互输入；重复运行会复用已保存的订阅、端口和 secret。安装器依次完成：

1. 停用 sing-box 用户服务，并注释 `~/.zshrc`/`~/.bashrc` 中加载 sing-box `vpn.sh` 的行（原文保留在 `# [mihomo-installer disabled]` 前缀之后，已备份）。
2. 安装运行文件到 `~/.local/lib/mihomo/releases/<时间戳>`（`current` 软链指向最新），`mo` 写入 `~/.local/bin`。
3. 下载最新核心到 `~/.local/bin/mihomo`，下载 zashboard 面板到 `~/service/mihomo/ui`。
4. 生成 `~/service/mihomo/override.yaml`（空闲端口、随机 secret）与 `config.yaml`，并用 `mihomo -t` 校验。
5. 注册 `mihomo.service`（用户级，`enable` 开机自启，并尝试 `loginctl enable-linger`），默认每天 06:00 同步 URL 订阅。
6. 向 Shell rc 写入 `# >>> mihomo >>>` 配置块：PATH、`vpn_on/vpn_off/vpn_s`，以及新终端在服务运行时自动 `vpn_on`（设置 `MO_AUTO_VPN=0` 可关闭）。
7. 交互询问是否通过 `sudo` 写入 APT 代理，并配置 GNOME 桌面代理。

选项与环境变量：

| 项 | 说明 |
| --- | --- |
| `--keep-singbox` | 不停用 sing-box，mihomo 自动选择其他端口 |
| `--no-apt` / `--no-desktop` | 跳过 APT / GNOME 代理 |
| `MO_GH_PROXY` | GitHub 镜像前缀，默认 `https://cdn.gh-proxy.org/`；设为空字符串则直连。镜像失败会自动回退直连 |
| `MO_VERSION` | 指定核心版本（默认读取最新 Release 的 `version.txt`） |
| `MO_FORCE_CORE=1` / `MO_FORCE_UI=1` | 重新下载核心 / 面板 |

核心按 CPU 能力选择 `amd64-v3 / v2 / v1`，下载后会运行 `mihomo -v` 校验版本与可执行性，不可运行时自动降级。上游不发布校验和，因此没有 SHA256 锁定。

## mo 命令

直接输入 `mo` 进入序号菜单，也可以直接使用子命令：

```text
mo s                 查看用户级服务状态
mo r                 重启服务
mo v                 查看核心版本（并提示可升级版本）
mo upgrade [--force] 升级核心，失败时自动回滚到上一个二进制
mo sync              同步已保存的订阅
mo regen             用缓存订阅重新生成配置（改完 override.yaml 后）
mo d                 显示工作目录
mo ip                查看代理出口 IP
mo speed             运行网络测速
mo l [-g 组] [节点]   列出并切换代理节点（交互时输入 t 可测速）
mo sub [URL|文件]     导入新订阅链接或 yaml/文本文件
mo t                 测试配置文件
mo cron              订阅自动同步二级菜单
mo ui                打开本地 Web 面板
mo log [-f|行数]      查看服务日志
mo tun on|off|status TUN 透明代理
mo desktop on|off|status
mo apt on|off|status
mo uninstall         卸载
```

服务状态异常、重启失败或启动后立即退出时，`mo s`/`mo r` 会自动执行一次 `mihomo -t`，并把测试输出和最近 20 行日志打印到终端。

### 订阅与配置生成

- **Clash/Mihomo YAML**：以订阅内容为基础，再合并本地 `override.yaml`（端口、controller、secret、UI、`allow-lan`、TUN、GeoData 镜像等；本地值优先）。订阅自带的 `port`/`socks-port`/`redir-port`/`tproxy-port` 会被移除。
- **节点链接 / Base64**：写入 `providers/sub.txt`，由内置模板 `resources/config-template.yaml` 通过 `proxy-providers` 引用，由 mihomo 原生解析。
- 新配置先经 `mihomo -t` 校验，通过后才会替换 `config.yaml`（旧配置保留最近 5 份 `config.yaml.bak.*`）；内容无变化时同步不会重启服务。
- 本地文件订阅会复制到 `~/service/mihomo/subscription.local`，之后 `mo sync` 重新生成配置但不会再访问原文件。
- 订阅 URL 先直连下载，失败后若服务在运行则经本机代理重试。

要长期修改本地设置，编辑 `~/service/mihomo/override.yaml` 后执行 `mo regen`（用缓存的订阅重新生成、校验并按需重启，不会重新下载）。

### 自动同步

`mo cron` 打开二级菜单：设置每日时间点（可多个，如 `06:00,18:00`）、每 N 小时、立即同步、取消、查看状态；也可直接 `mo cron daily 06:00,18:00`、`mo cron every 6`、`mo cron off`。底层是 systemd 用户定时器 `mihomo-sync.timer`（每日时间点使用 `Persistent=true`，错过的任务会在开机后补跑）。

### TUN

`mo tun on` 首次会执行一次 `sudo setcap cap_net_admin,cap_net_bind_service,cap_net_raw=+ep ~/.local/bin/mihomo`；升级核心后权限会丢失，`mo upgrade` 会自动重新授权。开启失败会自动回退为关闭。

## 终端代理

```bash
vpn_on    # 设置 http_proxy/https_proxy/all_proxy 等
vpn_off   # 取消
vpn_s     # 查看终端代理与服务状态（vpn_status 为别名）
```

端口从 `config.yaml` 的 `mixed-port` 读取，只修改当前 Shell 的环境变量，不会启停服务。

## Web 面板

zashboard 由 mihomo 的 `external-ui` 托管：`http://127.0.0.1:<API端口>/ui/`。`mo ui` 会输出带 secret 的直达链接并打开浏览器。API 仅监听 `127.0.0.1`，远程访问请使用 SSH 端口转发。

## 卸载

`mo uninstall` 会停用并删除服务与定时器、移除 `mo`/`mihomo`、Shell 配置块、APT 代理与桌面代理，并可选择恢复 sing-box 的服务和 Shell 配置、是否删除工作目录。

## 代码边界

- `cli/mo` 只负责命令解析和菜单。
- `modules/` 按功能域存放 Shell 模块，均依赖 `modules/core.sh`。
- `python/mihomo_config/` 负责配置合并（依赖 PyYAML）与 API 交互式客户端（仅标准库）。
- `installer/` 负责部署、Shell 配置和 systemd 单元。
- `resources/` 存放内置模板与本地覆盖项默认值。

## 测试

```bash
python3 -m unittest discover -s src/mihomo/tests
find src/mihomo -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
bash -n src/mihomo/cli/mo
```
