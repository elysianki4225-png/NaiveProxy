#!/usr/bin/env bash
# ==============================================================================
#  NaiveProxy 一键安装 / 配置 / 管理脚本
#
#  项目主页: https://github.com/elysianki4225-png/NaiveProxy
#  上游组件: https://github.com/klzgrad/naiveproxy  (客户端)
#            https://github.com/klzgrad/forwardproxy (服务端 Caddy 插件, naive 分支)
#
#  适用系统: Debian 11+ / Ubuntu 20.04+  (x86_64 / aarch64 / armv7l)
#  部署内容: caddy-forwardproxy-naive (带 NaiveProxy 填充层的 Caddy)
#            + systemd 守护进程 + 自动 HTTPS 证书 + 探针伪装(反代/静态页)
#
#  用法:
#    bash naiveproxy-install.sh                 # 交互式一键安装
#    bash naiveproxy-install.sh install --yes   # 非交互安装(全部默认值)
#    bash naiveproxy-install.sh menu            # 管理菜单
#    bash naiveproxy-install.sh help            # 查看全部参数
#
#  许可: MIT
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# 常量
# ------------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="naiveproxy-install.sh"
readonly REPO_URL="https://github.com/elysianki4225-png/NaiveProxy"
readonly CADDY_BIN="/usr/local/bin/caddy"
readonly CADDY_ETC="/etc/caddy"
readonly CADDYFILE="${CADDY_ETC}/Caddyfile"
readonly STATE_DIR="${CADDY_ETC}/naiveproxy"
readonly STATE_FILE="${STATE_DIR}/site.env"
readonly CLIENT_DIR="${STATE_DIR}/client"
readonly CADDY_HOME="/var/lib/caddy"
readonly CADDY_DATA="${CADDY_HOME}/data"
readonly CADDY_USER="caddy"
readonly SERVICE_NAME="caddy"
readonly SERVICE_FILE="/etc/systemd/system/caddy.service"
readonly WEBROOT_DEFAULT="/var/www/naiveproxy"
WEBROOT="$WEBROOT_DEFAULT"    # 静态伪装页面根目录（--webroot 覆盖）
readonly LOG_FILE="/var/log/naiveproxy-install.log"
readonly SYSCTL_FILE="/etc/sysctl.d/99-naiveproxy.conf"

# 上游版本（可被 --caddy-version 覆盖）
readonly FORWARDPROXY_REPO="klzgrad/forwardproxy"
readonly FORWARDPROXY_BRANCH="naive"
readonly DEFAULT_CADDY_VERSION="v2.11.7"

# 默认配置（可被命令行参数覆盖）
DOMAIN=""                              # 访问域名
DOMAIN_PREFIX=""                       # nip.io 随机前缀
PUBLIC_IP=""                           # 公网 IPv4
ACME_EMAIL=""                          # ACME 邮箱
CA_MODE="letsencrypt"                  # letsencrypt | zerossl | letsencrypt-staging | custom
ACME_CA_URL=""                         # 自定义 ACME 目录
EAB_KID=""                             # ZeroSSL EAB Key ID
EAB_HMAC=""                            # ZeroSSL EAB HMAC Key
PROXY_USER=""                          # 代理用户名
PROXY_PASS=""                          # 代理密码
HTTPS_PORT="443"                       # HTTPS 端口
HTTP_PORT="80"                         # HTTP 端口(证书校验/跳转用)
HTTP3="auto"                           # auto | on | off   (h3=QUIC/UDP443)
MASQ_MODE="reverse"                    # reverse | static | none
MASQ_TARGET="https://www.bing.com"     # 反向代理伪装目标
PROBE_SECRET=""                        # 探针密道域名(可选)
RUN_AS="caddy"                         # caddy | root
ENABLE_FIREWALL="auto"                 # auto | yes | no
ENABLE_BBR="auto"                      # auto | yes | no
CADDY_VERSION="${DEFAULT_CADDY_VERSION}"
INSTALL_METHOD="auto"                  # auto | prebuilt | source | api
FP_TAG=""                              # forwardproxy 预编译包 tag
ALLOW_PRIVATE_NETS="no"                # yes = 允许代理访问内网
FORCE="no"                             # yes = 覆盖已有安装
ASSUME_YES="no"                        # yes = 非交互，全部使用默认值
INTERACTIVE="auto"                     # auto | yes | no

# 运行时状态
OS_ID=""; OS_VERSION=""; OS_CODENAME=""; ARCH=""; CADDY_INSTALL_METHOD=""
QUIET="no"
UPGRADE_MODE="no"

# 颜色
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

# ------------------------------------------------------------------------------
# 日志与输出
# ------------------------------------------------------------------------------
_log_line() {
  local level="$1"; shift
  [[ -w "$(dirname "$LOG_FILE")" ]] || return 0
  printf '%s [%-5s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

info()    { printf '%s\n' "${C_BLUE}ℹ${C_RESET} $*"; _log_line INFO "$*"; }
ok()      { printf '%s\n' "${C_GREEN}✔${C_RESET} $*"; _log_line OK "$*"; }
warn()    { printf '%s\n' "${C_YELLOW}⚠${C_RESET} $*" >&2; _log_line WARN "$*"; }
err()     { printf '%s\n' "${C_RED}✘${C_RESET} $*" >&2; _log_line ERROR "$*"; }
die()     { err "$*"; printf '\n%s\n' "${C_RED}安装/操作已终止。${C_RESET} 日志: ${LOG_FILE}" >&2; exit 1; }
hint()    { printf '%s\n' "${C_DIM}  $*${C_RESET}"; }
blank()   { printf '\n'; }

section() {
  printf '\n%s\n' "${C_BOLD}${C_CYAN}────────────────────────────────────────────────────────────────${C_RESET}"
  printf '%s\n' "${C_BOLD}${C_CYAN}  $*${C_RESET}"
  printf '%s\n' "${C_BOLD}${C_CYAN}────────────────────────────────────────────────────────────────${C_RESET}"
  _log_line STEP "=== $* ==="
}

step() { printf '%s\n' "${C_BOLD}▶ $*${C_RESET}"; _log_line STEP "$*"; }

trap 'err "脚本在第 ${LINENO} 行执行失败（命令: ${BASH_COMMAND}）"; _log_line ERROR "failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------------------
# 交互读取（兼容 curl | bash 场景：优先读 /dev/tty）
# ------------------------------------------------------------------------------
can_prompt() {
  [[ "$ASSUME_YES" == "yes" ]] && return 1      # --yes 表示全部使用默认值
  [[ "$INTERACTIVE" == "no" ]] && return 1
  [[ "$INTERACTIVE" == "yes" ]] && return 0
  [[ "$TTY_OK" == "yes" ]] && return 0
  [[ -t 0 ]] && return 0
  return 1
}

# 是否真的能打开 /dev/tty（有些环境（如无控制终端、CI）里 /dev/tty 存在但不可用）
TTY_OK="no"
if [[ -r /dev/tty && -w /dev/tty ]]; then
  if { : >/dev/tty; } 2>/dev/null; then TTY_OK="yes"; fi
fi

# 输出交互提示：优先写到 /dev/tty（curl | bash 也能正常交互），没有可用 tty 时退回标准输出
_prompt_out() {
  if [[ "$TTY_OK" == "yes" ]]; then
    printf '%s' "$1" >/dev/tty 2>/dev/null && return 0
  fi
  printf '%s' "$1"
}

_tty_read() {
  local __var="$1"; shift
  local line
  if [[ "$TTY_OK" == "yes" ]]; then
    IFS= read -r "$@" line </dev/tty || return 1
  else
    IFS= read -r "$@" line || return 1
  fi
  printf -v "$__var" '%s' "$line"
}

# ask <变量名> <提示语> <默认值> [校验函数]
ask() {
  local __var="$1" prompt="$2" default="${3:-}" validator="${4:-}"
  local input
  if ! can_prompt; then
    printf -v "$__var" '%s' "$default"
    return 0
  fi
  while :; do
    if [[ -n "$default" ]]; then
      _prompt_out "${C_CYAN}?${C_RESET} ${prompt} ${C_DIM}[${default}]${C_RESET} "
    else
      _prompt_out "${C_CYAN}?${C_RESET} ${prompt} "
    fi
    _tty_read input || { printf -v "$__var" '%s' "$default"; return 0; }
    [[ -z "$input" && -n "$default" ]] && input="$default"
    if [[ -n "$validator" ]] && ! "$validator" "$input"; then
      err "输入不合法，请重新输入。"
      continue
    fi
    printf -v "$__var" '%s' "$input"
    return 0
  done
}

# ask_yn <提示语> <默认 yes|no>  返回 0=是 1=否
ask_yn() {
  local prompt="$1" default="${2:-no}" input suffix
  if [[ "$ASSUME_YES" == "yes" ]]; then
    [[ "$default" == "yes" ]] && return 0 || return 1
  fi
  can_prompt || { [[ "$default" == "yes" ]] && return 0 || return 1; }
  [[ "$default" == "yes" ]] && suffix="[Y/n]" || suffix="[y/N]"
  _prompt_out "${C_CYAN}?${C_RESET} ${prompt} ${suffix} "
  _tty_read input || input=""
  input="${input:-$default}"
  case "${input,,}" in
    y|yes|是) return 0 ;;
    *)        return 1 ;;
  esac
}

# choose <变量名> <提示语> <默认序号> <选项1> <选项2> ...
choose() {
  local __var="$1" prompt="$2" default="$3"; shift 3
  local -a options=("$@")
  local i input
  if ! can_prompt; then
    printf -v "$__var" '%s' "${options[$((default-1))]}"
    printf -v "${__var}_IDX" '%s' "$default"
    return 0
  fi
  local menu_text=$'\n'
  menu_text+="${C_BOLD}${prompt}${C_RESET}"$'\n'
  for i in "${!options[@]}"; do
    menu_text+="  $((i+1))) ${options[$i]}"$'\n'
  done
  _prompt_out "$menu_text"
  while :; do
    _prompt_out "${C_CYAN}→${C_RESET} 请选择 (默认 ${default}): "
    _tty_read input || { input="$default"; }
    input="${input:-$default}"
    if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= ${#options[@]} )); then
      printf -v "$__var" '%s' "${options[$((input-1))]}"
      printf -v "${__var}_IDX" '%s' "$input"
      return 0
    fi
    err "请输入 1-${#options[@]} 之间的数字。"
  done
}

confirm_danger() {
  local prompt="$1"
  if [[ "$ASSUME_YES" == "yes" ]]; then return 0; fi
  can_prompt || return 1
  local input
  _prompt_out "${C_RED}⚠ ${prompt} 请输入 yes 确认:${C_RESET} "
  _tty_read input || input=""
  [[ "$input" == "yes" ]]
}

# ------------------------------------------------------------------------------
# 环境检测与基础依赖
# ------------------------------------------------------------------------------
require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "请使用 root 运行本脚本：sudo bash ${SCRIPT_NAME}"
}

detect_os() {
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release，仅支持 Debian/Ubuntu 系统。"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-0}"
  OS_CODENAME="${VERSION_CODENAME:-unknown}"

  case "$OS_ID" in
    debian)
      local major="${OS_VERSION%%.*}"
      (( major >= 11 )) || die "Debian ${OS_VERSION} 版本过低，需要 Debian 11 (bullseye) 或更高版本。"
      ;;
    ubuntu)
      local major="${OS_VERSION%%.*}"
      if (( major < 20 )); then
        die "Ubuntu ${OS_VERSION} 版本过低，需要 Ubuntu 20.04 (focal) 或更高版本。"
      fi
      ;;
    *)
      warn "未在 Debian/Ubuntu 上测试（当前: ${OS_ID} ${OS_VERSION}）。脚本将尝试继续，但可能失败。"
      if ! can_prompt || ! ask_yn "仍要继续吗？" "no"; then die "已取消。"; fi
      ;;
  esac
}

