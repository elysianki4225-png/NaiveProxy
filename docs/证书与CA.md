# 证书与 ACME CA 详解

本篇解释：证书为什么重要、Let's Encrypt 的限速到底怎么算（**为什么 `*.nip.io` 容易失败**）、
如何切换到 ZeroSSL、如何自定义 ACME、以及证书申请失败的排查清单。

---

## 1. 证书为什么是 NaiveProxy 的命门

NaiveProxy 的伪装原理是「让流量与真实 Chrome 访问普通 HTTPS 网站无法区分」。因此：

- 必须使用**公开信任的 CA 签发的证书**（Let's Encrypt / ZeroSSL / 商业 CA 都行）；
- **不能**使用自签证书（`tls internal`）、Let's Encrypt staging 证书、或过期证书——
  证书链异常会让中间设备一眼区分出「这不是正常网站」；
- 必须使用**域名**访问（SNI），不能用 IP 直连。

Caddy 默认开启 [Automatic HTTPS](https://caddyserver.com/docs/automatic-https)：
只要 Caddyfile 的站点地址是域名（如 `:443, proxy.example.com`），它就会自动向 ACME CA 申请证书并自动续期。

---

## 2. Let's Encrypt 的限速：为什么 `*.nip.io` 常常申请失败

Let's Encrypt 的官方限额（[Rate Limits](https://letsencrypt.org/docs/rate-limits/)）：

| 限额 | 数值 | 补充速度 | 说明 |
| --- | --- | --- | --- |
| New Certificates per Registered Domain | **50 张 / 7 天** | 1 张 / 202 分钟 | 统计单位是「**注册域**」= Public Suffix List 中的 eTLD+1，**所有子域共享** |
| New Certificates per Exact Set of Identifiers | **5 张 / 7 天** | 1 张 / 34 小时 | 完全相同的域名组合（例如同一个域名反复重装） |
| New Orders per Account | 300 / 3 小时 | - | 同一 ACME 账户 |
| Failed Validations per Account per Hostname | 5 / 小时 | - | 同一域名校验失败次数 |

### 2.1 关键事实：`nip.io` 不在 Public Suffix List 中

本脚本直接核对了 Public Suffix List 官方数据（ICANN 段 + Private 段，共约 1.65 万行）：

```console
$ grep -x "nip.io" public_suffix_list.dat      # 无输出
$ grep -x "sslip.io" public_suffix_list.dat    # 无输出（localtest.me / lvh.me / xip.io / traefik.me 同样没有）
```

这意味着：

> **Let's Encrypt 会把 `*.nip.io` 全部视为同一个注册域 `nip.io`。**
> 全世界的用户共享那 **50 张 / 7 天** 的额度；同一个完整域名（如 `abc.1.2.3.4.nip.io`）
> 还额外受 **5 张 / 7 天** 限制（重新安装 5 次就会撞上）。

典型报错：

```
Error: could not get certificate: too many certificates (50) already issued for "nip.io" in the last 168h0m0s
Error: too many certificates already issued for exact set of domains: abc.1.2.3.4.nip.io
```

### 2.2 本脚本给出的四种解法

| 方案 | 做法 | 适用场景 |
| --- | --- | --- |
| ① 随机前缀 | 每次安装生成 `<随机8位>.<IP>.nip.io` | 规避「同名组合 5 张/周」，用 nip.io 时的**必做项**（脚本默认） |
| ② 换 CA（推荐） | `--ca zerossl`（脚本自动取 EAB） | 立刻绕开 nip.io 的共享额度 |
| ③ 自有域名 | `--domain proxy.example.com`（A 记录指向本机） | **生产环境首选**，名额只属于你自己的注册域 |
| ④ DNS-01 通配符 | 自行在 Caddyfile 加 `tls { dns <provider> }` + Caddy DNS 插件 | 一个域名下大量子域，且需要 DNS 服务商 API |

> ⚠️ 注意：切换 CA 只解决「额度」问题；如果域名根本不解析到本机，任何 CA 都签不下来。

---

## 3. 切换到 ZeroSSL（脚本已内置）

ZeroSSL 提供免费的 90 天 DV 证书，**没有** Let's Encrypt 那种「按注册域 50 张/周」的限制
（免费账户有单独的签发政策，对个人自用完全够用）。

### 3.1 使用（推荐）

```bash
sudo bash naiveproxy-install.sh install --ca zerossl --email you@example.com --force
```

脚本会：

1. 在 Caddyfile 全局块写入 `acme_ca https://acme.zerossl.com/v2/DV90`；
2. 用你的邮箱向 ZeroSSL 的 EAB 接口申请凭据：
   ```
   POST https://api.zerossl.com/acme/eab-credentials-email   (email=you@example.com)
   → {"success":true,"eab_kid":"...","eab_hmac_key":"..."}
   ```
3. 以**块语法**写入 Caddyfile（Caddy 全局选项 `acme_eab` 只接受这种写法，写成一行会报
   `wrong argument count ... after 'xxx'`）：
   ```caddyfile
   acme_eab {
       key_id  <EAB Key ID>
       mac_key <EAB HMAC Key>
   }
   ```

### 3.2 手工获取 EAB（自动获取被限流时）

1. 打开 <https://app.zerossl.com/developer>（登录后 Developer 页面）；
2. 生成 **ACME EAB Credentials**，得到 `EAB Key ID` 与 `EAB HMAC Key`；
3. 重装时传入：
   ```bash
   sudo bash naiveproxy-install.sh install --ca zerossl --email you@example.com \
        --eab 'EAB_Key_ID:EAB_HMAC_Key' --force
   ```

### 3.3 两个容易混淆的东西

| 名称 | 用途 | 在本项目中的位置 |
| --- | --- | --- |
| **EAB Credentials**（Key ID + HMAC Key） | 给 **ACME** 协议做账户绑定 | ✅ 本项目使用（`acme_eab` / `--eab`） |
| **API Key**（Dashboard 里的 Access Key） | 给 **REST API** 用（Caddy 的 `issuer zerossl <api_key>` 用这个） | ❌ 本项目不使用 |

### 3.4 ZeroSSL 的两个注意点

- **只支持 HTTP-01 / DNS-01 校验**（不支持 TLS-ALPN-01），因此 **80 端口必须对外可用**；
  脚本在防火墙配置中会自动放行 80/tcp；
- 如果服务器上有 Cloudflare 小黄云（代理开启），HTTP-01 会失败，需先改为 **DNS only**。

---

## 4. 其它 CA 与自定义 ACME

### 4.1 Let's Encrypt（默认）

```bash
sudo bash naiveproxy-install.sh install --ca letsencrypt --email you@example.com
```

Caddyfile 中不写 `acme_ca` 时，Caddy 使用 Let's Encrypt 生产环境端点（优先 TLS-ALPN-01，回退 HTTP-01）。

### 4.2 Let's Encrypt staging（测试用）

```bash
sudo bash naiveproxy-install.sh install --ca letsencrypt-staging
```

staging 证书**不被浏览器信任**，仅用于验证 ACME 流程是否正确，切勿用于实际使用。

### 4.3 自定义 ACME 目录

```bash
sudo bash naiveproxy-install.sh install --ca custom \
     --acme-ca https://acme.example.com/v2/directory --email you@example.com
```

若该 CA 需要 EAB，可再补 `--eab 'KeyID:HMACKey'`。常见的兼容 ACME 服务：

| 服务 | ACME 目录 | 备注 |
| --- | --- | --- |
| ZeroSSL | `https://acme.zerossl.com/v2/DV90` | 需要 EAB（脚本自动获取） |
| Let's Encrypt | `https://acme-v02.api.letsencrypt.org/directory` | 默认值 |
| 其它 ACME 兼容 CA | 以其官方文档为准 | 端点与 EAB 要求可能调整，使用前请自行确认 |
| Google Trust Services | `https://dv.acme-v02.api.pki.goog/directory` | 需要 EAB |
| 自建 step-ca / Smallstep | 你自建的目录 URL | 需要把根证书加入系统信任（或在 Caddyfile 用 `acme_ca_root`） |
| Let's Encrypt staging | `https://acme-staging-v02.api.letsencrypt.org/directory` | 测试用 |

> 自建 CA 若要给 Caddy 指定根证书，可在全局块添加 `acme_ca_root /path/to/root.pem`（需手工编辑 Caddyfile）。

---

## 5. 手动使用已有证书（企业证书 / 通配符证书）

把站点块里的自动 HTTPS 换成手动加载：

```caddyfile
:443, proxy.example.com {
	tls /etc/ssl/fullchain.pem /etc/ssl/privkey.pem
	route {
		forward_proxy {
			basic_auth 用户名 密码
			hide_ip
			hide_via
			probe_resistance
		}
		reverse_proxy https://floridahigh.fyi {
			header_up Host {upstream_hostport}
		}
	}
}
```

改完执行：

```bash
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo systemctl reload caddy
```

---

## 6. 通配符证书（DNS-01）

需要 Caddy 的 DNS 提供者插件（本脚本下载的官方预编译包**不含**这些插件，需要自己用 `xcaddy` 编译）：

```bash
# 例：Cloudflare 通配符
xcaddy build v2.11.7 \
  --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive \
  --with github.com/caddy-dns/cloudflare
```

Caddyfile：

```caddyfile
{
	acme_ca https://acme.zerossl.com/v2/DV90
	acme_eab {
		key_id  xxx
		mac_key xxx
	}
}

:443, *.example.com {
	tls {
		dns cloudflare {env.CLOUDFLARE_API_TOKEN}
	}
	route { ... }
}
```

---

## 7. 重新签发 / 查看有效期

```bash
# 查看当前证书签发者与到期时间
sudo bash naiveproxy-install.sh status

# 强制重新申请（会先移走本地证书缓存，⚠ 消耗 CA 配额）
sudo bash naiveproxy-install.sh renew

# 手动查看证书文件（ACME 存储目录）
sudo ls -R /var/lib/caddy/.local/share/caddy/certificates
```

Caddy 会在证书剩余寿命约 1/3 时**自动续期**，正常情况下你不需要做任何事。

---

## 8. 证书申请失败排查清单

按顺序核对（`journalctl -u caddy -n 100 --no-pager` 可以看到具体错误）：

| # | 检查项 | 说明 |
| --- | --- | --- |
| 1 | 域名解析 | `dig +short 你的域名` 必须等于服务器公网 IPv4；脚本安装时也会检查并提示 |
| 2 | Cloudflare 小黄云 | HTTP-01/TLS-ALPN-01 都会失败，必须改为 **DNS only**（灰云） |
| 3 | 80 / 443 端口 | 80 用于 HTTP-01（ZeroSSL 必需），443/tcp 用于 TLS-ALPN-01；云安全组 + 系统防火墙都要放行 |
| 4 | AAAA 记录 | 若同时存在 AAAA 且指向错误地址，CA 可能走 IPv6 校验而失败，建议先删掉 AAAA |
| 5 | 占位/停靠页 | 若前置有 Nginx/CDN 抢占了 80 端口，ACME 校验会失败 |
| 6 | CAA 记录 | 域名若配置了 CAA，必须允许所用 CA（如 `0 issue "letsencrypt.org"` / `"sectigo.com"`（ZeroSSL）） |
| 7 | 限速 | 见 `too many certificates ...`，换 CA 或用新域名组合 |
| 8 | 服务器出网被墙 | 在中国大陆服务器上，`acme-v02.api.letsencrypt.org` 可能超时 → 改用 ZeroSSL |
| 9 | 系统时间偏差过大 | `timedatectl` 确认时间同步（ACME 依赖时间正确） |
| 10 | 证书未签发但服务在跑 | Caddy 会用内部临时证书先提供 TLS，表现为 `issuer=Caddy Local Authority`，说明 ACME 还没成功 |

确认后重试：

```bash
sudo bash naiveproxy-install.sh renew          # 重新申请
# 或换 CA 重装
sudo bash naiveproxy-install.sh install --ca zerossl --email you@example.com --force
```
