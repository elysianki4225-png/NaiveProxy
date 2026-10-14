# NaiveProxy 服务端一键安装脚本

> 在 Debian / Ubuntu 上一键部署 **NaiveProxy 服务端**：`Caddy + forwardproxy-naive`（带 NaiveProxy 填充层的 Caddy），
> 自动申请 HTTPS 证书、自动生成 systemd 守护进程、自动配置探针伪装（反向代理真实网站），
> 安装完成后直接输出**可复制粘贴到客户端的节点信息**。

```
  ┌────────────┐        ┌──────────────┐        ┌──────────────────────────────┐
  │ naive 客户端│ ─────► │  被审查网络   │ ─────► │ 你的服务器: Caddy + forwardproxy-naive │
  │(Chromium栈) │        │  (GFW 等)    │        │ 443/tcp(h2) 443/udp(h3)      │
  └────────────┘        └──────────────┘        └──────────────────────────────┘
                                                      未通过鉴权的探测请求 → 伪装成普通网站
```

**适用系统**：Debian 11+ / Ubuntu 20.04+ · x86_64 / arm64 / armv7
**脚本**：[`naiveproxy-install.sh`](./naiveproxy-install.sh) · **版本**：v1.0.0 · **许可**：MIT

---

## 目录

- [1. 特性](#1-特性)
- [2. 快速开始](#2-快速开始)
- [3. 安装前准备](#3-安装前准备)
- [4. 安装过程做了什么](#4-安装过程做了什么)
- [5. 命令行参数](#5-命令行参数)
- [6. 安装完成后的输出示例](#6-安装完成后的输出示例)
- [7. 客户端配置](#7-客户端配置)
- [8. 证书与 ACME CA（含 Let's Encrypt 限速说明）](#8-证书与-acme-ca含-lets-encrypt-限速说明)
- [9. 服务管理与运维](#9-服务管理与运维)
- [10. 文件与目录](#10-文件与目录)
- [11. 工作原理与设计取舍](#11-工作原理与设计取舍)
- [12. 验证与测试情况](#12-验证与测试情况)
- [13. 常见问题 FAQ](#13-常见问题-faq)
- [14. 安全说明与免责声明](#14-安全说明与免责声明)
- [15. 相关文档](#15-相关文档)

---

## 1. 特性

| 能力 | 说明 |
| --- | --- |
| **一键部署** | 一条命令完成依赖安装、Caddy 安装、配置生成、证书申请、服务启动、开机自启 |
| **NaiveProxy 专用二进制** | 自动下载 `caddy-forwardproxy-naive` 预编译包（含 QUIC-BBR 补丁），失败时自动改用 `xcaddy` 源码编译，或 Caddy 官方在线构建服务 |
| **三种安装方式自动降级** | `prebuilt → download API → 源码编译`，非 x86_64 架构自动走编译/在线构建 |
| **域名自动生成** | 自动探测公网 IPv4，生成 `<随机8位>.<公网IP>.nip.io`，也支持你自己的域名 |
| **灵活 ACME CA** | Let's Encrypt / **ZeroSSL（自动获取 EAB 凭据）** / staging / 自定义 ACME 目录，规避 Let's Encrypt 单主域限速 |
| **HTTP/2 与 HTTP/3** | 默认同时开启 h2(TCP 443) 与 h3(QUIC/UDP 443)，也可只保留其中一种 |
| **探针伪装** | `probe_resistance` + 反向代理真实网站（默认 bing）或本机静态页面；未鉴权探测看到一个普通网站 |
| **安全默认值** | 禁止代理访问内网/回环地址、隐藏 `Forwarded`/`Via` 头、`hide_ip`/`hide_via`、以 `caddy` 非 root 用户运行 |
| **systemd 守护进程** | `Type=notify` + 开机自启 + 自动重启 + `AmbientCapabilities` 绑定 80/443 端口 |
| **节点信息直出** | 安装后打印：naive `config.json`、命令行、sing-box 出站、`naive+https://` 分享链接、Base64 订阅、可选二维码 |
| **管理面板** | `bash naiveproxy-install.sh menu` 提供状态、重启、重签证书、更新、卸载等操作 |
| **可选优化** | BBR 拥塞控制、防火墙（ufw/firewalld）自动放行、日志与自检报告 |

---

## 2. 快速开始

> 需要 **root** 权限（`sudo -i` 或 `sudo bash ...`）。

### 方式 A：交互式安装（推荐新手）

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/elysianki4225-png/NaiveProxy/main/naiveproxy-install.sh)"
```

脚本会依次询问：**域名方案 → 端口 → 账号密码 → 证书邮箱 → ACME CA → HTTP/3 → 伪装站点**，其余全部自动完成。

> 也可以先下载再运行（便于查看与二次修改）：
>
> ```bash
> curl -fsSL -o naiveproxy-install.sh \
>   https://raw.githubusercontent.com/elysianki4225-png/NaiveProxy/main/naiveproxy-install.sh
> chmod +x naiveproxy-install.sh
> sudo ./naiveproxy-install.sh
> ```

### 方式 B：全自动安装（适合脚本化/无人值守）

```bash
# ZeroSSL 证书（推荐，规避 Let's Encrypt 单主域限速）+ bing 反代伪装 + 随机域名与随机密码
bash -c "$(curl -fsSL https://raw.githubusercontent.com/elysianki4225-png/NaiveProxy/main/naiveproxy-install.sh)" install \
  --ca zerossl --email you@example.com --yes
```

### 方式 C：使用自己的域名（生产环境推荐）

先把域名的 **A 记录**指向服务器公网 IP，然后：

```bash
sudo ./naiveproxy-install.sh install \
  --domain proxy.example.com \
  --email you@example.com \
  --ca zerossl \
  --http3 on \
  --masq reverse --masq-target https://your-blog-or-any-site.com
```

### 安装后：查看节点信息 / 管理

```bash
sudo bash naiveproxy-install.sh info     # 重新打印节点信息与客户端配置
sudo bash naiveproxy-install.sh menu     # 打开管理面板
sudo bash naiveproxy-install.sh status   # 查看服务与证书状态
```

---

## 3. 安装前准备

| 项目 | 要求 |
| --- | --- |
| 系统 | Debian 11+ / Ubuntu 20.04+（干净系统即可，脚本会自动装依赖） |
| 架构 | x86_64（amd64，可直接用预编译包）/ arm64 / armv7（自动改用编译或在线构建） |
| 端口 | **80/tcp**（证书校验 + 跳转）、**443/tcp**（h2）、**443/udp**（h3，如开启） |
| 域名 | 使用自有域名时，A 记录必须已解析到本机公网 IPv4；**不要开启 Cloudflare 小黄云代理**（HTTP-01 会失败） |
| 云安全组 | 阿里云/腾讯云/AWS 等必须放行上述端口（脚本无法代改安全组） |
| 内存 | ≥ 512 MB（源码编译需要 ≥ 1 GB） |
| 出口网络 | 服务器需能访问 GitHub、ACME CA（ZeroSSL/Let's Encrypt）以及**伪装目标网站** |

> 💡 **为什么推荐 ZeroSSL？** 使用 `*.nip.io` 这类公共解析域名时，Let's Encrypt 对「注册域」的限额是**所有 nip.io 用户共享**的，
> 很容易申请失败。详见 [第 8 节](#8-证书与-acme-ca含-lets-encrypt-限速说明)。

---

## 4. 安装过程做了什么

脚本按 6 个步骤执行，任何一步失败都会给出明确原因与后续建议：

| 步骤 | 动作 | 细节 |
| --- | --- | --- |
| 1 | **检测环境** | 校验系统版本/架构/systemd，安装基础依赖，调用多个 API 探测公网 IPv4（失败可手动指定） |
| 2 | **收集配置** | 域名（自动/自定义）、端口、代理账号密码、邮箱、ACME CA、HTTP/3 开关、伪装站点；并检查域名解析是否指向本机 |
| 3 | **端口检查** | 检测 80/443(tcp/udp) 占用；若是已在运行的 Caddy 则复用并在安装后重启 |
| 4 | **安装 Caddy** | ① 下载 `klzgrad/forwardproxy` 官方预编译包（x86_64，含 QUIC-BBR 补丁）→ ② Caddy 官方在线构建 API → ③ `xcaddy` 源码编译（自动安装符合要求的 Go 工具链） |
| 5 | **生成配置** | 写入 `/etc/caddy/Caddyfile`（含 forward_proxy、探针伪装、反代/静态页）、生成 systemd 服务并设置开机自启、保存安装信息 |
| 6 | **启动与验证** | `caddy validate` 校验语法 → 启动服务 → 等待 ACME 证书签发（读取真实证书链验证）→ 探测伪装页面 → **端到端代理自检**（用 curl 直连本机代理访问外网）→ 放行防火墙 → 可选启用 BBR → 生成客户端配置 |

安装日志：`/var/log/naiveproxy-install.log`

---

## 5. 命令行参数

```
bash naiveproxy-install.sh [命令] [参数...]
```

### 命令

| 命令 | 说明 |
| --- | --- |
| `install` | 安装（默认命令） |
| `menu` | 交互式管理面板 |
| `status` | 服务状态 + 当前证书签发者与到期时间 |
| `info` | 重新打印节点信息（含客户端配置） |
| `start` / `stop` / `restart` | 启停服务 |
| `log [N\|-f]` | 查看日志（默认末尾 120 行，`-f` 实时跟踪） |
| `update` | 更新 Caddy 二进制（保留配置与证书） |
| `renew` | 强制重新申请证书（⚠ 会消耗 CA 配额） |
| `uninstall` | 卸载（可只停服务或彻底清除） |
| `version` / `help` | 版本 / 帮助 |

### 安装参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `--domain <域名>` | 随机前缀`.公网IP`.nip.io | 指定证书域名 |
| `--prefix <前缀>` | 随机 8 位 | nip.io 前缀 |
| `--ip <IPv4>` | 自动探测 | 手动指定公网 IPv4 |
| `--email <邮箱>` | `admin@<域名>` | ACME 账户邮箱（证书到期通知） |
| `--ca <CA>` | 交互选择（默认 ZeroSSL） | `letsencrypt` \| `zerossl` \| `letsencrypt-staging` \| `custom` |
| `--acme-ca <URL>` | - | 自定义 ACME 目录（配合 `--ca custom`） |
| `--eab <KeyID:HMACKey>` | 自动获取 | ZeroSSL EAB 凭据（自动获取失败时使用） |
| `--user <用户名>` | 随机 | 代理用户名（`[A-Za-z0-9._-]{1,32}`） |
| `--pass <密码>` | 随机 24 位 | 代理密码（`[A-Za-z0-9._-]{8,64}`，可直接放进 URL；别名 `--password`） |
| `--https-port <端口>` | 443 | 代理端口 |
| `--http-port <端口>` | 80 | 证书校验与跳转端口 |
| `--http3 <模式>` | `on` | `on`=h2+h3，`h2only`=仅 h2，`h3only`=关闭 h2（别名 `--h3`） |
| `--masq <模式>` | `reverse` | `reverse`=反代真实网站，`static`=本机静态页，`none`=404 |
| `--masq-target <URL>` | `https://www.bing.com` | 反代目标（可填你自己的博客/官网） |
| `--probe-secret <域名>` | 关闭 | 探针密道域名（需要该域名也解析到本机） |
| `--run-as <caddy\|root>` | `caddy` | 运行身份（`caddy` 更安全） |
| `--firewall <auto\|yes\|no>` | `auto` | 是否自动放行 ufw/firewalld 端口 |
| `--bbr <auto\|yes\|no>` | `auto` | 是否启用 BBR 拥塞控制 |
| `--install-method <方式>` | `auto` | `auto` \| `prebuilt` \| `source` \| `api` |
| `--caddy-version <版本>` | `v2.11.7` | 指定 Caddy 版本（源码编译时使用） |
| `--fp-tag <tag>` | 最新 | 指定预编译包 tag，如 `v2.11.7-naive` |
| `--webroot <目录>` | `/var/www/naiveproxy` | 静态伪装页目录 |
| `--allow-private` | 关闭 | 允许代理访问内网地址（默认禁止，⚠ 有安全风险） |
| `--force` | - | 覆盖已有配置（自动备份原文件；别名 `--force-reinstall`） |
| `--yes` / `-y` | - | 非交互：全部使用默认值 |
| `--interactive` / `--non-interactive` | 自动判断 | 强制交互 / 强制非交互 |
| `--quiet` | - | 精简输出（只打印关键结果；别名 `-q`） |
| `--version` | - | 显示脚本版本 |
| `-h`, `--help` | - | 完整帮助 |

### 常用组合示例

```bash
# 1) ZeroSSL + 自有域名 + 反代自己的博客（伪装效果最好）
sudo ./naiveproxy-install.sh install --domain proxy.example.com --ca zerossl \
     --email me@example.com --masq reverse --masq-target https://blog.example.com

# 2) 仅 HTTP/2（某些网络对 UDP 443 有 QoS）
sudo ./naiveproxy-install.sh install --http3 h2only

# 3) 不反代外站，用本机静态页做伪装（不依赖上游站点可用性）
sudo ./naiveproxy-install.sh install --masq static

# 4) 强制源码编译（例如 arm64 或想自己控制版本）
sudo ./naiveproxy-install.sh install --install-method source --caddy-version v2.11.7

# 5) 自定义端口（避免与已有服务冲突，注意客户端也要改端口）
sudo ./naiveproxy-install.sh install --https-port 8443 --http-port 8080

# 6) 刷新/升级已安装的 Caddy
sudo ./naiveproxy-install.sh update

# 7) 卸载（彻底删除）
sudo ./naiveproxy-install.sh uninstall --yes
```

---

## 6. 安装完成后的输出示例

```
────────────────────────────────────────────────────────────────
  安装完成 · 节点信息（可直接复制使用）
────────────────────────────────────────────────────────────────
【服务器信息】
  地址(SNI/域名) : abc123defg.203.0.113.10.nip.io
  端口           : 443
  用户名         : u9k2m4p7q1
  密码           : Zx9Qw8Er7Ty6Ui5Op4As
  伪装站点       : 反向代理 → https://www.bing.com
  协议支持       : HTTP/2 + HTTP/3
  证书 CA        : zerossl (https://acme.zerossl.com/v2/DV90)
  安装方式       : 预编译二进制 (v2.11.7-naive, naive fork)

【1】官方 naive 客户端 config.json
{"listen":"socks://127.0.0.1:1080","proxy":"https://u9k2m4p7q1:Zx9Qw8Er7Ty6Ui5Op4As@abc123defg.203.0.113.10.nip.io:443"}

【2】命令行启动
  naive --listen=socks://127.0.0.1:1080 --proxy=https://u9k2m4p7q1:Zx9Qw8Er7Ty6Ui5Op4As@abc123defg.203.0.113.10.nip.io:443
  naive --listen=socks://127.0.0.1:1080 --proxy=quic://u9k2m4p7q1:Zx9Qw8Er7Ty6Ui5Op4As@abc123defg.203.0.113.10.nip.io:443   # HTTP/3

【3】分享链接（NekoBox / Husi / Exclave / v2rayN / sing-box 可直接导入）
  naive+https://u9k2m4p7q1:Zx9Qw8Er7Ty6Ui5Op4As@abc123defg.203.0.113.10.nip.io:443#NaiveProxy-abc123defg
  naive+quic://u9k2m4p7q1:Zx9Qw8Er7Ty6Ui5Op4As@abc123defg.203.0.113.10.nip.io:443#NaiveProxy-QUIC-abc123defg

【4】sing-box 出站配置（复制到 outbounds 数组）
  { "type": "naive", "tag": "naive-out", "server": "abc123defg.203.0.113.10.nip.io", ... }
```

同时会把这些内容写进 `/etc/caddy/naiveproxy/client/`（权限 0700 / 0600，仅 root 可读）：

```
/etc/caddy/naiveproxy/client/
├── naive-config.json            # 官方客户端 config.json（HTTP/2）
├── naive-config-quic.json       # 官方客户端 config.json（HTTP/3）
├── naive-command.txt            # 各平台命令行用法
├── sing-box-outbound-h2.json    # sing-box 出站（HTTP/2）
├── sing-box-outbound-h3.json    # sing-box 出站（HTTP/3）
├── share-links.txt              # naive+https:// / naive+quic:// 分享链接
├── subscribe-plain.txt          # 纯文本订阅（单行链接）
├── subscribe-base64.txt         # Base64 订阅（可直接作为订阅内容）
├── subscribe-*-quic.txt         # 同上（HTTP/3 版）
├── qr-h2.png / qr-h3.png        # 二维码（系统已安装 qrencode 时生成）
└── node-info.txt                # 上述信息的文本汇总
```

---

## 7. 客户端配置

**完整客户端配置（官方 naive 客户端、Windows/Linux/macOS/Android、sing-box、v2rayN、NekoBox、Husi、Exclave、Shadowrocket 等）见
👉 [docs/客户端配置.md](docs/客户端配置.md)**

最小可用示例：

**官方 naive 客户端**（[下载](https://github.com/klzgrad/naiveproxy/releases/latest)）

```json
{
  "listen": "socks://127.0.0.1:1080",
  "proxy": "https://用户名:密码@你的域名:443"
}
```

把上面的 JSON 保存为 `config.json`，与 `naive`/`naive.exe` 放在同一目录后运行，本机即获得
`127.0.0.1:1080` 的 SOCKS5/HTTP 代理。

**sing-box**（≥ 1.13，需带 `libcronet` 的构建）

```json
{
  "type": "naive",
  "tag": "naive-out",
  "server": "你的域名",
  "server_port": 443,
  "username": "用户名",
  "password": "密码",
  "tls": { "enabled": true, "server_name": "你的域名" }
}
```

**通用分享链接**（NekoBox / Husi / Exclave / v2rayN / sing-box 导入）

```
naive+https://用户名:密码@你的域名:443#备注
naive+quic://用户名:密码@你的域名:443#备注     # HTTP/3
```

> 手动填写时需要的字段：**服务器地址 = 域名**、**端口 = 443**、**用户名/密码**、**TLS/SNI = 域名**（务必开启 TLS）。

---

## 8. 证书与 ACME CA（含 Let's Encrypt 限速说明）

### 8.1 为什么必须用真实证书

NaiveProxy 的安全性建立在「流量与真实 Chrome 访问普通 HTTPS 网站无法区分」之上。
自签证书、staging 证书都会因证书链异常而形成明显特征。**生产环境请务必使用被公开信任的证书。**

### 8.2 Let's Encrypt 的限额（为什么 `*.nip.io` 容易失败）

| 限额 | 数值 | 说明 |
| --- | --- | --- |
| New Certificates per Registered Domain | **50 张 / 7 天** | 以「注册域」为统计单位（Public Suffix List 的 eTLD+1） |
| New Certificates per Exact Set of Identifiers | **5 张 / 7 天** | 完全相同的域名组合，补满速度约 1 张 / 34 小时 |
| New Orders per Account | 300 / 3 小时 | 同一 ACME 账户 |

`nip.io`（以及 `sslip.io`、`xip.io`、`localtest.me` 等）**并不在 Public Suffix List 中**
（本脚本已直接核对 [publicsuffix/list](https://github.com/publicsuffix/list) 官方列表：ICANN 与 Private 段均无 `nip.io`）。
因此 Let's Encrypt 会把所有 `*.nip.io` 视为**同一个注册域**：

> ⚠️ 全世界所有使用 `xxx.nip.io` 的人，共享这 **50 张 / 7 天** 的额度；同一个域名组合还额外受 **5 张 / 7 天** 限制。
> 遇到 `too many certificates already issued for nip.io` 就是命中了这个限制。

### 8.3 本脚本的应对策略

1. **每次安装使用随机前缀**（`<随机8位>.<IP>.nip.io`）→ 规避「同一域名组合 5 张 / 7 天」的重复证书限制；
2. **支持切换 ACME CA**：默认交互推荐 **ZeroSSL**（免费 DV 证书，不受上述 nip.io 共享额度限制）；
3. **支持自有域名 + DNS-01 通配符**（自行在 Caddyfile 中加 `tls { dns <provider> }`）；
4. 安装时若命中限速，脚本会直接给出「改用 ZeroSSL 重装」的命令。

### 8.4 ZeroSSL：EAB 自动获取

ZeroSSL 的 ACME 端点（`https://acme.zerossl.com/v2/DV90`）**强制要求 EAB（External Account Binding）**。
脚本的处理方式：

```bash
# 脚本内部自动调用（无需注册/登录，无需 API Key）：
POST https://api.zerossl.com/acme/eab-credentials-email   email=你的邮箱
# → 返回 eab_kid / eab_hmac_key，自动写入 Caddyfile 的 acme_eab 块
```

自动获取失败时，会提示你手工填写；也可以先自行获取再传入：

```bash
# 在 https://app.zerossl.com/developer 页面可以找到 ACME EAB Credentials
sudo ./naiveproxy-install.sh install --ca zerossl --email me@example.com --eab 'KeyID:HMACKey'
```

> ⚠️ 注意区分：ZeroSSL 的 **Developer → API Key** 是给 REST API 用的（Caddy 的 `issuer zerossl <api_key>` 用它）；
> 这里用的是 **EAB Credentials**。两者不要混用。
>
> ⚠️ 还要注意：ZeroSSL 使用 ACME 时通常只能通过 **HTTP-01** 校验，因此 **80 端口必须对外开放**。

更详细的证书说明（自定义 ACME、staging、手动证书、排查清单）见
👉 [docs/证书与CA.md](docs/证书与CA.md)

---

## 9. 服务管理与运维

```bash
# 服务状态 / 启停 / 开机自启
systemctl status caddy
systemctl restart caddy
systemctl stop caddy
systemctl start caddy
systemctl is-enabled caddy

# 日志（Caddy 默认不写访问日志，日志级别由 Caddy 自身控制）
journalctl -u caddy -f
journalctl -u caddy -n 100 --no-pager

# 配置检查与热重载（改完 Caddyfile 后建议先校验）
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo caddy reload  --config /etc/caddy/Caddyfile --adapter caddyfile --force

# 查看二进制信息
caddy version
caddy list-modules | grep forward_proxy
caddy build-info | grep -i forwardproxy

# 脚本自带的管理能力
sudo bash naiveproxy-install.sh status|info|restart|log|update|renew|uninstall|menu
```

更多运维内容（备份迁移、性能调优、排错表、卸载清理）见
👉 [docs/运维与排错.md](docs/运维与排错.md)

---

## 10. 文件与目录

| 路径 | 说明 |
| --- | --- |
| `/usr/local/bin/caddy` | `caddy-forwardproxy-naive` 可执行文件 |
| `/etc/caddy/Caddyfile` | 服务端配置（`root:caddy 0640`，含代理密码） |
| `/etc/caddy/naiveproxy/site.env` | 安装信息（域名/账号/密码/CA 等，0600） |
| `/etc/caddy/naiveproxy/client/` | 客户端配置与节点信息（0700，仅 root） |
| `/etc/systemd/system/caddy.service` | systemd 守护进程 |
| `/var/lib/caddy/` | Caddy 用户主目录、证书与密钥存储（`.local/share/caddy`） |
| `/var/www/naiveproxy/` | 静态伪装页面（`--masq static` 时使用） |
| `/var/log/naiveproxy-install.log` | 安装/管理脚本运行日志 |
| `/etc/sysctl.d/99-naiveproxy.conf` | BBR 等内核参数（启用 BBR 时生成） |

---

## 11. 工作原理与设计取舍

### 11.1 为什么必须用 `klzgrad/forwardproxy@naive`

官方 `caddyserver/forwardproxy` 只是一个普通的前向代理；NaiveProxy 需要**数据包填充层（padding）**来打散包长特征。
只有 [`klzgrad/forwardproxy` 的 `naive` 分支](https://github.com/klzgrad/forwardproxy/tree/naive) 合并了该填充层与探针伪装，
因此脚本安装的是它的预编译包，`--with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive` 编译的也是它。
（注意：该 fork 的 `go.mod` 模块名仍是 `github.com/caddyserver/forwardproxy`，所以必须使用 `=` 替换语法。）

### 11.2 生成的 Caddyfile 关键点

```caddyfile
{
	order forward_proxy before file_server
	email me@example.com
	acme_ca https://acme.zerossl.com/v2/DV90
	acme_eab {
		key_id  xxxxxxxx
		mac_key xxxxxxxx
	}
	http_port 80
	https_port 443
}

:443, proxy.example.com {
	encode zstd gzip
	route {
		forward_proxy {
			basic_auth 用户名 密码
			hide_ip
			hide_via
			probe_resistance
			dial_timeout 30
			max_idle_conns 128
			max_idle_conns_per_host 8
			acl {
				deny 10.0.0.0/8 127.0.0.0/8 172.16.0.0/12 192.168.0.0/16 ::1/128 fe80::/10
				allow all
			}
		}
		reverse_proxy https://www.bing.com {
			header_up Host {upstream_hostport}
		}
	}
}
```

| 细节 | 原因 |
| --- | --- |
| `:443` 写在站点地址最前面 | upstream 明确要求：否则 `forward_proxy` 无法处理「任意目标」的代理请求 |
| 使用显式 `route {}` 块 | `forward_proxy` 的默认顺序在 `file_server` 之后；`route` 块内顺序即书写顺序，最直观也最稳 |
| `probe_resistance`（不带参数） | 无凭据 / 凭据错误的探测请求会**原样传给后面的伪装内容**，看起来就是一台普通网站 |
| `acl` 显式列出内网 deny | 上游默认值即如此，显式写出避免误开放内网跳板 |
| HTTP/3 默认开启 | Caddy ≥ 2.6 默认监听 QUIC/UDP；脚本仅在需要时用 `servers :443 { protocols h1 h2 }` 关掉 |

### 11.3 systemd 服务

`Type=notify`、`User=caddy`、`AmbientCapabilities=CAP_NET_BIND_SERVICE`（非 root 绑定 80/443）、
`LimitNOFILE=1048576`、`Restart=on-failure`、`ProtectSystem=full`，`XDG_DATA_HOME` 固定到 `/var/lib/caddy`，
保证证书存储路径稳定（避免用 root 手工运行导致重复申请证书）。

---

## 12. 验证与测试情况

为避免「装完起不来」，本项目在开发过程中做了如下验证：

| 项目 | 方法 | 结果 |
| --- | --- | --- |
| Shell 语法 | `bash -n` | ✅ |
| 静态检查 | `shellcheck -S style` | ✅ 无告警（0 warning） |
| **Caddyfile 语法** | 使用**真实 Caddy v2.11.7 二进制**对脚本生成的配置执行 `caddy adapt`（8 种组合：ZeroSSL/EAB、LE、仅 h2、仅 h3、自定义端口、静态伪装、无伪装、探针密道、内网 ACL） | ✅ 全部通过 |
| **运行时行为** | 真实 Caddy 运行时验证：h1/h2/h3 监听、`caddy reload`、反代上游收到 `Host: <上游>`（`{upstream_hostport}` 生效）、静态页 200 / 不存在路径 404 | ✅ |
| 安装全流程 | 对 `cmd_install` 全流程做打桩冒烟测试（含系统版本检测、端口检查、配置生成、服务写入、客户端文件生成、结果输出） | ✅ 正常结束 |
| `acme_eab` 语法 | 实测发现 Caddy 全局选项的 `acme_eab` **必须使用块语法**（`key_id`/`mac_key`），已修正 | ✅ |
| 上游行为确认 | 阅读 `klzgrad/forwardproxy@naive` 的 `forwardproxy.go`/`caddyfile.go` 源码确认：① `probe_resistance` 下未鉴权请求会 `return next.ServeHTTP(...)`，即交给 `route` 中的伪装内容（反代/静态页）；② `forward_proxy` 的全部子指令名（`basic_auth`/`hosts`/`ports`/`hide_ip`/`hide_via`/`probe_resistance`/`serve_pac`/`dial_timeout`/`max_idle_conns`/`max_idle_conns_per_host`/`upstream`/`acl`）；③ 默认 ACL 策略与默认指令顺序（after `file_server`） | ✅ |
| 管理命令 | 打桩环境下逐条执行 `status` / `info` / `menu` / `restart` / `log` / `uninstall --yes`，并检查卸载后无残留文件 | ✅ |
| `curl \| bash` 场景 | 交互输入改为优先读写 `/dev/tty`（管道喂入 stdin 时也能正常交互），并在无可用终端时自动退化为非交互 | ✅ |
| 状态文件与只读变量冲突 | 实测发现 `site.env` 里的 `SCRIPT_VERSION` 与脚本只读变量同名会导致 `status`/`menu` 报错，已改名并让读取状态文件容错 | ✅ 已修正 |

> 本脚本无法替你在目标机器上申请证书（需要你的真实域名与公网环境），因此**首次安装后请务必确认证书签发成功**：
> `sudo bash naiveproxy-install.sh status`

---

## 13. 常见问题 FAQ

**Q1：安装后客户端连不上怎么办？**
按顺序检查：① 云安全组是否放行 443/tcp（h3 还需 443/udp）；② `systemctl status caddy` 是否 running；
③ `sudo bash naiveproxy-install.sh status` 里证书是否已签发；④ 客户端是否开启了 TLS 且 SNI 填的是**域名**（不是 IP）。
详见 [docs/运维与排错.md](docs/运维与排错.md)。

**Q2：证书申请失败，日志里有 rate limit？**
`*.nip.io` 命中 Let's Encrypt 共享额度。改用 ZeroSSL 重装即可：
`sudo bash naiveproxy-install.sh install --ca zerossl --email 你的邮箱 --yes --force`。

**Q3：可以用 IP 直连吗？**
不行。NaiveProxy 依赖域名 + 有效证书 + SNI，用 IP 会立刻暴露特征。请使用 nip.io 或自有域名。

**Q4：为什么反代 bing 后访问站点是 502？**
说明服务器无法访问该上游站点（被墙/被风控/需要代理）。换一个服务器能正常访问的站点：
`--masq-target https://你确定能访问的站点`；或者用 `--masq static` 用本机静态页伪装。

**Q5：HTTP/3 有什么用？要开吗？**
QUIC 在丢包严重的跨境线路上通常更快，且部分网络对 UDP 443 不限速。默认同时开 h2+h3，客户端自己选。
如果所在网络对 UDP QoS 严重，可以 `--http3 h2only`。

**Q6：能装 Clash/mihomo 客户端吗？**
mihomo（Clash Meta）目前**没有** naive 出站支持；请使用官方 naive 客户端、NekoBox/Husi/Exclave、v2rayN、sing-box 等。

**Q7：会影响我服务器上已有的网站吗？**
脚本占用 80/443。若已被占用会提示并可自动停止占用进程；如果你已有 Nginx/Apache/Caddy，建议改用其它端口或把反代伪装指向本机站点。

**Q8：怎么换伪装站点 / 换域名 / 换端口？**
重新运行安装并加 `--force`（会备份原 Caddyfile），例如
`sudo bash naiveproxy-install.sh install --domain new.example.com --masq-target https://example.org --force`。
⚠ 换域名会重新申请证书（消耗 CA 配额）。

更多问答与排错命令见 [docs/运维与排错.md](docs/运维与排错.md)。

---

## 14. 安全说明与免责声明

- 本脚本安装的是**实验性**项目（上游明确标注 `EXPERIMENTAL`），请勿用于人身安全受威胁的场景；
- Caddyfile 与 `site.env` 中含代理密码，权限已收紧为 0600/0640，请勿随意分享或提交到代码仓库；
- 默认以 `caddy` 非 root 用户运行，且禁止代理访问内网；`--allow-private` 会放宽该限制（有被用作内网跳板的风险）；
- 请遵守你所在国家/地区的法律法规，仅供学习与研究使用；使用本脚本产生的任何后果由使用者自行承担。

---

## 15. 相关文档

| 文档 | 内容 |
| --- | --- |
| [docs/客户端配置.md](docs/客户端配置.md) | 各平台客户端的完整配置步骤与导入方式 |
| [docs/证书与CA.md](docs/证书与CA.md) | 自动 HTTPS、Let's Encrypt 限速、ZeroSSL EAB、自定义 ACME、证书排查 |
| [docs/运维与排错.md](docs/运维与排错.md) | 服务管理、日志、性能调优、备份迁移、排错表、卸载 |
| [examples/Caddyfile.example](examples/Caddyfile.example) | 生成的 Caddyfile 示例（占位符版本） |
| [examples/naive-config.json](examples/naive-config.json) | 官方客户端配置示例 |
| [examples/sing-box-outbound.json](examples/sing-box-outbound.json) | sing-box 出站示例 |
| [examples/caddy.service](examples/caddy.service) | systemd 服务单元示例 |

### 致谢 / 上游项目

- [klzgrad/naiveproxy](https://github.com/klzgrad/naiveproxy) —— NaiveProxy 客户端与设计
- [klzgrad/forwardproxy@naive](https://github.com/klzgrad/forwardproxy/tree/naive) —— 服务端 Caddy 插件（填充层）
- [caddyserver/caddy](https://github.com/caddyserver/caddy) —— Web 服务器与自动 HTTPS
- [publicsuffix/list](https://github.com/publicsuffix/list) —— 验证 `nip.io` 不在 PSL 中

---

## License

MIT