detect_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64)   ARCH="amd64" ;;
    aarch64|arm64)  ARCH="arm64" ;;
    armv7l|armv6l)  ARCH="armv7" ;;
    *)
      warn "未识别的 CPU 架构: ${machine}，将尝试源码编译。"
      ARCH="$machine"
      ;;
  esac
}

check_systemd() {
  have systemctl || die "未检测到 systemd，本脚本依赖 systemd 管理服务。"
  [[ -d /run/systemd/system ]] || warn "systemd 似乎未作为 init 运行，服务管理可能失败。"
}

apt_quiet() {
  DEBIAN_FRONTEND=noninteractive apt-get \
    -o Acquire::Retries=3 -o Dpkg::Options::="--force-confold" "$@"
}

install_packages() {
  have apt-get || die "未找到 apt-get，本脚本仅支持 Debian/Ubuntu 系发行版。"
  local pkgs=(ca-certificates curl tar xz-utils openssl jq iproute2 procps gnupg)
  local need=()
  local p c
  for p in "${pkgs[@]}"; do
    case "$p" in
      ca-certificates) [[ -f /etc/ssl/certs/ca-certificates.crt ]] || need+=("$p") ;;
      jq)              have jq || need+=("$p") ;;
      iproute2)        have ss || need+=("$p") ;;
      procps)          have pgrep || need+=("$p") ;;
      gnupg)           have gpg || need+=("$p") ;;
      *)               have "$p" || need+=("$p") ;;
    esac
  done
  [[ ${#need[@]} -eq 0 ]] && { ok "基础依赖已满足。"; return 0; }

  step "安装基础依赖: ${need[*]}"
  apt-get update -qq
  apt_quiet install -y -qq "${need[@]}" >>"$LOG_FILE" 2>&1 || {
    warn "依赖安装出现异常，请检查网络/软件源。"
    apt_quiet install -y "${need[@]}" || die "基础依赖安装失败。"
  }
  ok "基础依赖安装完成。"
}

# ------------------------------------------------------------------------------
# IP / 域名 工具
# ------------------------------------------------------------------------------
valid_ipv4() {
  local ip="$1" IFS=. a b c d
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  read -r a b c d <<<"$ip"
  for a in "$a" "$b" "$c" "$d"; do (( a >= 0 && a <= 255 )) || return 1; done
  return 0
}

is_public_ipv4() {
  valid_ipv4 "$1" || return 1
  local ip="$1"
  case "$ip" in
    10.*|127.*|0.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[0-2][0-9].*) return 1 ;;
  esac
  return 0
}

http_get_plain() { # $1=url
  curl -fsSL --connect-timeout 6 --max-time 12 -A "curl/naiveproxy-install" "$1" 2>/dev/null
}

get_public_ipv4() {
  local ip="" url
  local urls=(
    "https://ipv4.icanhazip.com"
    "https://api.ipify.org"
    "https://ipinfo.io/ip"
    "https://ifconfig.me/ip"
    "https://4.ident.me"
    "https://checkip.amazonaws.com"
  )
  for url in "${urls[@]}"; do
    ip="$(http_get_plain "$url" | tr -d '[:space:]' || true)"
    if is_public_ipv4 "$ip"; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  # 退而求其次：从默认路由推断（可能是内网 IP，需要用户确认）
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  if valid_ipv4 "$ip"; then
    printf '%s\n' "$ip"
    return 2
  fi
  return 1
}

rand_string() { # $1=长度
  local n="${1:-8}" s=""
  if have openssl; then
    s="$(openssl rand -base64 48 2>/dev/null | tr -dc 'a-z0-9' | head -c "$n" || true)"
  fi
  if [[ -z "$s" ]]; then
    s="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c "$n" || true)"
  fi
  if [[ -z "$s" ]]; then
    s="$(date +%s%N | sha256sum | tr -dc 'a-z0-9' | head -c "$n")"
  fi
  printf '%s\n' "$s"
}

# 生成对浏览器/客户端都安全的密码（URL 中无需转义）
gen_password() { rand_string "${1:-24}"; }
gen_username() { printf 'u%s\n' "$(rand_string 8)"; }

valid_domain() {
  local d="$1"
  [[ "$d" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]
}

valid_username() {
  [[ "$1" =~ ^[A-Za-z0-9._-]{1,32}$ ]]
}

valid_password() {
  [[ "$1" =~ ^[A-Za-z0-9._-]{8,64}$ ]]
}

# 允许留空（留空表示随机生成）
valid_username_opt() { [[ -z "$1" ]] || valid_username "$1"; }
valid_password_opt() { [[ -z "$1" ]] || valid_password "$1"; }

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

resolve_ipv4() { # 解析域名，返回第一个 IPv4
  local d="$1" ip=""
  if have dig; then
    ip="$(dig +short A "$d" 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)"
  fi
  if [[ -z "$ip" ]] && have getent; then
    ip="$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1; exit}' || true)"
  fi
  if [[ -z "$ip" ]] && have host; then
    ip="$(host -t A "$d" 2>/dev/null | awk '/has address/{print $4; exit}' || true)"
  fi
  printf '%s\n' "$ip"
}

port_listening() { # $1=port
  ss -H -lntu "sport = :$1" 2>/dev/null | grep -q . && return 0
  ss -H -lnt "sport = :$1" 2>/dev/null | grep -q . && return 0
  return 1
}

port_owner() {
  ss -H -lntup "sport = :$1" 2>/dev/null | awk 'NR==1{print $0}' | head -c 200
}

# ------------------------------------------------------------------------------
# Caddy (forwardproxy-naive) 安装
# ------------------------------------------------------------------------------
caddy_bin_version() {
  [[ -x "$CADDY_BIN" ]] || return 1
  "$CADDY_BIN" version 2>/dev/null | head -n1 | tr -d '\r'
}

caddy_has_forwardproxy() { # $1=二进制路径
  local bin="${1:-$CADDY_BIN}"
  [[ -x "$bin" ]] || return 1
  "$bin" list-modules 2>/dev/null | grep -qx 'http.handlers.forward_proxy'
}

caddy_build_info_is_naive() { # 检查是否用了 klzgrad 的 naive fork
  local bin="${1:-$CADDY_BIN}"
  "$bin" build-info 2>/dev/null | grep -qi 'klzgrad/forwardproxy'
}

latest_fp_tag() {
  local tag=""
  tag="$(curl -fsSL -m 25 "https://api.github.com/repos/${FORWARDPROXY_REPO}/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null || true)"
  if [[ -z "$tag" ]]; then
    tag="$("$(command -v gh || echo /nonexistent)" api "repos/${FORWARDPROXY_REPO}/releases/latest" --jq '.tag_name' 2>/dev/null || true)"
  fi
  printf '%s\n' "$tag"
}

fetch_file() { # $1=url $2=输出文件
  local url="$1" out="$2"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --progress-bar \
       -A "naiveproxy-install/${SCRIPT_VERSION}" -o "$out" "$url"
}

install_caddy_prebuilt() {
  step "方式 1/3：下载官方预编译二进制（含 QUIC-BBR 补丁，推荐）"
  local tag="${FP_TAG:-}"
  if [[ -z "$tag" ]]; then
    tag="$(latest_fp_tag || true)"
  fi
  if [[ -z "$tag" ]]; then
    tag="${CADDY_VERSION}-naive"
  fi
  local url="https://github.com/${FORWARDPROXY_REPO}/releases/download/${tag}/caddy-forwardproxy-naive.tar.xz"
  local tmp; tmp="$(mktemp -d)"
  info "下载: ${url}"
  if ! fetch_file "$url" "${tmp}/caddy.tar.xz" >>"$LOG_FILE" 2>&1; then
    warn "预编译包下载失败（该版本可能没有对应 CPU 架构的产物，预编译包目前为 linux-amd64）。"
    rm -rf "$tmp"; return 1
  fi
  if ! tar -xJf "${tmp}/caddy.tar.xz" -C "$tmp" >>"$LOG_FILE" 2>&1; then
    warn "压缩包解压失败。"; rm -rf "$tmp"; return 1
  fi
  local found
  found="$(find "$tmp" -maxdepth 3 -type f -name caddy -perm -u+x | head -n1)"
  [[ -n "$found" ]] || { warn "压缩包内未找到 caddy 可执行文件。"; rm -rf "$tmp"; return 1; }

  install -m 0755 "$found" "${CADDY_BIN}.new"
  if ! caddy_has_forwardproxy "${CADDY_BIN}.new"; then
    warn "下载的二进制缺少 forward_proxy 模块，放弃该方式。"
    rm -f "${CADDY_BIN}.new"; rm -rf "$tmp"; return 1
  fi
  mv -f "${CADDY_BIN}.new" "$CADDY_BIN"
  rm -rf "$tmp"
  CADDY_INSTALL_METHOD="预编译二进制 (${tag}, naive fork)"
  ok "已安装: $("$CADDY_BIN" version 2>/dev/null | head -n1)"
  return 0
}

install_go_toolchain() {
  export PATH="/usr/local/go/bin:${PATH}"
  local need_major=1 need_minor=26
  local have_go=""
  if have go; then
    have_go="$(go version 2>/dev/null | awk '{print $3}')"
    local v="${have_go#go}"; local maj="${v%%.*}"; local rest="${v#*.}"; local min="${rest%%.*}"
    if (( maj > need_major || (maj == need_major && min >= need_minor) )); then
      ok "检测到 Go ${have_go}，满足要求。"
      return 0
    fi
    warn "系统自带 Go ${have_go} 版本过低（需要 ≥ ${need_major}.${need_minor}），将安装官方工具链。"
  fi

  step "安装 Go 工具链（源码编译 Caddy 需要 ≥ 1.${need_minor}）"
  local gover=""
  gover="$(curl -fsSL -m 15 "https://go.dev/VERSION?m=text" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
  [[ "$gover" =~ ^go1\. ]] || gover="go1.26.0"
  local goarch="$ARCH"
  case "$ARCH" in
    amd64)  goarch="amd64" ;;
    arm64)  goarch="arm64" ;;
    armv7)  goarch="armv6l" ;;
  esac
  local file="${gover}.linux-${goarch}.tar.gz"
  local tmp; tmp="$(mktemp -d)"
  local urls=(
    "https://go.dev/dl/${file}"
    "https://dl.google.com/go/${file}"
    "https://golang.google.cn/dl/${file}"
    "https://mirrors.aliyun.com/golang/${file}"
    "https://mirror.nju.edu.cn/golang/${file}"
  )
  local u ok_dl="no"
  for u in "${urls[@]}"; do
    info "下载 Go: ${u}"
    if fetch_file "$u" "${tmp}/${file}" >>"$LOG_FILE" 2>&1; then ok_dl="yes"; break; fi
    warn "下载失败，尝试下一个镜像..."
  done
  [[ "$ok_dl" == "yes" ]] || { rm -rf "$tmp"; die "Go 工具链下载失败，请手动安装 Go ≥ 1.${need_minor} 后重试。"; }

  rm -rf /usr/local/go
  tar -C /usr/local -xzf "${tmp}/${file}" >>"$LOG_FILE" 2>&1 || { rm -rf "$tmp"; die "Go 解压失败。"; }
  rm -rf "$tmp"
  export PATH="/usr/local/go/bin:${PATH}"
  hash -r
  ok "Go 安装完成: $(go version)"
}

build_caddy_from_source() {
  step "方式 2/3：源码编译（xcaddy + forwardproxy@naive）"
  have git || { info "安装编译所需依赖 git..."; apt_quiet install -y -qq git >>"$LOG_FILE" 2>&1 || warn "git 安装失败，编译可能失败。"; }
  install_go_toolchain

  local gopath="${HOME}/go"
  mkdir -p "$gopath/bin"
  export GOPATH="$gopath"
  export PATH="$GOPATH/bin:/usr/local/go/bin:${PATH}"
  export GO111MODULE=on CGO_ENABLED=0
  export GOTOOLCHAIN=auto
  hash -r

  if ! have xcaddy; then
    info "安装 xcaddy..."
    if ! go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest >>"$LOG_FILE" 2>&1; then
      warn "xcaddy 安装失败，尝试切换国内代理 GOPROXY..."
      GOPROXY="https://goproxy.cn,direct" go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest >>"$LOG_FILE" 2>&1 \
        || die "xcaddy 安装失败，请检查网络（可尝试 export GOPROXY=https://goproxy.cn,direct）。"
    fi
  fi
  hash -r
  have xcaddy || die "未找到 xcaddy。"

  local work="/usr/local/src/caddy-naiveproxy"
  mkdir -p "$work"
  local out="${work}/caddy"
  local ver="${CADDY_VERSION}"
  [[ "$ver" == v* ]] || ver="v${ver}"

  info "开始编译（首次编译约 3-10 分钟，取决于机器性能）..."
  info "命令: xcaddy build ${ver} --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@${FORWARDPROXY_BRANCH}"
  if ! (cd "$work" && xcaddy build "$ver" \
        --with "github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@${FORWARDPROXY_BRANCH}" \
        --output "$out") >>"$LOG_FILE" 2>&1; then
    warn "默认模块代理编译失败，改用 goproxy.cn 重试..."
    (cd "$work" && GOPROXY="https://goproxy.cn,direct" xcaddy build "$ver" \
        --with "github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@${FORWARDPROXY_BRANCH}" \
        --output "$out") >>"$LOG_FILE" 2>&1 \
      || { warn "源码编译失败，详见日志: ${LOG_FILE}"; return 1; }
  fi
  [[ -x "$out" ]] || { warn "编译产物不存在。"; return 1; }
  if ! caddy_has_forwardproxy "$out"; then
    warn "编译产物缺少 forward_proxy 模块。"; return 1
  fi
  install -m 0755 "$out" "$CADDY_BIN"
  CADDY_INSTALL_METHOD="源码编译 (xcaddy, forwardproxy@naive)"
  ok "已安装: $("$CADDY_BIN" version 2>/dev/null | head -n1)"
  return 0
}

install_caddy_download_api() {
  step "方式 3/3：使用 Caddy 官方在线构建服务（download API）"
  local os="linux"
  local url
  url="$(curl -sS -m 30 -G "https://caddyserver.com/api/download" \
        --data-urlencode "os=${os}" \
        --data-urlencode "arch=${ARCH}" \
        --data-urlencode "p=github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@${FORWARDPROXY_BRANCH}" \
        -o /dev/null -w '%{url_effective}' 2>/dev/null || true)"
  [[ -n "$url" ]] || { warn "无法生成下载链接。"; return 1; }
  local tmp; tmp="$(mktemp -d)"
  info "请求在线构建: ${url}"
  if ! fetch_file "$url" "${tmp}/caddy" >>"$LOG_FILE" 2>&1; then
    warn "在线构建服务返回失败（该服务偶发不可用）。"; rm -rf "$tmp"; return 1
  fi
  if [[ "$(head -c 4 "${tmp}/caddy" | od -An -c | tr -d ' \n')" != "177ELF" ]]; then
    local msg; msg="$(head -c 300 "${tmp}/caddy" 2>/dev/null | tr '\n' ' ')"
    warn "在线构建产物不是可执行文件，返回内容: ${msg}"
    rm -rf "$tmp"; return 1
  fi
  chmod 0755 "${tmp}/caddy"
  if ! caddy_has_forwardproxy "${tmp}/caddy"; then
    warn "在线构建产物缺少 forward_proxy 模块。"; rm -rf "$tmp"; return 1
  fi
  install -m 0755 "${tmp}/caddy" "$CADDY_BIN"
  rm -rf "$tmp"
  CADDY_INSTALL_METHOD="Caddy 官方在线构建 (download API)"
  ok "已安装: $("$CADDY_BIN" version 2>/dev/null | head -n1)"
  return 0
}

install_caddy() {
  section "步骤 4/6 · 安装 Caddy (forwardproxy-naive)"
  if [[ -x "$CADDY_BIN" && "${UPGRADE_MODE:-no}" != "yes" ]]; then
    if caddy_has_forwardproxy "$CADDY_BIN"; then
      ok "检测到已安装的 Caddy: $(caddy_bin_version)"
      if ! caddy_build_info_is_naive "$CADDY_BIN"; then
        warn "该 Caddy 可能不含 NaiveProxy 填充层（来自 caddyserver/forwardproxy 原版），"
        warn "建议使用 --force 重新安装 klzgrad/forwardproxy@naive 版本。"
      fi
      CADDY_INSTALL_METHOD="${CADDY_INSTALL_METHOD:-已存在 (跳过安装)}"
      return 0
    fi
    warn "已存在的 Caddy 缺少 forward_proxy 模块，将重新安装。"
  fi

  local method="${INSTALL_METHOD:-auto}"
  case "$method" in
    prebuilt)
      install_caddy_prebuilt || die "预编译二进制安装失败。"
      ;;
    source)
      build_caddy_from_source || die "源码编译失败。"
      ;;
    api)
      install_caddy_download_api || die "在线构建安装失败。"
      ;;
    *)
      if [[ "$ARCH" == "amd64" ]]; then
        install_caddy_prebuilt && return 0
      fi
      install_caddy_download_api && return 0
      build_caddy_from_source && return 0
      die "三种安装方式均失败。请查看日志 ${LOG_FILE}，或参考 README 手动编译。"
      ;;
  esac
}

# ------------------------------------------------------------------------------
# 用户 / 目录 准备
# ------------------------------------------------------------------------------
create_caddy_user() {
  if [[ "$RUN_AS" == "root" ]]; then
    warn "已选择以 root 运行 Caddy（安全性较低，仅建议在特殊场景使用）。"
    return 0
  fi
  if ! id -u "$CADDY_USER" >/dev/null 2>&1; then
    step "创建系统用户 ${CADDY_USER}"
    useradd --system --home-dir "$CADDY_HOME" --create-home \
            --shell /usr/sbin/nologin --comment "Caddy web server" "$CADDY_USER" \
      || die "创建用户 ${CADDY_USER} 失败。"
    ok "用户 ${CADDY_USER} 创建完成。"
  fi
  mkdir -p "$CADDY_HOME" "${CADDY_HOME}/.local/share" "${CADDY_HOME}/.config" "${CADDY_HOME}/.cache" "$CADDY_DATA"
  chown -R "${CADDY_USER}:${CADDY_USER}" "$CADDY_HOME"
  chmod 0750 "$CADDY_HOME"
}

prepare_dirs() {
  mkdir -p "$CADDY_ETC" "$STATE_DIR" "$CLIENT_DIR"
  chmod 0700 "$STATE_DIR" "$CLIENT_DIR"
  if [[ "$MASQ_MODE" == "static" ]]; then
    mkdir -p "$WEBROOT" 2>/dev/null || warn "无法创建 ${WEBROOT}，稍后将重试。"
  fi
}

# ------------------------------------------------------------------------------
# ZeroSSL EAB 凭据
# ------------------------------------------------------------------------------
zerossl_fetch_eab() { # $1=邮箱  输出: "kid hmac"
  local email="$1" resp=""
  resp="$(curl -fsS -m 30 -X POST "https://api.zerossl.com/acme/eab-credentials-email" \
          -H 'Content-Type: application/x-www-form-urlencoded' \
          --data-urlencode "email=${email}" 2>/dev/null || true)"
  [[ -n "$resp" ]] || return 1
  local kid hmac
  if have jq; then
    [[ "$(jq -r '.success // false' <<<"$resp" 2>/dev/null)" == "true" ]] || return 1
    kid="$(jq -r '.eab_kid // empty' <<<"$resp" 2>/dev/null)"
    hmac="$(jq -r '.eab_hmac_key // empty' <<<"$resp" 2>/dev/null)"
  else
    kid="$(sed -n 's/.*"eab_kid"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$resp")"
    hmac="$(sed -n 's/.*"eab_hmac_key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$resp")"
  fi
  [[ -n "$kid" && -n "$hmac" ]] || return 1
  printf '%s %s\n' "$kid" "$hmac"
  return 0
}

configure_zerossl() {
  section "配置 ZeroSSL ACME（规避 Let's Encrypt 单主域频率限制）"
  ACME_CA_URL="https://acme.zerossl.com/v2/DV90"
  if [[ -n "$EAB_KID" && -n "$EAB_HMAC" ]]; then
    ok "使用命令行提供的 EAB 凭据。"
    return 0
  fi
  step "正在使用邮箱 ${ACME_EMAIL} 自动申请 EAB 凭据（无需注册/登录 ZeroSSL）"
  local pair=""
  if pair="$(zerossl_fetch_eab "$ACME_EMAIL")"; then
    EAB_KID="${pair%% *}"
    EAB_HMAC="${pair##* }"
    ok "EAB 凭据获取成功 (kid: ${EAB_KID:0:12}…)"
    return 0
  fi
  warn "自动获取 EAB 失败（ZeroSSL 接口偶尔限流）。"
  hint "你也可以手动获取：登录 https://app.zerossl.com/developer 生成 EAB 凭据"
  info "EAB Key ID / HMAC Key 可在 https://app.zerossl.com/developer 页面找到（Developer → ACME EAB Credentials）。"
  warn "注意：这里的 EAB Credentials 是给 ACME 用的；ZeroSSL 的 API Key 是另一回事，不要混用。"
  if ! can_prompt; then
    warn "非交互模式：自动回退到 Let's Encrypt。"
    hint "如需使用 ZeroSSL，请用 --eab 'KEYID:HMACKEY' 指定凭据后重试。"
    CA_MODE="letsencrypt"; ACME_CA_URL=""; EAB_KID=""; EAB_HMAC=""
    return 0
  fi
  local kid="" mac=""
  ask kid "请输入 EAB Key ID (留空则改用 Let's Encrypt)" ""
  if [[ -z "$kid" ]]; then
    warn "已回退到 Let's Encrypt。"
    CA_MODE="letsencrypt"; ACME_CA_URL=""; EAB_KID=""; EAB_HMAC=""
    return 0
  fi
  ask mac "请输入 EAB HMAC Key" "" "" 
  [[ -n "$mac" ]] || die "EAB HMAC Key 不能为空。"
  EAB_KID="$kid"; EAB_HMAC="$mac"
  ok "已配置手动 EAB 凭据。"
}

# ------------------------------------------------------------------------------
# 交互式配置收集
# ------------------------------------------------------------------------------
collect_config() {
  section "步骤 2/6 · 收集配置"

  # ---------- 1. 域名 ----------
  if [[ -z "$DOMAIN" ]]; then
    local auto_prefix auto_domain
    auto_prefix="$(rand_string 8)"
    auto_domain="${auto_prefix}.${PUBLIC_IP}.nip.io"
    choose DOMAIN_CHOICE "请选择证书域名方案：" 1 \
      "nip.io 免费域名（推荐，无需自己解析）: ${auto_domain}" \
      "我自己的域名（需要已把 A 记录解析到 ${PUBLIC_IP}）" \
      "其它第三方动态 DNS 域名（如 duckdns / sslip.io 等）"
    DOMAIN_CHOICE_IDX="${DOMAIN_CHOICE_IDX:-1}"
    case "$DOMAIN_CHOICE_IDX" in
      1)
        DOMAIN="$auto_domain"
        DOMAIN_PREFIX="$auto_prefix"
        ;;
      2)
        local custom=""
        ask custom "请输入你的域名（例如 proxy.example.com）" "" valid_domain
        [[ -n "$custom" ]] || die "域名不能为空。"
        DOMAIN="$custom"
        ;;
      *)
        local other=""
        ask other "请输入完整域名（例如 myhost.duckdns.org）" "" valid_domain
        [[ -n "$other" ]] || die "域名不能为空。"
        DOMAIN="$other"
        ;;
    esac
  fi
  valid_domain "$DOMAIN" || die "域名格式不合法: ${DOMAIN}"

  # 解析检查
  local resolved
  resolved="$(resolve_ipv4 "$DOMAIN")"
  if [[ -z "$resolved" ]]; then
    warn "域名 ${DOMAIN} 当前无法解析，自动签发证书会失败。"
  elif [[ "$resolved" != "$PUBLIC_IP" ]]; then
    warn "域名 ${DOMAIN} 解析到 ${resolved}，与本机公网 IP ${PUBLIC_IP} 不一致。"
    hint "若使用 Cloudflare 等 CDN 代理（小黄云），HTTP-01 校验会失败，请先改为 DNS only。"
  else
    ok "域名解析检查通过: ${DOMAIN} → ${resolved}"
  fi

  # ---------- 2. 端口 ----------
  if [[ -z "${HTTPS_PORT_GIVEN:-}" ]]; then
    ask HTTPS_PORT "HTTPS 端口（代理端口，需对外开放）" "443" valid_port
  fi
  if [[ -z "${HTTP_PORT_GIVEN:-}" ]]; then
    ask HTTP_PORT "HTTP 端口（用于证书 HTTP-01 校验与跳转，需对外开放）" "80" valid_port
  fi

  # ---------- 3. 代理账号密码 ----------
  if [[ -z "$PROXY_USER" ]]; then
    local u=""
    ask u "代理用户名（回车使用随机生成，允许字母数字._-）" "" valid_username_opt
    PROXY_USER="${u:-$(gen_username)}"
  fi
  valid_username "$PROXY_USER" || die "用户名只能包含字母、数字、下划线、点、短横线（1-32 位）。"
  if [[ -z "$PROXY_PASS" ]]; then
    local p=""
    ask p "代理密码（回车使用随机生成，允许字母数字._-，8-64 位）" "" valid_password_opt
    PROXY_PASS="${p:-$(gen_password 24)}"
  fi
  valid_password "$PROXY_PASS" || die "密码只能包含字母、数字、下划线、点、短横线（8-64 位）。这样可直接放进 URL 使用，无需转义。"

  # ---------- 4. ACME 邮箱 ----------
  if [[ -z "$ACME_EMAIL" ]]; then
    local e=""
    ask e "证书通知邮箱（ACME 账户邮箱，可留空使用默认）" "admin@${DOMAIN}" ""
    ACME_EMAIL="$e"
  fi

  # ---------- 5. ACME CA ----------
  if [[ -z "${CA_GIVEN:-}" ]]; then
    choose CA_CHOICE "请选择证书颁发机构 (ACME CA)：" 2 \
      "Let's Encrypt  [会被 nip.io 共享限速影响，可能申请失败]" \
      "ZeroSSL  [推荐：自动获取 EAB，不受单主域 50 张/周 限制]" \
      "Let's Encrypt 测试环境 (staging)  [证书不被信任，仅用于调试]" \
      "自定义 ACME 目录 URL（支持自建 ACME / 其它 CA）"
    CA_CHOICE_IDX="${CA_CHOICE_IDX:-2}"
    case "$CA_CHOICE_IDX" in
      1) CA_MODE="letsencrypt" ;;
      2) CA_MODE="zerossl" ;;
      3) CA_MODE="letsencrypt-staging" ;;
      4) CA_MODE="custom" ;;
    esac
  fi

  case "$CA_MODE" in
    letsencrypt)
      ACME_CA_URL=""
      warn "Let's Encrypt 对「注册域」有 50 张/7 天 的共享限额；nip.io 不在公共后缀列表(PSL)中，"
      warn "所有使用 *.nip.io 的人共享这 50 个名额，且同名域名 5 张/7 天。失败时请改用 ZeroSSL。"
      ;;
    zerossl)
      configure_zerossl
      ;;
    letsencrypt-staging)
      ACME_CA_URL="https://acme-staging-v02.api.letsencrypt.org/directory"
      ;;
    custom)
      if [[ -z "$ACME_CA_URL" ]]; then
        ask ACME_CA_URL "请输入 ACME 目录 URL（例如 https://acme.example.com/v2/directory）" "" ""
      fi
      [[ -n "$ACME_CA_URL" ]] || die "自定义 ACME 目录 URL 不能为空。"
      ;;
    *)
      die "未知的 CA_MODE: ${CA_MODE}" ;;
  esac

  # ---------- 6. HTTP/3 ----------
  if [[ "$HTTP3" == "auto" ]]; then
    choose H3_CHOICE "是否启用 HTTP/3 (QUIC/UDP ${HTTPS_PORT})？" 1 \
      "同时开启 HTTP/2 与 HTTP/3  [推荐，客户端可自适应]" \
      "仅 HTTP/2（关闭 UDP ${HTTPS_PORT}，兼容性最好）" \
      "仅 HTTP/3（部分网络环境 UDP 被 QoS，谨慎使用）"
    H3_CHOICE_IDX="${H3_CHOICE_IDX:-1}"
    case "$H3_CHOICE_IDX" in
      1) HTTP3="on" ;;
      2) HTTP3="h2only" ;;
      3) HTTP3="h3only" ;;
    esac
  fi
  case "$HTTP3" in
    yes|true|1) HTTP3="on" ;;
    no|false|0) HTTP3="h2only" ;;
  esac

  # ---------- 7. 伪装站点 ----------
  if [[ -z "${MASQ_GIVEN:-}" ]]; then
    choose MASQ_CHOICE "未携带正确凭据的探测请求，应该看到什么内容（伪装目标）？" 1 \
      "反向代理到真实网站（默认: https://www.bing.com）  [伪装效果最好]" \
      "自定义反代目标网站（自己输入 URL）" \
      "使用本机静态页面（不依赖外部站点，最稳定）" \
      "不使用伪装：直接返回 404（不建议）"
    MASQ_CHOICE_IDX="${MASQ_CHOICE_IDX:-1}"
    case "$MASQ_CHOICE_IDX" in
      1) MASQ_MODE="reverse"; MASQ_TARGET="https://www.bing.com" ;;
      2) MASQ_MODE="reverse"; ask MASQ_TARGET "请输入要反代的网站 URL（含 https://）" "https://www.cloudflare.com" "" ;;
      3) MASQ_MODE="static" ;;
      *) MASQ_MODE="none" ;;
    esac
  fi

  export HTTPS_PORT HTTP_PORT
}

# ------------------------------------------------------------------------------
# 关键依赖检查（端口占用 / DNS 解析）
# ------------------------------------------------------------------------------
check_ports_before_install() {
  section "步骤 3/6 · 端口与网络检查"
  local p
  for p in "$HTTP_PORT" "$HTTPS_PORT"; do
    if port_listening "$p"; then
      if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        info "端口 ${p} 由正在运行的 Caddy 占用（安装完成后会重启服务复用该端口）。"
        continue
      fi
      warn "端口 ${p} 已被占用: $(port_owner "$p")"
      if can_prompt; then
        ask_yn "是否继续（会尝试停止占用进程）？" "yes" || die "端口被占用，无法继续。"
        stop_port_user "$p" || die "无法释放端口 ${p}，请手动处理后重试。"
      else
        info "非交互模式：尝试自动停止占用 ${p} 端口的进程..."
        if stop_port_user "$p"; then ok "端口 ${p} 已释放。"
        else warn "无法释放端口 ${p}，Caddy 启动时可能失败。"; fi
      fi
    fi
  done
  ok "端口检查完成（${HTTP_PORT}/tcp, ${HTTPS_PORT}/tcp, ${HTTPS_PORT}/udp）。"
}

stop_port_user() {
  local p="$1" pids
  pids="$(ss -H -lntup "sport = :$p" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u || true)"
  [[ -n "$pids" ]] || return 0
  local pid
  for pid in $pids; do
    info "停止占用端口 ${p} 的进程 PID ${pid} ($(ps -p "$pid" -o comm= 2>/dev/null || echo unknown))"
    kill "$pid" 2>/dev/null || true
  done
  sleep 1
  port_listening "$p" && return 1
  return 0
}

# ------------------------------------------------------------------------------
# 生成 Caddyfile
# ------------------------------------------------------------------------------
write_caddyfile() {
  section "步骤 5/6 · 生成配置"
  if [[ -f "$CADDYFILE" && "$FORCE" != "yes" ]]; then
    local bak
    bak="${CADDYFILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp -f "$CADDYFILE" "$bak" && info "已备份原配置到 ${bak}"
  fi

  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  local sitelist=":${HTTPS_PORT}, ${DOMAIN}"
  [[ -n "$PROBE_SECRET" ]] && sitelist="${sitelist}, ${PROBE_SECRET}"

  {
    printf '# ==============================================================================\n'
    printf '# NaiveProxy 服务端配置（Caddy + forwardproxy-naive）\n'
    printf '# 由 %s v%s 自动生成，生成时间: %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$ts"
    printf '# 项目文档: %s\n' "$REPO_URL"
    printf '# ⚠ 本文件包含代理账号密码，请勿公开分享（root:caddy 0640）\n'
    printf '# ==============================================================================\n\n'
    printf '{\n'
    printf '\t# forward_proxy 默认顺序在 file_server 之后；提前便于静态文件/反代兜底\n'
    printf '\torder forward_proxy before file_server\n\n'
    if [[ -n "$ACME_EMAIL" ]]; then
      printf '\t# ACME 账户邮箱（证书到期通知）\n'
      printf '\temail %s\n\n' "$ACME_EMAIL"
    fi
    if [[ -n "$ACME_CA_URL" ]]; then
      printf '\t# 证书颁发机构（切换 ACME CA 可规避 LE 的单主域 50 张/周 频率限制）\n'
      printf '\tacme_ca %s\n' "$ACME_CA_URL"
      if [[ -n "$EAB_KID" && -n "$EAB_HMAC" ]]; then
        printf '\t# ZeroSSL 要求的 External Account Binding (EAB) 凭据\n'
        printf '\tacme_eab {\n\t\tkey_id %s\n\t\tmac_key %s\n\t}\n' "$EAB_KID" "$EAB_HMAC"
      fi
      printf '\n'
    fi
    printf '\thttp_port %s\n\thttps_port %s\n' "$HTTP_PORT" "$HTTPS_PORT"
    if [[ "$HTTP3" == "h2only" || "$HTTP3" == "h3only" ]]; then
      printf '\n'
    fi
    if [[ "$HTTP3" == "h2only" ]]; then
      printf '\t# 关闭 HTTP/3（仅 TLS 监听端口），保留 HTTP/1.1 与 HTTP/2\n'
      printf '\tservers :%s {\n\t\tprotocols h1 h2\n\t}\n\n' "$HTTPS_PORT"
    elif [[ "$HTTP3" == "h3only" ]]; then
      printf '\t# 仅启用 HTTP/1.1 与 HTTP/3（关闭 HTTP/2）\n'
      printf '\tservers :%s {\n\t\tprotocols h1 h3\n\t}\n\n' "$HTTPS_PORT"
    fi
    printf '}\n\n'

    printf '# 提示: 地址列表中的 ":%s" 必须写在最前面，\n' "$HTTPS_PORT"
    printf '# 否则 forward_proxy 无法处理任意目标的代理请求（上游 Caddyfile 要求）\n'
    printf '%s {\n' "$sitelist"
    printf '\tencode zstd gzip\n\n'
    printf '\t# ---- 代理处理：先尝试 forward_proxy，未通过鉴权则自动落到下面的伪装内容 ----\n'
    printf '\troute {\n'
    printf '\t\tforward_proxy {\n'
    printf '\t\t\tbasic_auth %s %s\n' "$PROXY_USER" "$PROXY_PASS"
    printf '\t\t\thide_ip\n'
    printf '\t\t\thide_via\n'
    if [[ -n "$PROBE_SECRET" ]]; then
      printf '\t\t\t# 探针密道：浏览器访问 https://%s 会触发 407 以弹出账号密码框\n' "$PROBE_SECRET"
      printf '\t\t\tprobe_resistance %s\n' "$PROBE_SECRET"
    else
      printf '\t\t\t# 未鉴权的探测请求会被当作普通网站访客处理（探针伪装）\n'
      printf '\t\t\tprobe_resistance\n'
    fi
    printf '\t\t\tdial_timeout 30\n'
    printf '\t\t\tmax_idle_conns 128\n'
    printf '\t\t\tmax_idle_conns_per_host 8\n'
    if [[ "$ALLOW_PRIVATE_NETS" == "yes" ]]; then
      printf '\t\t\t# ⚠ 已允许访问内网/回环地址（改动过默认安全策略）\n'
      printf '\t\t\tacl {\n\t\t\t\tallow all\n\t\t\t}\n'
    else
      printf '\t\t\t# 禁止代理访问本机/内网地址（默认安全策略，防止被用作内网跳板）\n'
      printf '\t\t\tacl {\n'
      printf '\t\t\t\tdeny 10.0.0.0/8 127.0.0.0/8 172.16.0.0/12 192.168.0.0/16 ::1/128 fe80::/10\n'
      printf '\t\t\t\tallow all\n'
      printf '\t\t\t}\n'
    fi
    printf '\t\t}\n\n'

    # ---- 伪装内容 ----
    case "$MASQ_MODE" in
      reverse)
        printf '\t\t# ---- 伪装内容 1/2：反向代理到一个真实网站 ----\n'
        printf '\t\treverse_proxy %s {\n' "$MASQ_TARGET"
        printf '\t\t\t# 使用上游主机名作为 Host，避免上游站点因 Host 不匹配而拒绝\n'
        printf '\t\t\theader_up Host {upstream_hostport}\n'
        printf '\t\t}\n'
        ;;
      static)
        printf '\t\t# ---- 伪装内容：本机静态页面 ----\n'
        printf '\t\troot * %s\n' "$WEBROOT"
        printf '\t\tfile_server\n'
        ;;
      *)
        printf '\t\t# ---- 不做伪装（直接 404）----\n'
        printf '\t\trespond 404\n'
        ;;
    esac
    printf '\t}\n'
    printf '}\n'
  } >"$CADDYFILE"

  # caddy 用户需要读取配置文件；其中包含代理密码，因此不给其它用户读权限
  chmod 0640 "$CADDYFILE"
  if [[ "$RUN_AS" == "caddy" ]]; then
    chown "root:${CADDY_USER}" "$CADDYFILE" || true
    chmod 0755 "$CADDY_ETC"
  else
    chmod 0600 "$CADDYFILE"
  fi
  ok "已写入 ${CADDYFILE}"
}

write_static_page() {
  [[ "$MASQ_MODE" == "static" ]] || return 0
  mkdir -p "$WEBROOT"
  cat >"${WEBROOT}/index.html" <<'HTML_EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Welcome</title>
<style>
  body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;
       display:flex;align-items:center;justify-content:center;min-height:100vh;background:#f7f7f8;color:#333}
  main{max-width:36rem;padding:2rem;text-align:center}
  h1{font-size:1.6rem;font-weight:600;margin:0 0 .8rem}
  p{line-height:1.7;color:#666}
</style>
</head>
<body>
<main>
  <h1>It works!</h1>
  <p>This is a default page of a web server. The site is under construction.</p>
</main>
</body>
</html>
HTML_EOF
  chmod 0644 "${WEBROOT}/index.html"
  chown -R "${CADDY_USER}:${CADDY_USER}" "$WEBROOT" 2>/dev/null || true
  ok "已生成静态伪装页面 ${WEBROOT}/index.html"
}

# ------------------------------------------------------------------------------
# systemd 服务
# ------------------------------------------------------------------------------
write_systemd_unit() {
  local user_line="User=${CADDY_USER}" group_line="Group=${CADDY_USER}"
  local cap_lines=$'\nAmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE'
  local home_lines=$'\nEnvironment=HOME='"$CADDY_HOME"$'\nEnvironment=XDG_DATA_HOME='"$CADDY_HOME"$'/.local/share\nEnvironment=XDG_CONFIG_HOME='"$CADDY_HOME"'/.config'
  if [[ "$RUN_AS" == "root" ]]; then
    user_line="User=root"; group_line="Group=root"; cap_lines=""; home_lines=""
  fi

  cat >"$SERVICE_FILE" <<SYSTEMD_EOF
# NaiveProxy / Caddy 服务单元（由 ${SCRIPT_NAME} v${SCRIPT_VERSION} 生成）
[Unit]
Description=Caddy web server (NaiveProxy / forwardproxy-naive)
Documentation=${REPO_URL}
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
${user_line}
${group_line}${home_lines}
ExecStart=${CADDY_BIN} run --environ --config ${CADDYFILE} --adapter caddyfile
ExecReload=${CADDY_BIN} reload --config ${CADDYFILE} --adapter caddyfile --force
Restart=on-failure
RestartSec=3
TimeoutStopSec=10s
LimitNOFILE=1048576${cap_lines}
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${CADDY_HOME}

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

  chmod 0644 "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || warn "设置开机自启失败，请手动执行: systemctl enable ${SERVICE_NAME}"
  ok "已生成 systemd 服务 (${SERVICE_FILE}) 并设置开机自启。"
}

# ------------------------------------------------------------------------------
# 防火墙 / BBR
# ------------------------------------------------------------------------------
configure_firewall() {
  local do_it="$ENABLE_FIREWALL"
  if [[ "$do_it" == "auto" ]]; then
    if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
      do_it="yes"
    elif systemctl is-active --quiet firewalld 2>/dev/null; then
      do_it="yes"
    else
      do_it="no"
    fi
  fi
  if [[ "$do_it" != "yes" ]]; then
    info "未检测到启用中的 ufw/firewalld，跳过防火墙配置。"
    info "请确认云厂商安全组已放行: ${HTTP_PORT}/tcp, ${HTTPS_PORT}/tcp, ${HTTPS_PORT}/udp"
    return 0
  fi
  step "配置防火墙放行端口"
  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${HTTP_PORT}/tcp" >/dev/null 2>&1 || true
    ufw allow "${HTTPS_PORT}/tcp" >/dev/null 2>&1 || true
    ufw allow "${HTTPS_PORT}/udp" >/dev/null 2>&1 || true
    ok "ufw 已放行 ${HTTP_PORT}/tcp ${HTTPS_PORT}/tcp ${HTTPS_PORT}/udp"
  elif systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${HTTP_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${HTTPS_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${HTTPS_PORT}/udp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    ok "firewalld 已放行 ${HTTP_PORT}/tcp ${HTTPS_PORT}/tcp ${HTTPS_PORT}/udp"
  fi
}

enable_bbr() {
  local do_it="$ENABLE_BBR"
  if [[ "$do_it" == "auto" ]]; then
    local cur; cur="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    if [[ "$cur" == "bbr" ]]; then
      info "系统已启用 BBR。"
      return 0
    fi
    if ! can_prompt; then do_it="no"; else
      if ask_yn "是否启用 BBR 拥塞控制算法（可显著提升跨境传输速度，需要修改内核参数）？" "yes"; then do_it="yes"; else do_it="no"; fi
    fi
  fi
  [[ "$do_it" == "yes" ]] || return 0

  if ! modprobe tcp_bbr 2>/dev/null && ! grep -q tcp_bbr /proc/modules 2>/dev/null; then
    warn "当前内核不支持 BBR（可能需要升级内核），已跳过。"
    return 0
  fi
  {
    printf '# NaiveProxy 安装脚本添加：BBR 拥塞控制\n'
    printf 'net.core.default_qdisc=fq\n'
    printf 'net.ipv4.tcp_congestion_control=bbr\n'
    printf 'net.core.somaxconn=8192\n'
  } >"$SYSCTL_FILE"
  sysctl --system >/dev/null 2>&1 || warn "应用 sysctl 失败，请手动执行 sysctl --system"
  local now; now="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  if [[ "$now" == "bbr" ]]; then
    ok "BBR 已启用（当前拥塞控制: ${now}）。"
  else
    warn "BBR 启用未生效（当前: ${now}），可能是内核不支持。"
  fi
}

# ------------------------------------------------------------------------------
# 服务启动与证书等待
# ------------------------------------------------------------------------------
start_caddy() {
  step "启动 Caddy 服务"
  systemctl restart "$SERVICE_NAME" || true
  sleep 2
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "Caddy 服务已启动。"
    return 0
  fi
  err "Caddy 服务启动失败，最近日志如下："
  journalctl -u "$SERVICE_NAME" -n 40 --no-pager 2>/dev/null | sed 's/^/    /' >&2 || true
  die "请根据以上日志排查（常见原因：配置文件语法错误、端口被占用、证书申请失败）。"
}

wait_for_https() {
  local domain="$1" port="$2" timeout="${3:-240}" waited=0
  step "等待 Caddy 监听 ${port} 端口"
  while (( waited < 30 )); do
    port_listening "$port" && { ok "端口 ${port} 已监听。"; break; }
    sleep 1; waited=$((waited+1))
  done
  port_listening "$port" || warn "端口 ${port} 未监听，服务可能未正常启动。"

  step "等待自动 HTTPS 证书签发（最长 ${timeout} 秒）"
  local start; start="$(date +%s)"
  local issuer="" subject=""
  while :; do
    issuer="$(timeout 8 openssl s_client -connect "127.0.0.1:${port}" -servername "$domain" </dev/null 2>/dev/null \
              | openssl x509 -noout -issuer 2>/dev/null || true)"
    if [[ -n "$issuer" ]]; then
      if [[ "$issuer" == *"Caddy Local Authority"* ]]; then
        : # Caddy 内部自签证书：说明 ACME 尚未完成
      else
        subject="$(timeout 8 openssl s_client -connect "127.0.0.1:${port}" -servername "$domain" </dev/null 2>/dev/null \
                   | openssl x509 -noout -subject -dates 2>/dev/null | tr '\n' ' ' || true)"
        ok "证书已签发完成。"
        info "证书信息: ${subject}"
        info "签发机构: ${issuer#issuer=}"
        return 0
      fi
    fi
    if (( $(date +%s) - start >= timeout )); then
      warn "等待证书超时（${timeout}s）。"
      return 1
    fi
    sleep 3
    printf '.'
  done
}

verify_proxy_works() {
  local domain="$1" port="$2" user="$3" pass="$4"
  step "端到端测试：通过代理访问互联网"
  local code=""
  code="$(curl -sS -o /dev/null -m 25 -w '%{http_code}' \
          --resolve "${domain}:${port}:127.0.0.1" \
          --proxy "https://${user}:${pass}@${domain}:${port}" \
          "https://www.example.com/" 2>/dev/null || true)"
  if [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]; then
    ok "代理工作正常（目标站点返回 HTTP ${code}）。"
    return 0
  fi
  # 再试一次：跳过代理证书校验（用于 staging 证书等场景，判断是"代理不通"还是"证书不受信"）
  local code2=""
  code2="$(curl -sS -o /dev/null -m 25 -w '%{http_code}' --proxy-insecure \
           --resolve "${domain}:${port}:127.0.0.1" \
           --proxy "https://${user}:${pass}@${domain}:${port}" \
           "https://www.example.com/" 2>/dev/null || true)"
  if [[ "$code2" == "200" || "$code2" == "301" || "$code2" == "302" ]]; then
    warn "代理隧道可用，但代理证书校验失败（HTTP ${code2}）——通常是使用了测试(staging)证书或自签证书。"
    return 0
  fi
  warn "代理自检失败（HTTP ${code:-无响应}）。可能原因："
  hint "1) 本机无法直连外网（example.com 不可达）"
  hint "2) 转发到上游被防火墙拦截"
  hint "3) curl 版本较旧不支持 HTTPS 代理（可换 curl --proxy-insecure 试试）"
  return 1
}

verify_masquerade() {
  local domain="$1" port="$2"
  step "检查伪装站点响应"
  local code
  code="$(curl -s -o /dev/null -m 20 -w '%{http_code}' -k \
          --resolve "${domain}:${port}:127.0.0.1" "https://${domain}/" 2>/dev/null || true)"
  if [[ "$code" =~ ^(200|301|302|403|404)$ ]]; then
    ok "伪装响应正常（HTTP ${code}）。"
  else
    warn "伪装站点响应异常（HTTP ${code:-无响应}）。"
  fi
}

# ------------------------------------------------------------------------------
# 安装状态持久化
# ------------------------------------------------------------------------------
write_state_file() {
  local vars=(DOMAIN PUBLIC_IP DOMAIN_PREFIX PROXY_USER PROXY_PASS HTTPS_PORT HTTP_PORT
              ACME_EMAIL CA_MODE ACME_CA_URL EAB_KID EAB_HMAC HTTP3 MASQ_MODE MASQ_TARGET
              RUN_AS PROBE_SECRET CADDY_INSTALL_METHOD CADDY_VERSION STATE_SCRIPT_VERSION INSTALL_DATE)
  # shellcheck disable=SC2034  # 下面两个变量通过 ${!v} 间接读取并写入状态文件
  STATE_SCRIPT_VERSION="$SCRIPT_VERSION"
  # shellcheck disable=SC2034
  INSTALL_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
  : >"$STATE_FILE"
  {
    printf '# NaiveProxy 安装信息（由脚本自动生成，包含敏感信息，权限 0600）\n'
    printf '# 文档: %s\n' "$REPO_URL"
    local v
    for v in "${vars[@]}"; do
      printf '%s=%q\n' "$v" "${!v:-}"
    done
  } >>"$STATE_FILE"
  chmod 0600 "$STATE_FILE"
  ok "安装信息已保存到 ${STATE_FILE}"
}

load_state_file() {
  [[ -f "$STATE_FILE" ]] || return 1
  local had_errexit="no"
  case "$-" in *e*) had_errexit="yes" ;; esac
  set +e
  # shellcheck disable=SC1090
  . "$STATE_FILE" 2>/dev/null || warn "读取安装信息时出现异常，部分信息可能缺失: ${STATE_FILE}"
  # 个别字段可能被只读变量占用，忽略这类冲突
  [[ "${DOMAIN:-}" == "" ]] && warn "安装信息中缺少域名字段，请检查 ${STATE_FILE}"
  [[ "$had_errexit" == "yes" ]] && set -e
  return 0
}

require_installed() {
  load_state_file || die "未检测到 NaiveProxy 安装记录（${STATE_FILE} 不存在）。请先执行安装。"
}

# ------------------------------------------------------------------------------
# 生成客户端配置
# ------------------------------------------------------------------------------
build_proxy_uri() { # $1=https|quic
  local scheme="$1"
  printf '%s://%s:%s@%s:%s' "$scheme" "$PROXY_USER" "$PROXY_PASS" "$DOMAIN" "$HTTPS_PORT"
}

build_share_link() { # $1=https|quic
  local scheme="$1" tag="NaiveProxy-${DOMAIN_PREFIX:-$DOMAIN}"
  [[ "$scheme" == "quic" ]] && tag="NaiveProxy-QUIC-${DOMAIN_PREFIX:-$DOMAIN}"
  printf 'naive+%s://%s:%s@%s:%s#%s' "$scheme" "$PROXY_USER" "$PROXY_PASS" "$DOMAIN" "$HTTPS_PORT" "$tag"
}

render_template() { # $1=模板 其余为 KEY=VALUE 替换对
  local out="$1"; shift
  local pair k v
  for pair in "$@"; do
    k="${pair%%=*}"
    v="${pair#*=}"
    out="${out//__${k}__/$v}"
  done
  printf '%s' "$out"
}

generate_client_files() {
  section "生成客户端配置与节点信息"
  mkdir -p "$CLIENT_DIR"; chmod 0700 "$CLIENT_DIR"

  local uri_https uri_quic
  uri_https="$(build_proxy_uri https)"
  uri_quic="$(build_proxy_uri quic)"
  local link_https link_quic
  link_https="$(build_share_link https)"
  link_quic="$(build_share_link quic)"

  # ---- 1) 官方 naive 客户端 config.json ----
  local tpl_naive
  tpl_naive="$(cat <<'TPL'
{
  "listen": "socks://127.0.0.1:1080",
  "proxy": "__URI__"
}
TPL
)"
  { render_template "$tpl_naive" "URI=${uri_https}"; printf '\n'; } >"${CLIENT_DIR}/naive-config.json"
  { render_template "$tpl_naive" "URI=${uri_quic}";  printf '\n'; } >"${CLIENT_DIR}/naive-config-quic.json"

  # ---- 2) 命令行方式 ----
  cat >"${CLIENT_DIR}/naive-command.txt" <<TPL
# NaiveProxy 官方客户端命令行用法（各平台通用）
# 1) 下载客户端: https://github.com/klzgrad/naiveproxy/releases/latest
# 2) 把 naive.exe / naive 与 config.json 放在同一目录，双击运行或执行:

# 【推荐】使用 config.json（HTTP/2）:
naive "${CLIENT_DIR}/naive-config.json"

# 直接指定参数（HTTP/2，端口 1080 提供 SOCKS5 + HTTP 代理）:
naive --listen=socks://127.0.0.1:1080 --proxy=${uri_https}

# 使用 HTTP/3 (QUIC，UDP):
naive --listen=socks://127.0.0.1:1080 --proxy=${uri_quic}

# 局域网共享（手机等设备通过这台电脑上网）:
naive --listen=socks://0.0.0.0:1080 --proxy=${uri_https}
naive --listen=http://0.0.0.0:1081  --proxy=${uri_https}
TPL

  # ---- 3) sing-box 出站配置 ----
  local tpl_singbox
  tpl_singbox="$(cat <<'TPL'
{
  "type": "naive",
  "tag": "naive-out",
  "server": "__DOMAIN__",
  "server_port": __PORT__,
  "username": "__USER__",
  "password": "__PASS__",
  "quic": __QUIC__,
  "tls": {
    "enabled": true,
    "server_name": "__DOMAIN__"
  }
}
TPL
)"
  local singbox_common=("DOMAIN=${DOMAIN}" "PORT=${HTTPS_PORT}" "USER=${PROXY_USER}" "PASS=${PROXY_PASS}")
  { render_template "$tpl_singbox" "${singbox_common[@]}" "QUIC=false"; printf '\n'; } >"${CLIENT_DIR}/sing-box-outbound-h2.json"
  { render_template "$tpl_singbox" "${singbox_common[@]}" "QUIC=true";  printf '\n'; } >"${CLIENT_DIR}/sing-box-outbound-h3.json"

  # ---- 4) 分享链接（NekoBox / Husi / Exclave / v2rayN / sing-box 导入）----
  {
    printf '%s\n' "$link_https"
    printf '%s\n' "$link_quic"
  } >"${CLIENT_DIR}/share-links.txt"
  # 某些客户端（NekoBox / sing-box / v2rayN）支持 Base64 编码的订阅内容
  printf '%s\n' "$link_https" >"${CLIENT_DIR}/subscribe-plain.txt"
  { printf '%s' "$link_https" | base64 | tr -d '\n'; printf '\n'; } >"${CLIENT_DIR}/subscribe-base64.txt"
  printf '%s\n' "$link_quic" >"${CLIENT_DIR}/subscribe-plain-quic.txt"
  { printf '%s' "$link_quic" | base64 | tr -d '\n'; printf '\n'; } >"${CLIENT_DIR}/subscribe-base64-quic.txt"

  # ---- 5) 节点信息总览 ----
  write_node_info_file "${CLIENT_DIR}/node-info.txt" "$uri_https" "$uri_quic" "$link_https" "$link_quic"

  # ---- 6) 二维码（可选）----
  if have qrencode; then
    qrencode -o "${CLIENT_DIR}/qr-h2.png" -s 6 -m 2 "$link_https" 2>/dev/null || true
    qrencode -o "${CLIENT_DIR}/qr-h3.png" -s 6 -m 2 "$link_quic" 2>/dev/null || true
  fi

  chmod 0600 "${CLIENT_DIR}"/*
  ok "客户端配置文件已写入 ${CLIENT_DIR}/"
}

write_node_info_file() { # $1=输出文件 $2=uri_https $3=uri_quic $4=link_https $5=link_quic
  local out="$1" uri_https="$2" uri_quic="$3" link_https="$4" link_quic="$5"
  local proto_desc masq_desc
  case "$HTTP3" in
    h2only) proto_desc="HTTP/2 (H2) TCP" ;;
    h3only) proto_desc="HTTP/3 (QUIC) UDP" ;;
    *)      proto_desc="HTTP/2 (TCP) + HTTP/3 (UDP)" ;;
  esac
  case "$MASQ_MODE" in
    reverse) masq_desc="反向代理 → ${MASQ_TARGET}" ;;
    static)  masq_desc="本机静态页面 ${WEBROOT}" ;;
    *)       masq_desc="无（返回 404）" ;;
  esac
  cat >"$out" <<INFO
================================================================================
 NaiveProxy 节点信息   (生成时间: $(date '+%Y-%m-%d %H:%M:%S'))
================================================================================
 服务器地址   : ${DOMAIN}
 服务器端口   : ${HTTPS_PORT}
 代理用户名   : ${PROXY_USER}
 代理密码     : ${PROXY_PASS}
 SNI/域名     : ${DOMAIN}
 协议         : NaiveProxy (${proto_desc})
 伪装站点     : ${masq_desc}
 证书 CA      : ${CA_MODE}${ACME_CA_URL:+ (${ACME_CA_URL})}
--------------------------------------------------------------------------------
 【1】官方 naive 客户端 —— config.json
 {"listen":"socks://127.0.0.1:1080","proxy":"${uri_https}"}
 HTTP/3 版:  {"listen":"socks://127.0.0.1:1080","proxy":"${uri_quic}"}

 【2】命令行（Windows/Linux/macOS 通用）
 naive --listen=socks://127.0.0.1:1080 --proxy=${uri_https}
 naive --listen=socks://127.0.0.1:1080 --proxy=${uri_quic}     # HTTP/3

 【3】分享链接（可导入 NekoBox / Husi / Exclave / v2rayN / sing-box）
 ${link_https}
 ${link_quic}

 【4】sing-box 出站（见 sing-box-outbound-h2.json / sing-box-outbound-h3.json）

 【5】服务端管理
 systemctl status caddy          # 查看状态
 systemctl restart caddy         # 重启
 journalctl -u caddy -f          # 实时日志
 bash ${SCRIPT_NAME} info        # 重新打印本机节点信息

 配置文件: ${CADDYFILE}
 客户端配置目录: ${CLIENT_DIR}
================================================================================
INFO
}

# ------------------------------------------------------------------------------
# 结果汇总输出
# ------------------------------------------------------------------------------
print_summary() {
  if [[ "$QUIET" == "yes" ]]; then
    printf '%s|%s|%s|%s\n' "$DOMAIN" "$HTTPS_PORT" "$PROXY_USER" "$PROXY_PASS"
    return 0
  fi
  section "安装完成 · 节点信息（可直接复制使用）"
  printf '%s\n' "${C_BOLD}【服务器信息】${C_RESET}"
  printf '  地址(SNI/域名) : %s\n' "${C_BOLD}${C_GREEN}${DOMAIN}${C_RESET}"
  printf '  端口           : %s\n' "${C_BOLD}${C_GREEN}${HTTPS_PORT}${C_RESET}"
  printf '  用户名         : %s\n' "${C_BOLD}${C_GREEN}${PROXY_USER}${C_RESET}"
  printf '  密码           : %s\n' "${C_BOLD}${C_GREEN}${PROXY_PASS}${C_RESET}"
  local masq_text
  if [[ "$MASQ_MODE" == "reverse" ]]; then masq_text="反向代理 → ${MASQ_TARGET}"
  elif [[ "$MASQ_MODE" == "static" ]]; then masq_text="本机静态页面 ${WEBROOT}"
  else masq_text="无（返回 404）"; fi
  printf '  伪装站点       : %s\n' "$masq_text"
  printf '  协议支持       : %s\n' "$(case "$HTTP3" in h2only) echo "HTTP/2 (H2)" ;; h3only) echo "HTTP/3 (QUIC)";; *) echo "HTTP/2 + HTTP/3" ;; esac)"
  printf '  证书 CA        : %s\n' "${CA_MODE}${ACME_CA_URL:+ (${ACME_CA_URL})}"
  printf '  安装方式       : %s\n' "${CADDY_INSTALL_METHOD:-未知}"
  blank
  printf '%s\n' "${C_BOLD}【1】官方 naive 客户端 config.json（保存为 config.json 后与 naive 放在同目录）${C_RESET}"
  printf '%s\n' "{\"listen\":\"socks://127.0.0.1:1080\",\"proxy\":\"$(build_proxy_uri https)\"}"
  blank
  printf '%s\n' "${C_BOLD}【2】命令行启动${C_RESET}"
  printf '  %s\n' "naive --listen=socks://127.0.0.1:1080 --proxy=$(build_proxy_uri https)"
  printf '  %s\n' "naive --listen=socks://127.0.0.1:1080 --proxy=$(build_proxy_uri quic)   # HTTP/3"
  blank
  printf '%s\n' "${C_BOLD}【3】分享链接（NekoBox / Husi / Exclave / v2rayN / sing-box 可直接导入）${C_RESET}"
  printf '  %s\n' "$(build_share_link https)"
  printf '  %s\n' "$(build_share_link quic)"
  blank
  printf '%s\n' "${C_BOLD}【4】sing-box 出站配置（复制到 outbounds 数组）${C_RESET}"
  sed 's/^/  /' "${CLIENT_DIR}/sing-box-outbound-h2.json"
  blank
  printf '%s\n' "${C_BOLD}【5】服务与文件${C_RESET}"
  printf '  配置目录       : %s\n' "$CLIENT_DIR"
  printf '  服务端配置     : %s\n' "$CADDYFILE"
  printf '  服务管理       : systemctl {status|restart|stop|start} caddy\n'
  printf '  查看日志       : journalctl -u caddy -f\n'
  printf '  再次查看节点   : bash %s info   （或 bash %s menu）\n' "$SCRIPT_NAME" "$SCRIPT_NAME"
  blank
  printf '%s\n' "${C_YELLOW}【重要提醒】${C_RESET}"
  printf '  1. 云服务器请务必在"安全组/防火墙"中放行 TCP %s、TCP %s%s\n' "$HTTP_PORT" "$HTTPS_PORT" "$( [[ "$HTTP3" != "h2only" ]] && echo "、UDP ${HTTPS_PORT}" )"
  printf '  2. 域名 %s 必须解析到 %s，否则证书无法自动签发\n' "$DOMAIN" "$PUBLIC_IP"
  printf '  3. 客户端请使用官方 naive 客户端（Chromium 网络栈），伪装效果最佳\n'
  printf '  4. 本机节点信息含密码，已保存至 %s（权限 600）\n' "$CLIENT_DIR/node-info.txt"
  blank
}

# ------------------------------------------------------------------------------
# 子命令实现
# ------------------------------------------------------------------------------
cmd_install() {
  section "NaiveProxy 一键安装脚本 v${SCRIPT_VERSION}"
  printf '  %s\n' "项目: ${REPO_URL}"
  printf '  %s\n\n' "组件: Caddy + forwardproxy-naive（NaiveProxy 服务端）"

  require_root
  detect_os
  detect_arch
  check_systemd
  install_packages

  section "步骤 1/6 · 检测网络环境"
  info "系统: ${OS_ID} ${OS_VERSION} (${OS_CODENAME}) / ${ARCH}"
  local ip="" rc=0
  ip="$(get_public_ipv4)" || rc=$?
  if [[ "$rc" == "0" && -n "$ip" ]]; then
    if [[ -z "$PUBLIC_IP" ]]; then
      PUBLIC_IP="$ip"
      info "自动探测到公网 IPv4: ${ip}"
    elif [[ "$PUBLIC_IP" != "$ip" ]]; then
      warn "你指定的 IP (${PUBLIC_IP}) 与探测结果 (${ip}) 不一致，将按你指定的值继续。"
    fi
  else
    # 探测失败或只拿到内网/链路本地地址
    if [[ -n "${ip:-}" ]]; then
      warn "未能确认公网 IP：探测到的 ${ip} 看起来是内网/链路本地地址。"
    else
      warn "无法自动获取公网 IPv4（可能是网络受限或 API 不可达）。"
    fi
    if [[ -z "$PUBLIC_IP" ]]; then
      if can_prompt; then
        ask PUBLIC_IP "请手动输入本机公网 IPv4 地址" "${ip:-}" valid_ipv4
      fi
    fi
    is_public_ipv4 "${PUBLIC_IP:-}" \
      || die "缺少有效的公网 IPv4，无法生成 nip.io 域名。请用 --ip <你的公网IP> 或 --domain <你的域名> 指定。"
  fi
  ok "公网 IPv4: ${PUBLIC_IP}"

  collect_config
  check_ports_before_install

  install_caddy
  create_caddy_user
  prepare_dirs

  write_caddyfile
  write_static_page
  write_systemd_unit
  write_state_file

  section "步骤 6/6 · 启动服务与验证"
  local validate_out
  if ! validate_out="$(env HOME="${CADDY_HOME}" XDG_DATA_HOME="${CADDY_HOME}/.local/share" \
        XDG_CONFIG_HOME="${CADDY_HOME}/.config" \
        "$CADDY_BIN" validate --config "$CADDYFILE" --adapter caddyfile 2>&1)"; then
    err "Caddyfile 校验失败："
    printf '%s\n' "$validate_out" | sed 's/^/    /' >&2
    die "配置有误，已停止启动（原配置备份在 ${CADDYFILE}.bak.*）。"
  fi
  ok "Caddyfile 语法校验通过。"

  start_caddy
  if wait_for_https "$DOMAIN" "$HTTPS_PORT" 240; then
    verify_masquerade "$DOMAIN" "$HTTPS_PORT"
    verify_proxy_works "$DOMAIN" "$HTTPS_PORT" "$PROXY_USER" "$PROXY_PASS" || true
  else
    warn "证书可能仍在申请中，请稍后用以下命令查看进度："
    hint "journalctl -u caddy -f | grep -i -E 'certificate|acme|tls'"
    if [[ "$CA_MODE" == "letsencrypt" ]]; then
      warn "若出现 rate limit 报错，请改用 ZeroSSL 重新安装："
      hint "bash ${SCRIPT_NAME} install --ca zerossl --yes"
    fi
  fi

  configure_firewall
  enable_bbr
  generate_client_files

  print_summary
  ok "全部完成！日志文件: ${LOG_FILE}"
}

cmd_status() {
  require_root
  require_installed
  section "NaiveProxy 运行状态"
  systemctl --no-pager status "$SERVICE_NAME" --lines=0 2>/dev/null || warn "服务未安装或未启动。"
  blank
  printf '%-28s %s\n' "域名:" "$DOMAIN"
  printf '%-28s %s\n' "监听端口:" "$(port_listening "$HTTPS_PORT" && echo "${HTTPS_PORT} 已监听" || echo "${HTTPS_PORT} 未监听")"
  printf '%-28s %s\n' "Caddy 版本:" "$(caddy_bin_version || echo '未安装')"
  printf '%-28s %s\n' "开机自启:" "$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo 未知)"
  local issuer
  issuer="$(timeout 8 openssl s_client -connect "127.0.0.1:${HTTPS_PORT}" -servername "$DOMAIN" </dev/null 2>/dev/null \
            | openssl x509 -noout -issuer -enddate 2>/dev/null | tr '\n' ' ' || true)"
  printf '%-28s %s\n' "当前证书:" "${issuer:-未签发}"
  printf '%-28s %s\n' "配置目录:" "$CLIENT_DIR"
  printf '%-28s %s\n' "状态文件:" "$STATE_FILE"
}

cmd_info() {
  require_installed
  if [[ ! -d "$CLIENT_DIR" || ! -f "${CLIENT_DIR}/sing-box-outbound-h2.json" ]]; then
    generate_client_files
  fi
  print_summary
}

cmd_start()   { require_root; require_installed; systemctl start "$SERVICE_NAME"; ok "已启动。"; cmd_status; }
cmd_stop()    { require_root; require_installed; systemctl stop "$SERVICE_NAME"; ok "已停止。"; }
cmd_restart() {
  require_root; require_installed
  systemctl restart "$SERVICE_NAME"
  ok "已重启。"
  wait_for_https "$DOMAIN" "$HTTPS_PORT" 120 || true
}
cmd_log() {
  require_root
  if [[ "${1:-}" == "-f" || "${1:-}" == "--follow" ]]; then
    info "实时日志（Ctrl+C 退出）..."
    journalctl -u "$SERVICE_NAME" -f
  else
    journalctl -u "$SERVICE_NAME" -n "${1:-120}" --no-pager
  fi
}

cmd_update() {
  require_root
  info "更新 Caddy（保留现有配置与证书）"
  local old; old="$(caddy_bin_version || echo none)"
  CADDY_INSTALL_METHOD=""
  UPGRADE_MODE="yes"
  install_caddy || die "更新失败（可尝试 --install-method source）"
  local new; new="$(caddy_bin_version || echo unknown)"
  if [[ "$new" == "$old" ]]; then
    info "版本未变化: ${new}"
  else
    ok "已更新: ${old} → ${new}"
  fi
  systemctl restart "$SERVICE_NAME"
  sleep 2
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "服务运行正常。"
  else
    err "服务启动失败，请查看日志。"
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
  fi
}

cmd_renew() {
  require_root
  require_installed
  section "强制重新申请证书"
  warn "重新申请会占用 CA 的签发配额（Let's Encrypt: 同名域名 5 张/7 天）。"
  if ! confirm_danger "确定要删除现有证书并重新申请吗？"; then
    info "已取消。"
    return 0
  fi
  local certdir
  certdir="$(find "${CADDY_HOME}/.local/share/caddy/certificates" -maxdepth 2 -type d -name "$DOMAIN" 2>/dev/null | head -n1)"
  if [[ -n "$certdir" ]]; then
    mv -f "$certdir" "${certdir}.old.$(date +%s)" 2>/dev/null || rm -rf "$certdir"
    ok "已移除旧证书: ${certdir}"
  else
    info "未找到已缓存的证书目录，将由 Caddy 直接申请。"
  fi
  systemctl restart "$SERVICE_NAME"
  wait_for_https "$DOMAIN" "$HTTPS_PORT" 240 || warn "证书申请未在超时时间内完成，请查看日志。"
}

cmd_uninstall() {
  require_root
  section "卸载 NaiveProxy / Caddy"
  local remove_all="no"
  if confirm_danger "将停止服务并删除配置、证书与客户端信息，确定卸载？"; then remove_all="yes"; else
    ask_yn "仅停止并禁用服务（保留配置文件）？" "yes" || { info "已取消。"; return 0; }
  fi

  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true

  if [[ "$remove_all" == "yes" ]]; then
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
    local had_sysctl="no"
    [[ -f "$SYSCTL_FILE" ]] && had_sysctl="yes"
    rm -rf "$CADDY_ETC" "$CADDY_HOME" "$WEBROOT"
    rm -f "$SYSCTL_FILE"
    warn "已删除: ${CADDY_ETC} ${CADDY_HOME} ${WEBROOT}"
    if [[ "$had_sysctl" == "yes" ]]; then
      info "已删除内核参数文件 ${SYSCTL_FILE}（执行 sysctl --system 后 BBR 设置即失效）。"
    fi
    if [[ "$ASSUME_YES" != "yes" ]] && ask_yn "同时删除 Caddy 可执行文件 ${CADDY_BIN}？" "yes"; then
      rm -f "$CADDY_BIN"
      ok "已删除 ${CADDY_BIN}"
    fi
    if id -u "$CADDY_USER" >/dev/null 2>&1; then
      if [[ "$ASSUME_YES" != "yes" ]] && ask_yn "删除系统用户 ${CADDY_USER}？" "yes"; then
        userdel "$CADDY_USER" 2>/dev/null || true
      fi
    fi
    ok "卸载完成。"
  else
    ok "服务已停止并取消开机自启，配置文件保留在 ${CADDY_ETC}。"
    hint "重新启用: systemctl enable --now caddy"
  fi
}

cmd_menu() {
  require_root
  while :; do
    printf '\n%s\n' "${C_BOLD}${C_CYAN}════════ NaiveProxy 管理面板 v${SCRIPT_VERSION} ════════${C_RESET}"
    if load_state_file >/dev/null 2>&1; then
      printf '  当前节点: %s:%s  （用户名 %s）\n' "${DOMAIN:-?}" "${HTTPS_PORT:-?}" "${PROXY_USER:-?}"
      printf '  伪装目标: %s\n' "${MASQ_TARGET:-${MASQ_MODE:-?}}"
      printf '  服务状态: %s\n' "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo 未运行)"
    else
      printf '  %s\n' "未检测到安装记录（尚未安装）"
    fi
    printf '%s\n' "${C_BOLD}────────────────────────────────────────────────${C_RESET}"
    cat <<'MENU'
  1) 安装 / 重新安装 NaiveProxy        7) 查看实时日志
  2) 查看服务状态                      8) 更新 Caddy 程序
  3) 显示节点信息 / 客户端配置         9) 强制重新申请证书
  4) 重启服务                         10) 卸载
  5) 停止服务                         11) 查看当前 Caddyfile
  6) 启动服务                          0) 退出
MENU
    _prompt_out "${C_CYAN}→ 请输入选项: ${C_RESET}"
    local choice=""
    _tty_read choice || choice=""
    case "${choice:-}" in
      1) cmd_install ;;
      2) cmd_status ;;
      3) cmd_info ;;
      4) cmd_restart ;;
      5) cmd_stop ;;
      6) cmd_start ;;
      7) cmd_log -f ;;
      8) cmd_update ;;
      9) cmd_renew ;;
      10) cmd_uninstall ;;
      11)
        if [[ -f "$CADDYFILE" ]]; then blank; sed 's/^/  /' "$CADDYFILE"
        else warn "未找到 ${CADDYFILE}"; fi ;;
      0|q|Q|"") info "已退出。"; return 0 ;;
      *) warn "无效的选项: ${choice}" ;;
    esac
  done
}

usage() {
  cat <<USAGE_EOF
${C_BOLD}NaiveProxy 一键安装 / 管理脚本 v${SCRIPT_VERSION}${C_RESET}
${C_DIM}项目地址: ${REPO_URL}${C_RESET}

${C_BOLD}用法:${C_RESET}
  bash ${SCRIPT_NAME} [命令] [参数...]

${C_BOLD}命令:${C_RESET}
  install      安装（默认命令）
  menu         打开交互式管理面板
  status       查看运行状态与证书信息
  info         重新打印节点信息 / 客户端配置
  start|stop|restart    启停服务
  log [N|-f]   查看日志（默认最近 120 行，-f 实时跟踪）
  update       更新 Caddy 到最新版（保留配置）
  renew        强制重新申请证书（会消耗 CA 配额）
  uninstall    卸载
  version      显示脚本版本
  help         显示本帮助

${C_BOLD}安装参数:${C_RESET}
  --domain <域名>            指定域名（默认 随机前缀.<公网IP>.nip.io）
  --prefix <前缀>            nip.io 域名前缀（不指定则随机 8 位）
  --ip <IPv4>                手动指定本机公网 IPv4
  --email <邮箱>             ACME 账户邮箱（接收证书到期提醒）
  --ca <CA>                  证书机构: letsencrypt | zerossl | letsencrypt-staging | custom
                             （默认交互选择，推荐 zerossl 以规避 LE 频率限制）
  --acme-ca <URL>            自定义 ACME 目录 URL（配合 --ca custom）
  --eab <KeyID:HMACKey>      ZeroSSL 手工 EAB 凭据（默认用邮箱自动获取）
  --user <用户名>            代理用户名（默认随机）
  --pass <密码>              代理密码（默认随机 24 位，也可写作 --password）
  --https-port <端口>        HTTPS/代理端口（默认 443）
  --http-port <端口>         HTTP 端口（默认 80，用于证书校验）
  --http3 <模式>             on   = HTTP/2 + HTTP/3（默认）
                             h2only = 仅 HTTP/2      h3only = 关闭 HTTP/2
                             （也可写作 --h3）
  --masq <模式>              伪装内容: reverse（默认，反代真实网站）| static（本机静态页）| none
  --masq-target <URL>        反代目标，例如 https://www.bing.com 或你自己的博客
  --webroot <目录>           静态伪装页目录（--masq static 时使用，默认 ${WEBROOT_DEFAULT}）
  --probe-secret <域名>      启用探针密道（浏览器访问该域名会弹出登录框）
  --run-as <caddy|root>      运行身份（默认 caddy，更安全）
  --firewall <auto|yes|no>   是否自动放行防火墙端口（默认 auto）
  --bbr <auto|yes|no>        是否启用 BBR（默认 auto=询问）
  --install-method <方式>    auto（默认）| prebuilt（预编译）| source（源码编译）| api（官方在线构建）
  --caddy-version <版本>     指定 Caddy 版本（默认 ${DEFAULT_CADDY_VERSION}）
  --fp-tag <tag>             指定 forwardproxy 预编译包 tag（默认自动取最新）
  --allow-private            允许代理访问内网地址（默认禁止）
  --force, --force-reinstall 覆盖已有配置（自动备份原文件）
  --yes, -y                  非交互：全部使用默认值（适合脚本化部署）
  --interactive              强制交互模式（即使没有终端也尝试交互）
  --non-interactive, -n      强制非交互模式（等价于 --yes）
  --quiet, -q                减少输出
  --version                  显示脚本版本
  -h, --help                 显示帮助

${C_BOLD}典型用法:${C_RESET}
  ${C_DIM}# 交互式安装（推荐新手）${C_RESET}
  bash ${SCRIPT_NAME}

  ${C_DIM}# 全自动安装：ZeroSSL 证书 + 反代 bing 伪装${C_RESET}
  bash ${SCRIPT_NAME} install --ca zerossl --email me@example.com --yes

  ${C_DIM}# 使用自己的域名 + HTTP/3${C_RESET}
  bash ${SCRIPT_NAME} install --domain proxy.example.com --http3 on

  ${C_DIM}# 反代你自己的网站做伪装${C_RESET}
  bash ${SCRIPT_NAME} install --masq reverse --masq-target https://blog.example.com

  ${C_DIM}# 查看节点信息${C_RESET}
  bash ${SCRIPT_NAME} info

${C_BOLD}说明:${C_RESET}
  * 脚本会安装 caddy-forwardproxy-naive（klzgrad/forwardproxy 的 naive 分支），
    它是唯一带 NaiveProxy 填充层（padding）的服务端实现。
  * 只支持 Debian 11+/Ubuntu 20.04+，需要 root 权限。
  * 生产环境建议使用自己的域名 + 已解析的 A 记录；nip.io 适合临时测试。
USAGE_EOF
}

# ------------------------------------------------------------------------------
# 参数解析
# ------------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)      DOMAIN="$2"; shift 2 ;;
      --prefix)      DOMAIN_PREFIX="$2"; shift 2 ;;
      --ip)          PUBLIC_IP="$2"; shift 2 ;;
      --email)       ACME_EMAIL="$2"; shift 2 ;;
      --ca)
        CA_GIVEN="yes"
        case "$2" in
          le|letsencrypt|let|LE)              CA_MODE="letsencrypt" ;;
          zerossl|zero|zs|ZEROSSL)            CA_MODE="zerossl" ;;
          staging|letsencrypt-staging|le-staging) CA_MODE="letsencrypt-staging" ;;
          custom|其它|other)                  CA_MODE="custom" ;;
          *) die "未知的 --ca 取值: $2（可选: letsencrypt | zerossl | letsencrypt-staging | custom）" ;;
        esac
        shift 2 ;;
      --acme-ca)     ACME_CA_URL="$2"; shift 2 ;;
      --eab)
        EAB_KID="${2%%:*}"
        EAB_HMAC="${2#*:}"
        [[ -n "$EAB_KID" && -n "$EAB_HMAC" && "$EAB_KID" != "$EAB_HMAC" ]] || die "--eab 格式应为 KeyID:HMACKey"
        shift 2 ;;
      --user)        PROXY_USER="$2"; shift 2 ;;
      --pass|--password) PROXY_PASS="$2"; shift 2 ;;
      --https-port)  HTTPS_PORT="$2"; HTTPS_PORT_GIVEN="yes"; shift 2 ;;
      --http-port)   HTTP_PORT="$2"; HTTP_PORT_GIVEN="yes"; shift 2 ;;
      --http3|--h3)  HTTP3="$2"; shift 2 ;;
      --masq)
        MASQ_GIVEN="yes"
        case "$2" in
          reverse|proxy|反代) MASQ_MODE="reverse" ;;
          static|page|静态)   MASQ_MODE="static" ;;
          none|off|无)        MASQ_MODE="none" ;;
          *) die "未知的 --masq 取值: $2（可选: reverse | static | none）" ;;
        esac
        shift 2 ;;
      --masq-target) MASQ_MODE="reverse"; MASQ_TARGET="$2"; shift 2 ;;
      --probe-secret) PROBE_SECRET="$2"; shift 2 ;;
      --run-as)      RUN_AS="$2"; shift 2 ;;
      --firewall)    ENABLE_FIREWALL="$2"; shift 2 ;;
      --bbr)         ENABLE_BBR="$2"; shift 2 ;;
      --install-method) INSTALL_METHOD="$2"; shift 2 ;;
      --caddy-version)  CADDY_VERSION="$2"; shift 2 ;;
      --fp-tag)         FP_TAG="$2"; shift 2 ;;
      --allow-private)  ALLOW_PRIVATE_NETS="yes"; shift ;;
      --webroot)        WEBROOT="$2"; shift 2 ;;
      --force|--force-reinstall) FORCE="yes"; shift ;;
      --yes|-y)      ASSUME_YES="yes"; shift ;;
      --non-interactive|-n) INTERACTIVE="no"; shift ;;
      --interactive) INTERACTIVE="yes"; shift ;;
      --quiet|-q)    QUIET="yes"; shift ;;
      -h|--help)     usage; exit 0 ;;
      --version)     printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
      "")            shift ;;
      *) die "未知参数: $1（使用 --help 查看全部参数）" ;;
    esac
  done
}

# ------------------------------------------------------------------------------
# 入口
# ------------------------------------------------------------------------------
main() {
  local cmd=""
  local had_args="no"
  [[ $# -gt 0 ]] && had_args="yes"
  if [[ $# -gt 0 ]]; then
    case "$1" in
      install|status|info|start|stop|restart|log|logs|update|renew|uninstall|menu|help|version)
        cmd="$1"; shift ;;
      -h|--help)  usage; exit 0 ;;
      --version)  printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
      *)          cmd="" ;;
    esac
  fi
  # 只写了参数（例如 --ca zerossl --yes）时，默认执行安装
  if [[ -z "$cmd" && "$had_args" == "yes" ]]; then
    cmd="install"
  fi

  case "$cmd" in
    help)      usage; exit 0 ;;
    version)   printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
    log|logs)  cmd_log "${1:-120}"; exit 0 ;;
    uninstall) parse_args "$@"; cmd_uninstall; exit 0 ;;
  esac

  parse_args "$@"

  case "$cmd" in
    install)   cmd_install ;;
    status)    cmd_status ;;
    info)      cmd_info ;;
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    restart)   cmd_restart ;;
    update)    cmd_update ;;
    renew)     cmd_renew ;;
    menu)      cmd_menu ;;
    "")
      if [[ -f "$STATE_FILE" ]]; then
        if can_prompt; then cmd_menu; else cmd_info; fi
      else
        cmd_install
      fi
      ;;
    *)         usage; exit 1 ;;
  esac
}

main "$@"
