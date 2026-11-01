#!/usr/bin/env bash
# =============================================================================
#  Reality-Site OneClick  ·  nginx 伪装站 + VLESS Reality（自有域名做 target）
#
#  不依赖 S-UI 等面板，终端交互菜单完成：
#    Cloudflare Token / 域名 / IP / 端口 → DNS 记录(灰云) → acme.sh DNS-01 证书
#    → nginx(127.0.0.1:回落端口, proxy_protocol) → Xray Reality → 生成 vless:// 链接
#
#  用法:
#    bash rsite.sh            # 首次运行：安装为 rsite 命令并进入菜单
#    rsite  或  rl             # 交互菜单（rl 是 rsite 的短命令）
#    rsite install            # 直接进入部署向导
#    rsite link               # 显示节点链接 / 二维码 / Mihomo 配置
#    rsite doctor             # 诊断
#    rsite masque             # 显示 MASQUE 客户端配置
#    rsite core               # 核心管理：Xray 升级 / sing-box 安装与升级
#
#  支持: Debian 11+ / Ubuntu 20.04+ (x86_64 / arm64)，需 root
# =============================================================================

set -o pipefail

RSITE_VERSION="1.4.0"
RSITE_DIR="/etc/rsite"
RSITE_STATE="${RSITE_DIR}/rsite.env"
RSITE_BACKUP="${RSITE_DIR}/backup"
RSITE_BIN="/usr/local/bin/rsite"
RL_BIN="/usr/local/bin/rl"   # 短命令：输入 rl 调出菜单
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"
NGINX_CONF="/etc/nginx/conf.d/rsite.conf"
NGINX_LOG="/var/log/nginx/rsite.access.log"
ACME="/root/.acme.sh/acme.sh"
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

# -----------------------------------------------------------------------------
# 输出
# -----------------------------------------------------------------------------
if [ -t 1 ]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_W=$'\e[1m'; C_0=$'\e[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_W=""; C_0=""
fi
msg()   { printf '%s\n' "$*"; }
info()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn()  { printf '%s[警告]%s %s\n' "$C_Y" "$C_0" "$*"; }
err()   { printf '%s[错误]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
line()  { msg "------------------------------------------------------------"; }
# kv 键 值 …  —— 按显示宽度对齐（中文占 2 列）
kv() {
  local k v b c w
  while [ $# -ge 2 ]; do
    k="$1"; v="$2"; shift 2
    b="$(printf '%s' "$k" | LC_ALL=C wc -c)"; c="$(printf '%s' "$k" | LC_ALL=C.UTF-8 wc -m)"
    w=$(( c + (b - c) / 2 ))
    printf '  %s%*s %s\n' "$k" $(( w < 16 ? 16 - w : 1 )) '' "$v"
  done
}
title() { msg ""; msg "${C_W}==================== $* ====================${C_0}"; }
step()  { msg ""; msg "${C_W}${C_B}[$1]${C_0} ${C_W}$2${C_0}"; }

# -----------------------------------------------------------------------------
# 输入
# -----------------------------------------------------------------------------
_tty_read() { # _tty_read [read 选项...] 变量名
  if [ -t 0 ]; then read "$@"
  elif { : </dev/tty; } 2>/dev/null; then read "$@" </dev/tty
  else read "$@"; fi
}

# ask 变量 "提示" [默认值]
ask() {
  local __var="$1" __prompt="$2" __def="${3:-}" __in=""
  if [ -n "$__def" ]; then
    _tty_read -r -p "${__prompt} [${C_G}${__def}${C_0}]: " __in || true
  else
    _tty_read -r -p "${__prompt}: " __in || true
  fi
  __in="$(printf '%s' "$__in" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$__in" ] && __in="$__def"
  printf -v "$__var" '%s' "$__in"
}

# ask_secret 变量 "提示"   （输入不回显）
ask_secret() {
  local __var="$1" __prompt="$2" __in=""
  _tty_read -r -s -p "${__prompt}: " __in || true
  msg ""
  __in="$(printf '%s' "$__in" | tr -d '[:space:]')"
  printf -v "$__var" '%s' "$__in"
}

# confirm "提示" [y|n]   默认值
confirm() {
  local __prompt="$1" __def="${2:-n}" __in="" __hint="y/N"
  [ "$__def" = y ] && __hint="Y/n"
  _tty_read -r -p "${__prompt} [${__hint}]: " __in || true
  __in="$(printf '%s' "$__in" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
  [ -z "$__in" ] && __in="$__def"
  [ "$__in" = y ] || [ "$__in" = yes ]
}

pause() { local _x; msg ""; _tty_read -r -p "按回车返回菜单..." _x || true; }

# -----------------------------------------------------------------------------
# 校验
# -----------------------------------------------------------------------------
valid_domain() { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o; for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || return 1; done
}
valid_ipv6() { [[ "$1" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$1" == *:*:* ]]; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
valid_sid()  { [[ "$1" =~ ^[0-9a-f]{2,16}$ ]] && [ $(( ${#1} % 2 )) -eq 0 ]; }
valid_key()  { [[ "$1" =~ ^[A-Za-z0-9_-]{43}$ ]]; }
valid_email(){ [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }
valid_name() { [[ "$1" =~ ^[^[:space:]\'\"\\]{1,40}$ ]]; }

# -----------------------------------------------------------------------------
# 状态文件
# -----------------------------------------------------------------------------
STATE_KEYS="DOMAIN ZONE ZONE_ID SERVER_IP CONNECT_ADDR PORT FALLBACK_PORT UUID SID PRIVKEY PUBKEY FP NODE_NAME WEBROOT SITE_TITLE ACME_EMAIL BLOCK_CN LIMIT_FB"

state_defaults() {
  DOMAIN=""; ZONE=""; ZONE_ID=""; SERVER_IP=""; CONNECT_ADDR=""
  PORT="443"; FALLBACK_PORT="8443"; UUID=""; SID=""; PRIVKEY=""; PUBKEY=""
  FP="chrome"; NODE_NAME="Reality"; WEBROOT=""; SITE_TITLE="胸外科科普"
  ACME_EMAIL=""; BLOCK_CN="yes"; LIMIT_FB="yes"
}

state_load() {
  state_defaults
  [ -f "$RSITE_STATE" ] || return 1
  local k v
  while IFS='=' read -r k v; do
    case " $STATE_KEYS " in *" $k "*) ;; *) continue ;; esac
    v="${v#\'}"; v="${v%\'}"
    printf -v "$k" '%s' "$v"
  done <"$RSITE_STATE"
  return 0
}

state_save() {
  mkdir -p "$RSITE_DIR" && chmod 700 "$RSITE_DIR"
  local k tmp="${RSITE_STATE}.tmp"
  : >"$tmp" && chmod 600 "$tmp"
  for k in $STATE_KEYS; do printf "%s='%s'\n" "$k" "${!k}" >>"$tmp"; done
  mv -f "$tmp" "$RSITE_STATE"
}

is_deployed() { [ -f "$RSITE_STATE" ] && [ -f "$XRAY_CONF" ] && [ -x "$XRAY_BIN" ]; }

# -----------------------------------------------------------------------------
# 环境
# -----------------------------------------------------------------------------
require_root() { [ "$(id -u)" -eq 0 ] || { err "请用 root 运行（sudo -i 后再执行）"; exit 1; }; }

require_os() {
  if ! command -v apt-get >/dev/null 2>&1; then
    err "仅支持 Debian / Ubuntu（apt）系统"; exit 1
  fi
  command -v systemctl >/dev/null 2>&1 || { err "需要 systemd"; exit 1; }
}

APT_UPDATED=0
apt_install() {
  local missing=() p
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  info "安装依赖: ${missing[*]}"
  if [ "$APT_UPDATED" -eq 0 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null || { err "apt update 失败"; return 1; }
    APT_UPDATED=1
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >/dev/null || { err "安装失败: ${missing[*]}"; return 1; }
}

base_deps() { apt_install curl jq openssl ca-certificates socat cron iproute2 dnsutils qrencode; }

self_install() {
  local src="${BASH_SOURCE[0]:-$0}"
  if [ -f "$src" ] && [ "$(readlink -f "$src")" != "$RSITE_BIN" ]; then
    install -m 755 "$src" "$RSITE_BIN" && ok "已安装管理命令: rsite"
  fi
  [ -x "$RSITE_BIN" ] && rl_install
}

# 短命令 rl → rsite（已被其他程序占用时不覆盖）
rl_install() {
  if [ -L "$RL_BIN" ] && [ "$(readlink -f "$RL_BIN")" = "$RSITE_BIN" ]; then return 0; fi
  if [ -e "$RL_BIN" ]; then
    warn "$RL_BIN 已被其他程序占用，未创建短命令 rl（仍可用 rsite）"
    return 0
  fi
  ln -s "$RSITE_BIN" "$RL_BIN" && ok "已创建短命令: rl（输入 rl 即可调出菜单）"
}

detect_ip() {
  local ip="" u
  for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    ip="$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')"
    valid_ipv4 "$ip" && { printf '%s' "$ip"; return 0; }
  done
  return 1
}

port_owner() { # 输出占用端口的进程名（TCP 监听）
  ss -Hltnp "sport = :$1" 2>/dev/null | grep -o 'users:(("[^"]*"' | head -n1 | cut -d'"' -f2
}
port_owner_udp() { # 输出占用 UDP 端口的进程名
  ss -Hlunp "sport = :$1" 2>/dev/null | grep -o 'users:(("[^"]*"' | head -n1 | cut -d'"' -f2
}
port_pid() { # port_pid tcp|udp 端口 → 第一个占用进程的 PID
  local f=-Hltnp; [ "$1" = udp ] && f=-Hlunp
  ss "$f" "sport = :$2" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -n1 | cut -d= -f2
}
pid_unit() { # 进程所属的 systemd 服务名（没有则输出空）
  [ -n "$1" ] || return 0
  grep -oE '[^/]+\.service' "/proc/$1/cgroup" 2>/dev/null | tail -n1
}
# GitHub 最新版本号（去掉 v 前缀）；第二个参数 beta 表示包含预发布
gh_latest_tag() {
  local repo="$1" t=""
  if [ "${2:-}" = beta ]; then
    t="$(curl -fsSL --max-time 8 "https://api.github.com/repos/${repo}/releases?per_page=1" 2>/dev/null | jq -r '.[0].tag_name // empty' 2>/dev/null)"
  else
    t="$(curl -fsSL --max-time 8 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)"
  fi
  printf '%s' "${t#v}"
}

nginx_ver_ge() { # nginx_ver_ge 1.25.1
  local v; v="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  [ -n "$v" ] || return 1
  [ "$(printf '%s\n%s\n' "$1" "$v" | sort -V | head -n1)" = "$1" ]
}

# -----------------------------------------------------------------------------
# Cloudflare API
# -----------------------------------------------------------------------------
CF_API="https://api.cloudflare.com/client/v4"
cf() { # cf METHOD PATH [JSON]
  local m="$1" p="$2" d="${3:-}"
  if [ -n "$d" ]; then
    curl -sS --max-time 20 -X "$m" -H "Authorization: Bearer ${CF_TOKEN}" \
      -H "Content-Type: application/json" --data "$d" "${CF_API}${p}"
  else
    curl -sS --max-time 20 -X "$m" -H "Authorization: Bearer ${CF_TOKEN}" "${CF_API}${p}"
  fi
}

cf_errors() { jq -r '[.errors[]? | "\(.code): \(.message)"] | join("; ")' 2>/dev/null; }

# 根据完整域名自动找出 Token 可见的区域（zone）
cf_find_zone() {
  local d="$1" cand resp cnt
  cand="$d"
  while [[ "$cand" == *.* ]]; do
    resp="$(cf GET "/zones?name=${cand}")" || return 1
    if [ "$(jq -r '.success' <<<"$resp" 2>/dev/null)" != "true" ]; then
      err "Cloudflare API 返回错误: $(cf_errors <<<"$resp")"
      return 1
    fi
    cnt="$(jq -r '.result | length' <<<"$resp")"
    if [ "${cnt:-0}" -ge 1 ]; then
      ZONE="$cand"; ZONE_ID="$(jq -r '.result[0].id' <<<"$resp")"
      return 0
    fi
    cand="${cand#*.}"
  done
  return 1
}

# 创建/更新 A 记录（灰云）
cf_upsert_a() {
  local resp id body
  resp="$(cf GET "/zones/${ZONE_ID}/dns_records?type=A&name=${DOMAIN}")" || return 1
  [ "$(jq -r '.success' <<<"$resp")" = "true" ] || { err "读取 DNS 记录失败: $(cf_errors <<<"$resp")"; return 1; }
  id="$(jq -r '.result[0].id // empty' <<<"$resp")"
  body="$(jq -nc --arg n "$DOMAIN" --arg c "$SERVER_IP" '{type:"A",name:$n,content:$c,ttl:1,proxied:false}')"
  if [ -n "$id" ]; then
    resp="$(cf PUT "/zones/${ZONE_ID}/dns_records/${id}" "$body")"
  else
    resp="$(cf POST "/zones/${ZONE_ID}/dns_records" "$body")"
  fi
  [ "$(jq -r '.success' <<<"$resp")" = "true" ] || { err "写入 DNS 记录失败: $(cf_errors <<<"$resp")"; return 1; }
  ok "DNS: ${DOMAIN} → ${SERVER_IP}（灰云/仅 DNS）"
  # AAAA 记录会让 IPv6 客户端连到别处
  resp="$(cf GET "/zones/${ZONE_ID}/dns_records?type=AAAA&name=${DOMAIN}")"
  if [ "$(jq -r '.result | length' <<<"$resp" 2>/dev/null)" -ge 1 ] 2>/dev/null; then
    warn "该域名还存在 AAAA 记录：$(jq -r '[.result[] | "\(.content) proxied=\(.proxied)"] | join(", ")' <<<"$resp")"
    warn "若该 IPv6 不是本机或开了橙云，请到 Cloudflare 删除它"
  fi
}

# -----------------------------------------------------------------------------
# Xray 密钥
# -----------------------------------------------------------------------------
x25519_parse() { # 兼容新旧 xray x25519 输出格式
  local out="$1"
  PRIVKEY="$(sed -nE 's/^(PrivateKey|Private key):[[:space:]]*//p' <<<"$out" | head -n1 | tr -d '\r ')"
  PUBKEY="$(sed -nE 's/^(Password \(PublicKey\)|Public key|PublicKey|Password):[[:space:]]*//p' <<<"$out" | head -n1 | tr -d '\r ')"
  valid_key "$PRIVKEY" && valid_key "$PUBKEY"
}
gen_keypair()   { x25519_parse "$("$XRAY_BIN" x25519 2>/dev/null)"; }
derive_pubkey() { x25519_parse "$("$XRAY_BIN" x25519 -i "$1" 2>/dev/null)"; }
gen_uuid() {
  if [ -x "$XRAY_BIN" ]; then "$XRAY_BIN" uuid; else cat /proc/sys/kernel/random/uuid; fi
}
gen_sid() { openssl rand -hex 8; }

# -----------------------------------------------------------------------------
# 链接 / 客户端配置
# -----------------------------------------------------------------------------
urlenc() { jq -rn --arg v "$1" '$v|@uri'; }
link_host() { if valid_ipv6 "$1"; then printf '[%s]' "$1"; else printf '%s' "$1"; fi; }

vless_link() {
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
    "$UUID" "$(link_host "$CONNECT_ADDR")" "$PORT" "$DOMAIN" "$FP" "$PUBKEY" "$SID" "$(urlenc "$NODE_NAME")"
}

mihomo_yaml() {
  cat <<EOF
  - name: "${NODE_NAME}"
    type: vless
    server: ${CONNECT_ADDR}
    port: ${PORT}
    uuid: ${UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${DOMAIN}
    client-fingerprint: ${FP}
    reality-opts:
      public-key: ${PUBKEY}
      short-id: ${SID}
EOF
}

singbox_json() {
  jq -n --arg tag "$NODE_NAME" --arg s "$CONNECT_ADDR" --argjson p "$PORT" --arg u "$UUID" \
     --arg sni "$DOMAIN" --arg fp "$FP" --arg pbk "$PUBKEY" --arg sid "$SID" '{
    type:"vless", tag:$tag, server:$s, server_port:$p, uuid:$u, flow:"xtls-rprx-vision",
    tls:{enabled:true, server_name:$sni, utls:{enabled:true, fingerprint:$fp},
         reality:{enabled:true, public_key:$pbk, short_id:$sid}}}'
}

show_node() {
  state_load || { warn "尚未部署，请先运行「一键部署」"; return 1; }
  local link; link="$(vless_link)"
  title "节点信息"
  kv "节点名" "$NODE_NAME" "连接地址" "$CONNECT_ADDR" "端口" "$PORT" \
    "UUID" "$UUID" "flow" "xtls-rprx-vision" "传输/安全" "tcp / reality" \
    "SNI" "$DOMAIN" "fingerprint" "$FP" "公钥 pbk" "$PUBKEY" "shortId" "$SID"
  line
  msg "${C_W}VLESS 链接：${C_0}"
  msg "${C_G}${link}${C_0}"
  line
  if command -v qrencode >/dev/null 2>&1; then
    msg "二维码（终端窗口太窄可能显示错位）："
    qrencode -t ANSIUTF8 -m 1 "$link"
  fi
  line
  msg "${C_W}Mihomo / Clash.Meta：${C_0}"
  mihomo_yaml
  line
  msg "${C_W}sing-box outbound：${C_0}"
  singbox_json
  mkdir -p "$RSITE_DIR"
  ( umask 077; printf '%s\n' "$link" >"${RSITE_DIR}/link.txt" )
  msg ""
  msg "链接已保存到 ${RSITE_DIR}/link.txt（仅 root 可读）。UUID / shortId / 私钥 不要外传。"
}

# -----------------------------------------------------------------------------
# 证书 (acme.sh + Cloudflare DNS-01)
# -----------------------------------------------------------------------------
cert_dir()  { printf '/etc/nginx/ssl/%s' "$DOMAIN"; }
cert_ok() { # 证书存在、CN/SAN 匹配、7 天内不过期
  local c; c="$(cert_dir)/cert.pem"
  [ -s "$c" ] && [ -s "$(cert_dir)/key.pem" ] || return 1
  openssl x509 -in "$c" -noout -checkend 604800 >/dev/null 2>&1 || return 1
  openssl x509 -in "$c" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:${DOMAIN}\b" \
    || openssl x509 -in "$c" -noout -subject 2>/dev/null | grep -q "CN *= *${DOMAIN}$"
}

# acme.sh 首次签发时保存在 account.conf 里的 CF Token（没有则输出空）
acme_saved_token() {
  [ -f /root/.acme.sh/account.conf ] || return 0
  grep -m1 '^SAVED_CF_Token=' /root/.acme.sh/account.conf | cut -d= -f2- | tr -d "'\""
}

acme_install() {
  [ -x "$ACME" ] && return 0
  info "安装 acme.sh"
  curl -fsSL https://get.acme.sh | sh -s email="$ACME_EMAIL" >/dev/null || { err "acme.sh 安装失败"; return 1; }
  [ -x "$ACME" ]
}

# 安装证书到 nginx 目录；续签后执行 rsite cert-hook（重载 nginx，并同步给 MASQUE）
acme_install_cert() {
  mkdir -p "$(cert_dir)"
  "$ACME" --install-cert -d "$DOMAIN" --ecc \
    --key-file "$(cert_dir)/key.pem" --fullchain-file "$(cert_dir)/cert.pem" \
    --reloadcmd "${RSITE_BIN} cert-hook >/dev/null 2>&1 || systemctl reload nginx 2>/dev/null || true" >/dev/null || return 1
  chmod 600 "$(cert_dir)/key.pem"
}

issue_cert() {
  acme_install || return 1
  # 附录 A：清掉 account.conf 里写死的旧 Zone/Account ID，避免 count:0 类错误
  [ -f /root/.acme.sh/account.conf ] && sed -i '/SAVED_CF_Zone_ID\|SAVED_CF_Account_ID/d' /root/.acme.sh/account.conf
  local rc=0 force=()
  [ "${1:-}" = force ] && force=(--force)
  info "签发证书: ${DOMAIN}（DNS-01，ECC，Let's Encrypt）——约需 1~2 分钟"
  ( unset CF_Zone_ID CF_Account_ID CF_Key CF_Email
    export CF_Token="$CF_TOKEN"
    "$ACME" --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256 --server letsencrypt "${force[@]}" ) || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
    err "证书签发失败（acme.sh 退出码 $rc），日志: /root/.acme.sh/acme.sh.log"
    msg "  常见原因：Token 没有该区域的 DNS 编辑权限 / Token 设置了 IP 筛选但未包含本机 IP"
    return 1
  fi
  acme_install_cert || { err "安装证书失败"; return 1; }
  cert_ok || { err "证书文件校验失败"; return 1; }
  ok "证书: $(openssl x509 -in "$(cert_dir)/cert.pem" -noout -subject -enddate | tr '\n' ' ')"
}

# -----------------------------------------------------------------------------
# nginx
# -----------------------------------------------------------------------------
write_nginx_conf() {
  local listen_ssl dflt_listen h2line="" reject v6a="" v6b=""
  if [ -f /proc/net/if_inet6 ]; then v6a=" listen [::]:80 default_server;"; v6b=" listen [::]:80;"; fi
  if nginx_ver_ge 1.25.1; then
    listen_ssl="listen 127.0.0.1:${FALLBACK_PORT} ssl proxy_protocol;"
    dflt_listen="listen 127.0.0.1:${FALLBACK_PORT} ssl default_server proxy_protocol;"
    h2line="    http2 on;"
  else
    listen_ssl="listen 127.0.0.1:${FALLBACK_PORT} ssl http2 proxy_protocol;"
    dflt_listen="listen 127.0.0.1:${FALLBACK_PORT} ssl http2 default_server proxy_protocol;"
  fi
  if nginx_ver_ge 1.19.4; then
    reject="    ssl_reject_handshake on;"
  else
    # 老版本没有 ssl_reject_handshake：用自签证书兜底并直接断开
    local d="/etc/nginx/ssl/_default"
    if [ ! -s "$d/cert.pem" ]; then
      mkdir -p "$d"
      openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
        -subj "/CN=invalid" -keyout "$d/key.pem" -out "$d/cert.pem" >/dev/null 2>&1
    fi
    reject="    ssl_certificate $d/cert.pem;
    ssl_certificate_key $d/key.pem;
    return 444;"
  fi
  mkdir -p "$WEBROOT"
  cat >"$NGINX_CONF" <<EOF
# 由 rsite 生成 —— 重新部署会覆盖本文件
limit_conn_zone \$binary_remote_addr zone=rsite_perip:10m;
limit_req_zone  \$binary_remote_addr zone=rsite_req:10m rate=10r/s;

# 80：只给自己的域名跳 https，其余直接断开
server { listen 80 default_server;${v6a} return 444; }
server {
    listen 80;${v6b}
    server_name ${DOMAIN};
    return 301 https://\$host$( [ "$PORT" = 443 ] || printf ':%s' "$PORT" )\$request_uri;
}

# 非本域名的 SNI 拒绝握手
server {
    ${dflt_listen}
${reject}
}

server {
    ${listen_ssl}
${h2line}
    server_name ${DOMAIN};

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    ssl_certificate     $(cert_dir)/cert.pem;
    ssl_certificate_key $(cert_dir)/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:RSITE_SSL:10m;

    server_tokens off;
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    limit_conn rsite_perip 20;
    limit_req zone=rsite_req burst=30 nodelay;
    limit_rate 512k;

    access_log ${NGINX_LOG};

    root ${WEBROOT};
    index index.html;
    error_page 404 /404.html;
    location / { try_files \$uri \$uri/ =404; }
    location ~ /\. { deny all; }
}
EOF
}

apply_nginx() {
  # 删除 Debian/Ubuntu 默认站点（其 default_server 会与本配置冲突）
  if [ -e /etc/nginx/sites-enabled/default ]; then
    mkdir -p "$RSITE_BACKUP"
    mv -f /etc/nginx/sites-enabled/default "$RSITE_BACKUP/nginx-sites-enabled-default" 2>/dev/null
    info "已停用 nginx 默认站点（备份在 $RSITE_BACKUP）"
  fi
  write_nginx_conf
  local out
  out="$(nginx -t 2>&1)"
  if grep -q 'server_names_hash_bucket_size' <<<"$out"; then
    sed -i '1a server_names_hash_bucket_size 128;' "$NGINX_CONF"
    out="$(nginx -t 2>&1)"
  fi
  if ! grep -q 'test is successful' <<<"$out"; then
    err "nginx 配置检查失败："; msg "$out"; return 1
  fi
  systemctl enable nginx >/dev/null 2>&1
  systemctl restart nginx || { err "nginx 启动失败: journalctl -u nginx -n 30"; return 1; }
  ok "nginx 监听 127.0.0.1:${FALLBACK_PORT}（proxy_protocol），网站目录 ${WEBROOT}"
}

# -----------------------------------------------------------------------------
# 网站模板（纯静态）
# -----------------------------------------------------------------------------
write_site() {
  mkdir -p "$WEBROOT"
  local t="$SITE_TITLE" y; y="$(date +%Y)"
  cat >"$WEBROOT/index.html" <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${t}</title>
<meta name="description" content="胸外科常见疾病科普：肺、食管、纵隔、胸壁。">
<link rel="stylesheet" href="/style.css">
</head>
<body>
<header><div class="wrap"><a class="logo" href="/">${t}</a>
<nav><a href="#about">简介</a><a href="#nodule">肺结节</a><a href="#vats">胸腔镜</a><a href="#mg">重症肌无力</a><a href="#rehab">术后康复</a></nav></div></header>
<main class="wrap">
<section class="hero"><h1>把胸外科讲清楚</h1><p>面向患者与家属的胸外科常识整理。内容仅供科普参考，不能替代医生面诊。</p></section>

<section id="about"><h2>胸外科看什么病</h2>
<div class="grid">
<div class="card"><h3>肺</h3><p>肺结节、肺癌、肺大疱与气胸、支气管扩张等需要手术评估的肺部疾病。</p></div>
<div class="card"><h3>食管</h3><p>食管肿瘤、贲门失弛缓、食管良性狭窄等吞咽相关疾病。</p></div>
<div class="card"><h3>纵隔</h3><p>胸腺瘤、神经源性肿瘤、纵隔囊肿等位于两肺之间的病变。</p></div>
<div class="card"><h3>胸壁</h3><p>漏斗胸、胸壁肿瘤、肋骨骨折等胸廓本身的问题。</p></div>
</div></section>

<section id="nodule"><h2>体检发现肺结节怎么办</h2>
<p>肺结节非常常见，绝大多数是良性的。医生通常根据结节的<b>大小、密度（实性 / 磨玻璃 / 混合）、形态</b>以及既往影像的变化来判断风险，并给出随访间隔。</p>
<ul><li>保存好每一次的胸部 CT 原始影像，方便前后对比。</li>
<li>按医生建议的时间复查，不要因为焦虑过度频繁检查，也不要拖延。</li>
<li>戒烟是对肺最有益的一件事。</li></ul></section>

<section id="vats"><h2>胸腔镜手术是什么</h2>
<p>胸腔镜手术（VATS）通过胸壁上的小切口，在摄像系统辅助下完成操作。与传统开胸相比，切口小、对胸壁肌肉损伤少，多数患者恢复更快。是否适合微创，需要结合病变位置、大小和全身情况由医生评估。</p></section>

<section id="mg"><h2>重症肌无力与胸腺切除</h2>
<p>重症肌无力是一种自身免疫病，常见表现为眼睑下垂、看东西重影、四肢易疲劳，症状往往“晨轻暮重”。部分患者合并胸腺增生或胸腺瘤，胸腺切除是综合治疗中的一部分，需要神经内科与胸外科共同评估手术时机。</p></section>

<section id="rehab"><h2>术后康复小贴士</h2>
<ul><li><b>咳嗽排痰：</b>按住伤口、深吸气后用力咳，帮助肺复张。</li>
<li><b>早期活动：</b>在医护指导下尽早下床，预防血栓和肺部感染。</li>
<li><b>呼吸训练：</b>腹式呼吸、吹气球或呼吸训练器，循序渐进。</li>
<li><b>疼痛管理：</b>疼痛影响咳嗽和活动时及时告诉医生。</li></ul></section>

<p class="note">本站为个人科普站点，不提供在线问诊与预约，不收集任何个人信息。如有不适请到正规医院就诊。</p>
</main>
<footer><div class="wrap">© ${y} ${t}</div></footer>
</body>
</html>
EOF
  cat >"$WEBROOT/style.css" <<'EOF'
*{box-sizing:border-box}body{margin:0;font:16px/1.75 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif;color:#1f2a37;background:#f6f8fb}
.wrap{max-width:960px;margin:0 auto;padding:0 20px}header{background:#fff;border-bottom:1px solid #e5e9f0;position:sticky;top:0}
header .wrap{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;min-height:60px}
.logo{font-weight:700;color:#0b6e75;text-decoration:none;font-size:18px}nav a{margin-left:18px;color:#4b5563;text-decoration:none;font-size:15px}nav a:hover{color:#0b6e75}
.hero{padding:56px 0 24px}.hero h1{font-size:34px;margin:0 0 8px}.hero p{color:#4b5563;margin:0}
section{padding:22px 0}h2{font-size:22px;border-left:4px solid #0b6e75;padding-left:10px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:14px}
.card{background:#fff;border:1px solid #e5e9f0;border-radius:10px;padding:16px}.card h3{margin:0 0 6px;color:#0b6e75}.card p{margin:0;font-size:15px;color:#4b5563}
.note{font-size:14px;color:#6b7280;border-top:1px solid #e5e9f0;padding-top:16px;margin-top:24px}
footer{padding:24px 0;color:#9ca3af;font-size:14px}
@media(max-width:600px){nav a{margin:0 12px 0 0}.hero h1{font-size:26px}}
EOF
  cat >"$WEBROOT/404.html" <<EOF
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>页面不存在 - ${t}</title><link rel="stylesheet" href="/style.css"></head>
<body><main class="wrap"><section class="hero"><h1>404</h1><p>页面不存在，<a href="/">返回首页</a>。</p></section></main></body></html>
EOF
  printf 'User-agent: *\nAllow: /\n' >"$WEBROOT/robots.txt"
  chmod -R a+rX "$WEBROOT"
  ok "已写入静态网站模板（${WEBROOT}）"
}

# -----------------------------------------------------------------------------
# Xray
# -----------------------------------------------------------------------------
install_xray() {
  if [ -x "$XRAY_BIN" ] && [ "${1:-}" != upgrade ]; then
    ok "Xray 已安装: $("$XRAY_BIN" version 2>/dev/null | head -n1)"
    return 0
  fi
  info "安装/更新 Xray（官方 install-release.sh）"
  bash -c "$(curl -fsSL "$XRAY_INSTALL_URL")" @ install >/dev/null 2>&1 \
    || { err "Xray 安装失败，可手动执行: bash -c \"\$(curl -L $XRAY_INSTALL_URL)\" @ install"; return 1; }
  [ -x "$XRAY_BIN" ] || { err "未找到 $XRAY_BIN"; return 1; }
  ok "Xray: $("$XRAY_BIN" version 2>/dev/null | head -n1)"
}

# gen_xray_json <target|dest> <1|0 是否启用 limitFallback>
gen_xray_json() {
  local tkey="$1" lim="$2"
  jq -n \
    --argjson port "$PORT" --arg uuid "$UUID" --arg email "$NODE_NAME" \
    --arg tkey "$tkey" --arg target "127.0.0.1:${FALLBACK_PORT}" \
    --arg sni "$DOMAIN" --arg pk "$PRIVKEY" --arg sid "$SID" \
    --argjson lim "$lim" --argjson cn "$([ "$BLOCK_CN" = yes ] && echo true || echo false)" '
  def limit: {afterBytes:4194304, bytesPerSec:65536, burstBytesPerSec:131072};
  {
    log: {loglevel:"warning", access:"none"},
    inbounds: [{
      tag:"reality-in", listen:"0.0.0.0", port:$port, protocol:"vless",
      settings:{clients:[{id:$uuid, flow:"xtls-rprx-vision", email:$email}], decryption:"none"},
      streamSettings:{
        network:"tcp", security:"reality",
        realitySettings:(
          {show:false, xver:1, serverNames:[$sni], privateKey:$pk, shortIds:[$sid]}
          + {($tkey): $target}
          + (if $lim then {limitFallbackUpload:limit, limitFallbackDownload:limit} else {} end))
      },
      sniffing:{enabled:true, destOverride:["http","tls","quic"], routeOnly:true}
    }],
    outbounds: [{tag:"direct", protocol:"freedom"}, {tag:"block", protocol:"blackhole"}],
    routing: {domainStrategy:"AsIs", rules: (
      [{type:"field", ip:["geoip:private"], outboundTag:"block"},
       {type:"field", protocol:["bittorrent"], outboundTag:"block"}]
      + (if $cn then [{type:"field", ip:["geoip:cn"], outboundTag:"block"}] else [] end))}
  }'
}

apply_xray() {
  mkdir -p "$(dirname "$XRAY_CONF")" "$RSITE_BACKUP"
  if [ -s "$XRAY_CONF" ] && ! cmp -s "$XRAY_CONF" "$RSITE_BACKUP/xray-last.json" 2>/dev/null; then
    cp -f "$XRAY_CONF" "$RSITE_BACKUP/xray-$(date +%Y%m%d-%H%M%S).json"
  fi
  local tmp="${RSITE_DIR}/xray-test.json" v tkey lim want_lim=1 out=""
  [ "$LIMIT_FB" = yes ] || want_lim=0
  # 依次尝试：新字段 target → 旧字段 dest；limitFallback 不被支持时自动去掉
  for v in "target:$want_lim" "target:0" "dest:$want_lim" "dest:0"; do
    tkey="${v%%:*}"; lim="${v##*:}"
    gen_xray_json "$tkey" "$lim" >"$tmp" || { err "生成 Xray 配置失败"; return 1; }
    if out="$("$XRAY_BIN" run -test -c "$tmp" 2>&1)"; then
      [ "$want_lim" = 1 ] && [ "$lim" = 0 ] && warn "当前 Xray 不支持 limitFallback，已省略（升级 Xray 后重新部署即可启用）"
      chmod 644 "$tmp"; mv -f "$tmp" "$XRAY_CONF"
      cp -f "$XRAY_CONF" "$RSITE_BACKUP/xray-last.json"
      systemctl enable xray >/dev/null 2>&1
      systemctl restart xray || { err "Xray 启动失败: journalctl -u xray -n 30"; return 1; }
      sleep 1
      systemctl is-active --quiet xray || { err "Xray 未运行: journalctl -u xray -n 30"; return 1; }
      ok "Xray Reality 监听 0.0.0.0:${PORT} → 回落 127.0.0.1:${FALLBACK_PORT}（xver=1）"
      return 0
    fi
  done
  rm -f "$tmp"
  err "Xray 配置测试失败："; msg "$out"
  return 1
}

# -----------------------------------------------------------------------------
# 端口检查 / 防火墙
# -----------------------------------------------------------------------------
check_port_free() { # check_port_free 端口 期望的进程名
  local p="$1" want="$2" o
  o="$(port_owner "$p")"
  [ -z "$o" ] || [ "$o" = "$want" ] && return 0
  warn "端口 ${p} 已被进程「${o}」占用"
  if [[ "$o" == *s-ui* || "$o" == *sing-box* || "$o" == *sui* ]] && systemctl list-unit-files 2>/dev/null | grep -q '^s-ui'; then
    if confirm "检测到 S-UI，是否停止并禁用 s-ui 服务以释放端口？" y; then
      systemctl disable --now s-ui >/dev/null 2>&1
      sleep 1
      o="$(port_owner "$p")"; [ -z "$o" ] && { ok "已释放端口 ${p}"; return 0; }
    fi
  fi
  confirm "端口 ${p} 仍被「${o}」占用，继续可能导致启动失败。仍要继续吗？" n
}

ufw_allow_ports() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  ufw allow 80/tcp >/dev/null && ufw allow "${PORT}/tcp" >/dev/null
  ok "UFW 已放行 80/tcp、${PORT}/tcp"
}

# -----------------------------------------------------------------------------
# 部署向导
# -----------------------------------------------------------------------------
wizard() {
  local reconf=0 tmp
  state_load && reconf=1
  local old_domain="$DOMAIN" old_ip="$SERVER_IP"

  title "Reality 伪装站 · 部署向导"
  msg "按提示输入，直接回车使用 [方括号] 中的默认值。"
  [ "$reconf" = 1 ] && msg "检测到已有部署，默认值为当前配置。"

  # 1. 域名
  step "1/6" "域名"
  while :; do
    ask DOMAIN "网站域名（例 thoracic.example.com）" "$DOMAIN"
    DOMAIN="$(tr 'A-Z' 'a-z' <<<"$DOMAIN")"
    valid_domain "$DOMAIN" && break
    warn "域名格式不正确"
  done

  # 2. Cloudflare Token
  step "2/6" "Cloudflare API Token"
  msg "CF「我的个人资料 → API 令牌」→ 模板「编辑区域 DNS」，区域资源只授权本域名所在区域。"
  msg "Token 只用于本次签发证书和写 DNS，输入时不显示；acme.sh 会自行保存以便自动续签。"
  CF_TOKEN=""
  local need_token=1 saved_token="" use_saved=0
  if [ "$reconf" = 1 ] && [ "$DOMAIN" = "$old_domain" ] && cert_ok; then
    need_token=0
    msg "${C_G}当前证书有效，可直接回车跳过（跳过则不改 DNS、不重签证书）。${C_0}"
  else
    # 同一区域（主域名）下换子域名：复用 acme.sh 已保存的 Token
    saved_token="$(acme_saved_token)"
    if [ -n "$saved_token" ]; then
      info "检测到 acme.sh 已保存的 Token，验证是否可用于 ${DOMAIN}..."
      CF_TOKEN="$saved_token"
      if cf_find_zone "$DOMAIN" 2>/dev/null; then
        use_saved=1
        msg "${C_G}已保存的 Token 可用（区域: ${ZONE}），直接回车即可复用；也可以输入新的 Token。${C_0}"
      else
        msg "已保存的 Token 看不到 ${DOMAIN} 所在的区域，请输入可用的 Token。"
      fi
      CF_TOKEN=""
    fi
  fi
  while :; do
    ask_secret CF_TOKEN "CF Token"
    if [ -z "$CF_TOKEN" ]; then
      [ "$need_token" = 0 ] && break
      if [ "$use_saved" = 1 ]; then
        CF_TOKEN="$saved_token"; ok "复用已保存的 Token，区域: ${ZONE}"; break
      fi
      warn "首次部署必须提供 Token"; continue
    fi
    info "验证 Token 并查找区域..."
    if cf_find_zone "$DOMAIN"; then
      ok "Token 可用，区域: ${ZONE}"; break
    fi
    warn "该 Token 看不到 ${DOMAIN} 所在的区域（count:0）。检查「区域资源」与「客户端 IP 筛选」后重试。"
  done

  # 3. IP 与端口
  step "3/6" "服务器 IP 与端口"
  if [ -z "$SERVER_IP" ]; then info "探测公网 IPv4..."; SERVER_IP="$(detect_ip || true)"; fi
  while :; do
    ask SERVER_IP "VPS 公网 IPv4（DNS A 记录指向它）" "$SERVER_IP"
    valid_ipv4 "$SERVER_IP" && break; warn "IPv4 格式不正确"
  done
  while :; do
    ask PORT "Reality 对外端口" "$PORT"
    valid_port "$PORT" && break; warn "端口无效"
  done
  while :; do
    ask FALLBACK_PORT "nginx 本机回落端口（仅 127.0.0.1）" "$FALLBACK_PORT"
    valid_port "$FALLBACK_PORT" && [ "$FALLBACK_PORT" != "$PORT" ] && [ "$FALLBACK_PORT" != 80 ] && break
    warn "端口无效或与对外端口/80 冲突"
  done

  # 4. 客户端 / 节点
  step "4/6" "节点参数（回车自动生成）"
  [ -z "$CONNECT_ADDR" ] && CONNECT_ADDR="$SERVER_IP"
  [ -n "$old_ip" ] && [ "$CONNECT_ADDR" = "$old_ip" ] && CONNECT_ADDR="$SERVER_IP"
  while :; do
    ask CONNECT_ADDR "客户端连接地址（IP 或域名）" "$CONNECT_ADDR"
    valid_ipv4 "$CONNECT_ADDR" || valid_ipv6 "$CONNECT_ADDR" || valid_domain "$CONNECT_ADDR" && break
    warn "地址格式不正确"
  done
  while :; do
    ask UUID "UUID" "${UUID:-自动生成}"
    [ "$UUID" = "自动生成" ] && UUID=""
    [ -z "$UUID" ] && break
    valid_uuid "$UUID" && break; warn "UUID 格式不正确"
  done
  while :; do
    ask SID "shortId（2~16 位十六进制，偶数长度）" "${SID:-自动生成}"
    [ "$SID" = "自动生成" ] && SID=""
    SID="$(tr 'A-F' 'a-f' <<<"$SID")"
    [ -z "$SID" ] && break
    valid_sid "$SID" && break; warn "shortId 格式不正确"
  done
  msg "fingerprint: 1) chrome  2) firefox  3) safari  4) edge  5) ios  6) random"
  ask tmp "选择" "$(case "$FP" in firefox) echo 2;; safari) echo 3;; edge) echo 4;; ios) echo 5;; random) echo 6;; *) echo 1;; esac)"
  case "$tmp" in 2) FP=firefox;; 3) FP=safari;; 4) FP=edge;; 5) FP=ios;; 6) FP=random;; *) FP=chrome;; esac
  while :; do
    ask NODE_NAME "节点名称（链接 # 后的备注）" "$NODE_NAME"
    valid_name "$NODE_NAME" && break; warn "节点名不能含空格或引号，最长 40 字符"
  done

  # 5. 网站
  step "5/6" "伪装网站"
  [ -z "$WEBROOT" ] && WEBROOT="/var/www/${DOMAIN%%.*}"
  while :; do
    ask WEBROOT "网站目录" "$WEBROOT"
    [[ "$WEBROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] && [ "$WEBROOT" != / ] && break; warn "目录无效"
  done
  ask SITE_TITLE "网站标题" "$SITE_TITLE"
  SITE_TITLE="$(tr -d '<>&"'"'"'\\' <<<"$SITE_TITLE")"; [ -z "$SITE_TITLE" ] && SITE_TITLE="胸外科科普"
  WRITE_SITE=no
  if [ -s "$WEBROOT/index.html" ]; then
    confirm "网站目录已有 index.html，是否用内置胸外科科普模板覆盖？" n && WRITE_SITE=yes
  else
    WRITE_SITE=yes
  fi

  # 6. 其他
  step "6/6" "其他选项"
  [ -z "$ACME_EMAIL" ] && ACME_EMAIL="admin@${ZONE:-$DOMAIN}"
  if [ -n "$CF_TOKEN" ]; then
    while :; do
      ask ACME_EMAIL "证书邮箱（Let's Encrypt 到期提醒）" "$ACME_EMAIL"
      valid_email "$ACME_EMAIL" && break; warn "邮箱格式不正确"
    done
    DO_DNS=no
    confirm "自动在 Cloudflare 创建/更新 A 记录 ${DOMAIN} → ${SERVER_IP}（灰云）？" y && DO_DNS=yes
  fi
  confirm "拦截回国流量 geoip:cn（教程默认开启）？" "$([ "$BLOCK_CN" = yes ] && echo y || echo n)" && BLOCK_CN=yes || BLOCK_CN=no
  confirm "启用 limitFallback 防偷跑限速（回落超 4MB 后限 64KB/s）？" "$([ "$LIMIT_FB" = yes ] && echo y || echo n)" && LIMIT_FB=yes || LIMIT_FB=no

  # 汇总
  title "确认配置"
  kv \
    "域名 / SNI" "$DOMAIN" \
    "CF 区域" "${ZONE:-（跳过）}" \
    "VPS IP" "$SERVER_IP" \
    "Reality 端口" "0.0.0.0:${PORT}" \
    "nginx 回落" "127.0.0.1:${FALLBACK_PORT}（proxy_protocol / xver=1）" \
    "客户端地址" "$CONNECT_ADDR" \
    "UUID" "${UUID:-自动生成}" \
    "shortId" "${SID:-自动生成}" \
    "fingerprint" "$FP" \
    "节点名" "$NODE_NAME" \
    "网站目录" "$WEBROOT（$([ "$WRITE_SITE" = yes ] && echo 写入模板 || echo 保留现有)）" \
    "DNS 记录" "$([ "${DO_DNS:-no}" = yes ] && echo 自动写入 || echo 不修改)" \
    "证书" "$([ -n "$CF_TOKEN" ] && echo "acme.sh DNS-01 / ECC" || echo 沿用现有)" \
    "geoip:cn 拦截" "$BLOCK_CN" \
    "limitFallback" "$LIMIT_FB"
  line
  confirm "开始部署？" y || { warn "已取消"; return 1; }
  deploy "$old_domain"
}

deploy() {
  local old_domain="${1:-}" total=7
  step "1/$total" "安装依赖"
  base_deps && apt_install nginx || return 1

  step "2/$total" "检查端口"
  check_port_free "$PORT" xray || return 1
  check_port_free "$FALLBACK_PORT" nginx || return 1
  check_port_free 80 nginx || return 1

  step "3/$total" "Cloudflare DNS"
  if [ "${DO_DNS:-no}" = yes ]; then
    cf_upsert_a || warn "DNS 写入失败，请手动在 CF 添加 A 记录（灰云）"
  else
    msg "跳过（请确保 ${DOMAIN} 的 A 记录指向 ${SERVER_IP} 且为灰云）"
  fi

  step "4/$total" "证书"
  systemctl enable --now nginx >/dev/null 2>&1 || true
  if [ -n "${CF_TOKEN:-}" ]; then
    if [ -n "$old_domain" ] && [ "$old_domain" != "$DOMAIN" ]; then
      issue_cert force || return 1
      "$ACME" --remove -d "$old_domain" --ecc >/dev/null 2>&1 && info "已移除旧域名 ${old_domain} 的续签任务"
    else
      issue_cert || return 1
    fi
  else
    cert_ok || { err "没有可用证书，且未提供 Token"; return 1; }
    ok "沿用现有证书"
  fi

  step "5/$total" "伪装网站 + nginx"
  [ "${WRITE_SITE:-no}" = yes ] && write_site
  [ -s "$WEBROOT/index.html" ] || write_site
  apply_nginx || return 1

  step "6/$total" "Xray Reality"
  install_xray || return 1
  [ -z "$UUID" ] && UUID="$(gen_uuid)"
  [ -z "$SID" ] && SID="$(gen_sid)"
  if [ -n "$PRIVKEY" ] && derive_pubkey "$PRIVKEY"; then
    :
  else
    gen_keypair || { err "生成 x25519 密钥失败"; return 1; }
  fi
  state_save
  apply_xray || return 1
  ufw_allow_ports

  step "7/$total" "自检"
  doctor quick
  show_node
  msg ""
  ok "部署完成。浏览器访问 https://${DOMAIN}$( [ "$PORT" = 443 ] || printf ':%s' "$PORT" ) 应显示网站；客户端导入上面的链接即可。"
}

# -----------------------------------------------------------------------------
# 修改配置
# -----------------------------------------------------------------------------
rotate_menu() {
  state_load && is_deployed || { warn "尚未部署"; return 1; }
  title "修改节点参数"
  msg "  1) 重新运行部署向导（可改域名/端口/IP 等）"
  msg "  2) 更换 UUID"
  msg "  3) 更换 shortId"
  msg "  4) 重新生成 Reality 密钥对"
  msg "  5) 全部更换（UUID + shortId + 密钥）"
  msg "  6) 只改客户端连接地址 / 节点名 / fingerprint（不动服务端）"
  msg "  0) 返回"
  local c; ask c "请选择 [0-6]" ""
  case "$c" in
    1) wizard; return ;;
    2) UUID="$(gen_uuid)" ;;
    3) SID="$(gen_sid)" ;;
    4) gen_keypair || { err "生成密钥失败"; return 1; } ;;
    5) UUID="$(gen_uuid)"; SID="$(gen_sid)"; gen_keypair || return 1 ;;
    6)
      ask CONNECT_ADDR "客户端连接地址" "$CONNECT_ADDR"
      ask NODE_NAME "节点名称" "$NODE_NAME"; valid_name "$NODE_NAME" || NODE_NAME="Reality"
      ask FP "fingerprint (chrome/firefox/safari/edge/ios/random)" "$FP"
      case "$FP" in chrome|firefox|safari|edge|ios|random) ;; *) FP=chrome ;; esac
      state_save; show_node; return ;;
    *) return 0 ;;
  esac
  state_save
  apply_xray && { warn "旧链接已失效，请在客户端导入新链接"; show_node; }
}

# -----------------------------------------------------------------------------
# 诊断
# -----------------------------------------------------------------------------
doctor() {
  state_load || { warn "尚未部署"; return 1; }
  [ "${1:-}" = quick ] || title "诊断 Doctor"
  local pass=0 fail=0
  chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; pass=$((pass+1)); else printf '%s[FAIL]%s %s\n' "$C_R" "$C_0" "$1"; [ -n "${3:-}" ] && msg "       → $3"; fail=$((fail+1)); fi; }

  chk "xray 运行中"   "systemctl is-active --quiet xray" "journalctl -u xray -n 30"
  chk "nginx 运行中"  "systemctl is-active --quiet nginx" "nginx -t; journalctl -u nginx -n 30"
  chk "0.0.0.0:${PORT} 由 xray 监听" "[ \"\$(port_owner $PORT)\" = xray ]" "端口被 $(port_owner "$PORT") 占用"
  chk "127.0.0.1:${FALLBACK_PORT} 由 nginx 监听" "[ \"\$(port_owner $FALLBACK_PORT)\" = nginx ]"
  chk "证书有效且匹配 ${DOMAIN}（>7 天）" "cert_ok" "菜单「证书管理 → 强制续签」"
  local res; res="$(dig +short A "$DOMAIN" @1.1.1.1 2>/dev/null | tail -n1)"
  chk "DNS ${DOMAIN} → ${SERVER_IP}（当前解析: ${res:-无}）" "[ \"$res\" = \"$SERVER_IP\" ]" \
      "解析到 CF 的 IP 说明开了橙云，必须改为灰云（仅 DNS）"
  local code
  code="$(curl --noproxy '*' -sk -o /dev/null -w '%{http_code}' --max-time 8 --resolve "${DOMAIN}:${PORT}:127.0.0.1" "https://${DOMAIN}:${PORT}/" 2>/dev/null)"
  chk "经 Reality 回落访问网站返回 200（实际: ${code:-无}）" "[ \"$code\" = 200 ]" "检查 xver 与 nginx proxy_protocol 是否同时开启"
  chk "非本域名 SNI 握手被拒绝" \
      "! (timeout 6 openssl s_client -connect 127.0.0.1:${PORT} -servername www.baidu.com </dev/null 2>/dev/null | grep -q 'BEGIN CERTIFICATE')"
  chk "Xray 配置测试通过" "$XRAY_BIN run -test -c $XRAY_CONF"
  if [ -x "$ACME" ]; then
    chk "acme.sh 自动续签任务存在" "crontab -l 2>/dev/null | grep -q acme.sh" "$ACME --install-cronjob"
  fi
  line
  msg "通过 ${pass} 项，失败 ${fail} 项。"
  [ "${1:-}" = quick ] || msg "外部验证：在本地（关代理）执行 curl -I https://${DOMAIN}$( [ "$PORT" = 443 ] || printf ':%s' "$PORT" ) 应返回 200"
}

# -----------------------------------------------------------------------------
# 证书管理
# -----------------------------------------------------------------------------
cert_menu() {
  state_load || { warn "尚未部署"; return 1; }
  title "证书管理"
  if [ -s "$(cert_dir)/cert.pem" ]; then
    openssl x509 -in "$(cert_dir)/cert.pem" -noout -subject -issuer -enddate | sed 's/^/  /'
  else
    warn "未找到证书"
  fi
  msg ""
  msg "  1) 强制续签（使用 acme.sh 已保存的 Token）"
  msg "  2) 更换 Token 后重新签发"
  msg "  0) 返回"
  local c; ask c "请选择 [0-2]" ""
  case "$c" in
    1)
      "$ACME" --renew -d "$DOMAIN" --ecc --force && ok "已续签" || err "续签失败，可尝试 2) 换 Token" ;;
    2)
      ask_secret CF_TOKEN "新的 CF Token"
      [ -n "$CF_TOKEN" ] || return 1
      cf_find_zone "$DOMAIN" || { err "Token 看不到 ${DOMAIN} 的区域"; return 1; }
      issue_cert force && systemctl reload nginx ;;
  esac
}

# -----------------------------------------------------------------------------
# 服务管理
# -----------------------------------------------------------------------------
service_menu() {
  title "服务管理"
  msg "  1) 状态"
  msg "  2) 重启 xray + nginx"
  msg "  3) 停止 xray"
  msg "  4) 启动 xray"
  msg "  5) 查看 xray 日志（最近 50 行）"
  msg "  6) 查看 nginx 错误日志（最近 30 行）"
  msg "  7) 更新 Xray 核心"
  msg "  0) 返回"
  local c; ask c "请选择 [0-7]" ""
  case "$c" in
    1) systemctl --no-pager status xray nginx | grep -E '●|Active:|Main PID' ;
       [ -x "$XRAY_BIN" ] && "$XRAY_BIN" version | head -n1; nginx -v 2>&1 ;;
    2) nginx -t && systemctl restart nginx xray && ok "已重启" ;;
    3) systemctl stop xray && ok "已停止" ;;
    4) systemctl start xray && ok "已启动" ;;
    5) journalctl -u xray -n 50 --no-pager ;;
    6) tail -n 30 /var/log/nginx/error.log ;;
    7) xray_upgrade stable ;;
  esac
}

# -----------------------------------------------------------------------------
# 核心管理：Xray 升级 / sing-box 安装与升级
# -----------------------------------------------------------------------------
SB_BIN="/usr/bin/sing-box"
SB_CONF="/etc/sing-box/config.json"
SB_INSTALL_URL="https://sing-box.app/install.sh"
SB_INSTALL_URL2="https://raw.githubusercontent.com/SagerNet/sing-box/testing/docs/installation/tools/install.sh"

xray_ver_now() { [ -x "$XRAY_BIN" ] && "$XRAY_BIN" version 2>/dev/null | head -n1 | awk '{print $2}'; }

# xray_upgrade stable|beta|ver [版本号]
# 升级后用新核心测试所有 rsite 生成的 Xray 配置，失败自动回滚到旧核心
xray_upgrade() {
  local mode="$1" ver="${2:-}" old bak args=(install) out c bad=0
  apt_install curl jq unzip >/dev/null || return 1
  old="$(xray_ver_now)"
  case "$mode" in
    beta) args+=(--beta) ;;
    ver)  [[ "$ver" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || { err "版本号格式应为 25.10.15 这样的数字"; return 1; }
          args+=(--version "v${ver#v}") ;;
  esac
  mkdir -p "$RSITE_BACKUP"; bak="$RSITE_BACKUP/xray.bin.prev"
  [ -x "$XRAY_BIN" ] && cp -f "$XRAY_BIN" "$bak"
  info "升级 Xray（当前: ${old:-未安装}，方式: ${mode}${ver:+ $ver}）"
  if ! out="$(bash -c "$(curl -fsSL "$XRAY_INSTALL_URL")" @ "${args[@]}" 2>&1)"; then
    err "Xray 安装脚本失败："; msg "$out" | tail -n 8; return 1
  fi
  [ -x "$XRAY_BIN" ] || { err "未找到 $XRAY_BIN"; return 1; }
  for c in "$XRAY_CONF" "$VENC_CONF"; do
    [ -s "$c" ] || continue
    if ! "$XRAY_BIN" run -test -c "$c" >/dev/null 2>&1; then
      warn "新核心无法通过配置测试: $c"; bad=1
    fi
  done
  if [ "$bad" = 1 ] && [ -s "$bak" ]; then
    if confirm "是否回滚到旧版本 ${old}？" y; then
      install -m 755 "$bak" "$XRAY_BIN"
      systemctl restart xray 2>/dev/null; systemctl try-restart "$VENC_SVC" 2>/dev/null
      warn "已回滚到 $(xray_ver_now)"; return 1
    fi
  fi
  # Reality：重新生成配置（新核心可能支持 limitFallback 等新字段）
  if state_load && is_deployed; then apply_xray || return 1
  else systemctl try-restart xray 2>/dev/null || true; fi
  systemctl try-restart "$VENC_SVC" 2>/dev/null || true
  ok "Xray: ${old:-无} → $(xray_ver_now)"
}

sb_ver_now() { [ -x "$SB_BIN" ] && "$SB_BIN" version 2>/dev/null | head -n1 | awk '{print $3}'; }

# 官方安装包自带的示例配置是一个公开密码的 shadowsocks 入站，启用服务前必须替换
sb_sanitize_conf() {
  [ -f "$SB_CONF" ] || return 0
  if grep -q 'Gn1JUS14bLUHgv1cWDDp4A==' "$SB_CONF" 2>/dev/null; then
    mkdir -p "$RSITE_BACKUP"; cp -f "$SB_CONF" "$RSITE_BACKUP/sing-box-sample.json"
    printf '%s\n' '{' '  "log": { "level": "warn" },' '  "inbounds": [],' \
      '  "outbounds": [ { "type": "direct", "tag": "direct" } ]' '}' >"$SB_CONF"
    chmod 600 "$SB_CONF"
    info "已把官方示例配置（含公开密码的 SS 入站）替换为空配置: $SB_CONF"
  fi
}

# singbox_install stable|beta|ver [版本号]
singbox_install() {
  local mode="$1" ver="${2:-}" old tmp args=()
  command -v dpkg >/dev/null 2>&1 || { err "仅支持 dpkg 系统"; return 1; }
  apt_install curl jq >/dev/null || return 1
  old="$(sb_ver_now)"
  case "$mode" in
    beta) args+=(--beta) ;;
    ver)  [[ "$ver" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || { err "版本号格式应为 1.12.0 或 1.13.0-beta.1"; return 1; }
          args+=(--version "${ver#v}") ;;
  esac
  tmp="$(mktemp -d)"
  if ! curl -fsSL --max-time 30 "$SB_INSTALL_URL" -o "$tmp/install.sh" 2>/dev/null; then
    curl -fsSL --max-time 30 "$SB_INSTALL_URL2" -o "$tmp/install.sh" || { err "下载 sing-box 安装脚本失败"; rm -rf "$tmp"; return 1; }
  fi
  info "安装 sing-box（当前: ${old:-未安装}，方式: ${mode}${ver:+ $ver}）"
  if ! ( cd "$tmp" && sh ./install.sh "${args[@]}" ); then
    err "sing-box 安装失败"; rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp"
  [ -x "$SB_BIN" ] || { err "未找到 $SB_BIN"; return 1; }
  sb_sanitize_conf
  if systemctl is-active --quiet sing-box 2>/dev/null; then
    if "$SB_BIN" check -c "$SB_CONF" >/dev/null 2>&1; then
      systemctl restart sing-box && ok "sing-box 服务已重启"
    else
      warn "新版本 sing-box 无法通过现有配置检查（sing-box check -c $SB_CONF），服务未重启，请按新版文档调整配置"
    fi
  fi
  ok "sing-box: ${old:-无} → $(sb_ver_now)"
  [ -z "$old" ] && msg "提示：仅安装了核心，服务未启用。配置写入 $SB_CONF 后执行 systemctl enable --now sing-box。"
}

singbox_remove() {
  [ -x "$SB_BIN" ] || { warn "未安装 sing-box"; return 0; }
  confirm "卸载 sing-box（会停止服务，配置目录 /etc/sing-box 保留）？" n || return 0
  systemctl disable --now sing-box >/dev/null 2>&1
  local p; p="$(dpkg-query -W -f='${Package}\n' 'sing-box*' 2>/dev/null | head -n1)"
  if [ -n "$p" ]; then DEBIAN_FRONTEND=noninteractive apt-get remove -y "$p" >/dev/null 2>&1; fi
  [ -x "$SB_BIN" ] && rm -f "$SB_BIN"
  ok "已卸载 sing-box"
}

core_menu() {
  local c v
  title "核心管理：Xray / sing-box / masque-server"
  info "查询最新版本..."
  kv "Xray 当前" "$(xray_ver_now || true)" \
     "Xray 最新正式" "$(gh_latest_tag XTLS/Xray-core)" \
     "Xray 最新预发布" "$(gh_latest_tag XTLS/Xray-core beta)" \
     "sing-box 当前" "$(sb_ver_now || true)" \
     "sing-box 最新正式" "$(gh_latest_tag SagerNet/sing-box)" \
     "sing-box 最新预发布" "$(gh_latest_tag SagerNet/sing-box beta)" \
     "masque-server 当前" "$(mq_ver_now || true)" \
     "masque-server 最新" "$(gh_latest_tag "$MQ_REPO")"
  msg ""
  msg "  1) 升级 Xray 到最新正式版"
  msg "  2) 升级 Xray 到最新预发布版（beta）"
  msg "  3) 安装指定版本 Xray（可用于回退）"
  msg "  4) 安装 / 升级 sing-box 到最新正式版"
  msg "  5) 安装 / 升级 sing-box 到最新预发布版（beta）"
  msg "  6) 安装指定版本 sing-box"
  msg "  7) 卸载 sing-box"
  msg "  8) 升级 masque-server（MASQUE 服务端）"
  msg "  0) 返回"
  ask c "请选择 [0-8]" ""
  case "$c" in
    1) xray_upgrade stable ;;
    2) xray_upgrade beta ;;
    3) ask v "Xray 版本号（如 25.10.15）" ""; xray_upgrade ver "$v" ;;
    4) singbox_install stable ;;
    5) singbox_install beta ;;
    6) ask v "sing-box 版本号（如 1.12.0）" ""; singbox_install ver "$v" ;;
    7) singbox_remove ;;
    8) mq_install_bin upgrade ;;
  esac
}

# -----------------------------------------------------------------------------
# 防偷跑
# -----------------------------------------------------------------------------
abuse_menu() {
  title "防偷跑 / 访问统计"
  msg "  1) 访问最多的 IP（Top 20）"
  msg "  2) 流量最大的 IP（Top 20，按字节）"
  msg "  3) 封禁 IP（ufw deny）"
  msg "  4) 查看已封禁"
  msg "  5) 解除封禁"
  msg "  0) 返回"
  local c ip; ask c "请选择 [0-5]" ""
  case "$c" in
    1) [ -f "$NGINX_LOG" ] && awk '{print $1}' "$NGINX_LOG" | sort | uniq -c | sort -rn | head -n 20 || warn "暂无日志" ;;
    2) [ -f "$NGINX_LOG" ] && awk '{b[$1]+=$10} END{for(i in b) printf "%12d  %s\n", b[i], i}' "$NGINX_LOG" | sort -rn | head -n 20 || warn "暂无日志" ;;
    3|5)
      command -v ufw >/dev/null 2>&1 || { warn "未安装 ufw，请先在「系统加固」中启用防火墙"; return 1; }
      ask ip "IP 或网段（如 1.2.3.4 或 1.2.3.0/24）" ""
      [[ "$ip" =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]] || { warn "格式不正确"; return 1; }
      if [ "$c" = 3 ]; then ufw insert 1 deny from "$ip" >/dev/null && ok "已封禁 $ip"
      else ufw delete deny from "$ip" >/dev/null && ok "已解除 $ip"; fi ;;
    4) command -v ufw >/dev/null 2>&1 && ufw status | grep -i deny || msg "无" ;;
  esac
}

# -----------------------------------------------------------------------------
# 系统加固
# -----------------------------------------------------------------------------
ssh_port_now() { sshd -T 2>/dev/null | awk '/^port /{print $2; exit}'; }

# 判断服务器所在区域：返回 cn 或 oversea（结果缓存）
GEO_REGION=""
geo_region() {
  if [ -n "$GEO_REGION" ]; then printf '%s' "$GEO_REGION"; return; fi
  local loc=""
  loc="$(curl -s --max-time 6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -nE 's/^loc=//p' | tr -d '[:space:]')"
  [ -n "$loc" ] || loc="$(curl -s --max-time 6 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]')"
  if [ "$loc" = CN ]; then GEO_REGION=cn; else GEO_REGION=oversea; fi
  printf '%s' "$GEO_REGION"
}
region_label() { [ "$(geo_region)" = cn ] && printf '国内' || printf '海外'; }

# 生成 ed25519 密钥并写入 authorized_keys；私钥仅显示一次
ssh_gen_key() {
  apt_install openssh-client >/dev/null 2>&1 || true
  command -v ssh-keygen >/dev/null 2>&1 || { err "缺少 ssh-keygen"; return 1; }
  local kf=/root/.ssh/rsite_ed25519
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  if [ -f "$kf" ]; then
    warn "已存在 $kf，复用它（不覆盖）"
  else
    ssh-keygen -t ed25519 -N '' -C "rsite-$(date +%Y%m%d)" -f "$kf" >/dev/null || { err "生成密钥失败"; return 1; }
  fi
  touch /root/.ssh/authorized_keys
  grep -qxF "$(cat "$kf.pub")" /root/.ssh/authorized_keys 2>/dev/null || cat "$kf.pub" >>/root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  ok "已生成/写入密钥：$kf（公钥已加入 authorized_keys）"
  line
  warn "下面是【私钥】，只显示这一次，请完整复制保存到本地（含首尾两行）："
  msg "本地保存为 id_ed25519 后： chmod 600 id_ed25519 && ssh -i id_ed25519 -p <端口> root@${SERVER_IP:-服务器IP}"
  line
  cat "$kf"
  line
  return 0
}

harden_ssh() {
  local cur newp; cur="$(ssh_port_now)"; cur="${cur:-22}"
  warn "修改前请确认：你已能用【密钥】登录本机。关闭密码登录后只能用密钥。"
  if [ ! -s /root/.ssh/authorized_keys ] && ! ls /home/*/.ssh/authorized_keys >/dev/null 2>&1; then
    warn "没有找到任何 authorized_keys。"
    if confirm "现在生成一把新密钥并写入（否则中止）？" y; then
      ssh_gen_key || return 1
      confirm "私钥已显示并保存好了吗？继续将关闭密码登录" n || { warn "已中止，未改动 SSH"; return 0; }
    else
      err "没有密钥，关闭密码登录会把你锁在外面。已中止。"; return 1
    fi
  fi
  while :; do ask newp "SSH 端口" "$cur"; valid_port "$newp" && break; done
  confirm "SSH 端口 ${newp}，仅密钥登录，root 仅允许密钥。确定应用？" n || return 0
  local drop="/etc/ssh/sshd_config.d/00-rsite.conf"
  if grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
    mkdir -p /etc/ssh/sshd_config.d
    printf 'Port %s\nPasswordAuthentication no\nChallengeResponseAuthentication no\nPermitRootLogin prohibit-password\n' "$newp" >"$drop"
  else
    cp -f /etc/ssh/sshd_config "$RSITE_BACKUP/sshd_config.$(date +%s)" 2>/dev/null
    sed -i -E 's/^#?PasswordAuthentication.*/PasswordAuthentication no/; s/^#?PermitRootLogin.*/PermitRootLogin prohibit-password/; s/^#?Port .*/Port '"$newp"'/' /etc/ssh/sshd_config
  fi
  if ! sshd -t; then err "sshd 配置检查失败，已回滚"; rm -f "$drop"; return 1; fi
  if command -v ufw >/dev/null 2>&1; then ufw allow "${newp}/tcp" >/dev/null; fi
  if [ -f /etc/fail2ban/jail.local ]; then sed -i -E "s/^port *=.*/port = ${newp}/" /etc/fail2ban/jail.local; systemctl restart fail2ban 2>/dev/null; fi
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl daemon-reload; systemctl restart ssh.socket
  fi
  systemctl restart ssh 2>/dev/null || systemctl restart sshd
  ok "SSH 已改为端口 ${newp}（仅密钥）。${C_Y}不要关闭当前窗口，先另开终端测试: ssh -p ${newp} root@${SERVER_IP:-服务器IP}${C_0}"
}

harden_ufw() {
  apt_install ufw || return 1
  local sp; sp="$(ssh_port_now)"; sp="${sp:-22}"
  state_load || true
  msg "将放行：SSH ${sp}/tcp、80/tcp、${PORT:-443}/tcp，其余入站全部拒绝。"
  confirm "启用 UFW？" y || return 0
  ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
  ufw allow "${sp}/tcp" >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow "${PORT:-443}/tcp" >/dev/null
  ufw --force enable >/dev/null && ok "UFW 已启用" && ufw status
}

harden_f2b() {
  apt_install fail2ban || return 1
  local sp; sp="$(ssh_port_now)"; sp="${sp:-22}"
  printf '[sshd]\nenabled = true\nport = %s\nbackend = systemd\nmaxretry = 5\nbantime = 1h\n' "$sp" >/etc/fail2ban/jail.local
  systemctl enable fail2ban >/dev/null 2>&1; systemctl restart fail2ban
  sleep 1; fail2ban-client status sshd 2>/dev/null && ok "fail2ban sshd jail 已启用（端口 ${sp}）"
}

harden_bbr() {
  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >/etc/sysctl.d/99-bbr.conf
  sysctl --system >/dev/null 2>&1
  ok "当前拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
}

# TCP / 内核参数调优（含 BBR+fq、缓冲区、fast open、连接数、文件句柄）
harden_tcp() {
  cat >/etc/sysctl.d/99-rsite-tcp.conf <<'EOF'
# rsite TCP / network tuning
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.core.netdev_max_backlog=32768
net.core.somaxconn=8192
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_tw_reuse=1
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.ip_local_port_range=1024 65535
fs.file-max=1048576
EOF
  sysctl --system >/dev/null 2>&1
  if [ -d /etc/security/limits.d ]; then
    printf '* soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576\n' \
      >/etc/security/limits.d/99-rsite.conf
  fi
  ok "TCP/内核参数已优化（BBR+fq、缓冲区、TFO、句柄上限）。部分 limits 需重新登录生效。"
  msg "拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
}

# 系统更新源：海外用官方源，国内换阿里云镜像（自动按地区；已备份可回滚）
harden_mirror() {
  command -v apt-get >/dev/null 2>&1 || { err "仅支持 Debian/Ubuntu"; return 1; }
  local id codename region mirror
  id=debian; codename=""
  if [ -r /etc/os-release ]; then . /etc/os-release; id="${ID:-debian}"; codename="${VERSION_CODENAME:-}"; fi
  [ -n "$codename" ] || { err "无法识别系统版本代号，已跳过"; return 1; }
  region="$(geo_region)"
  if [ "$region" = cn ]; then mirror=aliyun; else mirror=official; fi
  msg "系统: ${id} ${codename}，地区: $(region_label)，将使用：${mirror} 源"
  confirm "切换更新源？（原文件会备份）" y || return 0
  local bk; bk="$RSITE_BACKUP/apt-$(date +%s)"; mkdir -p "$bk"
  cp -a /etc/apt/sources.list "$bk/" 2>/dev/null || true
  cp -a /etc/apt/sources.list.d "$bk/" 2>/dev/null || true
  local base sec
  if [ "$id" = ubuntu ]; then
    [ "$mirror" = aliyun ] && base="http://mirrors.aliyun.com/ubuntu" || base="http://archive.ubuntu.com/ubuntu"
    _write_apt_ubuntu "$base" "$codename"
  else
    if [ "$mirror" = aliyun ]; then base="http://mirrors.aliyun.com/debian"; sec="http://mirrors.aliyun.com/debian-security"
    else base="http://deb.debian.org/debian"; sec="http://security.debian.org/debian-security"; fi
    _write_apt_debian "$base" "$sec" "$codename"
  fi
  if DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1; then
    ok "更新源已切换为 ${mirror}，apt update 成功"
  else
    err "apt update 失败，正在回滚..."
    rm -f /etc/apt/sources.list; cp -a "$bk/sources.list" /etc/apt/ 2>/dev/null || true
    rm -rf /etc/apt/sources.list.d; cp -a "$bk/sources.list.d" /etc/apt/ 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1
    warn "已回滚到原更新源（备份在 $bk）"
    return 1
  fi
}

_write_apt_ubuntu() {
  local base="$1" cn="$2"
  if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    cat >/etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: ${base}
Suites: ${cn} ${cn}-updates ${cn}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${base}
Suites: ${cn}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    : >/etc/apt/sources.list
  else
    cat >/etc/apt/sources.list <<EOF
deb ${base} ${cn} main restricted universe multiverse
deb ${base} ${cn}-updates main restricted universe multiverse
deb ${base} ${cn}-backports main restricted universe multiverse
deb ${base} ${cn}-security main restricted universe multiverse
EOF
  fi
}

_write_apt_debian() {
  local base="$1" sec="$2" cn="$3"
  if [ -f /etc/apt/sources.list.d/debian.sources ]; then
    cat >/etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: ${base}
Suites: ${cn} ${cn}-updates ${cn}-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${sec}
Suites: ${cn}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    : >/etc/apt/sources.list
  else
    cat >/etc/apt/sources.list <<EOF
deb ${base} ${cn} main contrib non-free non-free-firmware
deb ${base} ${cn}-updates main contrib non-free non-free-firmware
deb ${sec} ${cn}-security main contrib non-free non-free-firmware
EOF
  fi
}

# 更新系统到最新
harden_update() {
  msg "更新软件包列表并升级到最新..."
  DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1 || { err "apt update 失败"; return 1; }
  DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade || { err "升级失败"; return 1; }
  apt_install unattended-upgrades >/dev/null 2>&1 && \
    dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
  ok "系统已更新到最新，并已开启自动安全更新"
  [ -f /var/run/reboot-required ] && warn "内核/核心组件已更新，建议重启：reboot"
}

# 清理系统垃圾文件
harden_clean() {
  local before after freed
  before="$(df -k / | awk 'NR==2{print $4}')"
  msg "清理 apt 缓存、无用依赖、日志、临时文件..."
  DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get -y autoclean >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get -y clean >/dev/null 2>&1 || true
  if command -v journalctl >/dev/null 2>&1; then
    journalctl --rotate >/dev/null 2>&1 || true
    journalctl --vacuum-time=3d >/dev/null 2>&1 || true
  fi
  rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
  find /var/log -type f \( -name '*.gz' -o -name '*.1' -o -name '*.old' \) -delete 2>/dev/null || true
  after="$(df -k / | awk 'NR==2{print $4}')"
  freed=$(( (after-before)/1024 ))
  ok "清理完成，根分区约释放 ${freed} MB（当前可用 $(( after/1024 )) MB）"
}

# 自动优化 DNS：海外 1.1.1.1 / 8.8.8.8，国内 223.5.5.5 / 223.6.6.6
harden_dns() {
  local region servers sv
  region="$(geo_region)"
  if [ "$region" = cn ]; then servers="223.5.5.5 223.6.6.6"; else servers="1.1.1.1 8.8.8.8"; fi
  msg "检测到服务器位于：$(region_label)，将设置 DNS：${servers}"
  confirm "应用 DNS？" y || return 0
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    mkdir -p /etc/systemd/resolved.conf.d
    { echo "[Resolve]"; echo "DNS=${servers}"; echo "FallbackDNS=1.1.1.1 8.8.8.8"; } >/etc/systemd/resolved.conf.d/rsite.conf
    systemctl restart systemd-resolved
    ok "已通过 systemd-resolved 设置 DNS：${servers}"
  else
    cp -a /etc/resolv.conf "$RSITE_BACKUP/resolv.conf.$(date +%s)" 2>/dev/null || true
    chattr -i /etc/resolv.conf 2>/dev/null || true
    [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
    : >/etc/resolv.conf
    for sv in $servers; do echo "nameserver $sv" >>/etc/resolv.conf; done
    ok "已写入 /etc/resolv.conf：${servers}"
    warn "若面板/DHCP 会覆盖 resolv.conf，请在面板里改，或自行 chattr +i 锁定"
  fi
}

harden_menu() {
  title "系统优化 / 加固（可选，按需执行）"
  msg "  1) 更新系统到最新 + 自动安全更新"
  msg "  2) 优化更新源（按地区：海外官方 / 国内阿里云镜像）"
  msg "  3) 清理系统垃圾文件"
  msg "  4) 自动优化 DNS（海外 1.1.1.1/8.8.8.8，国内 223.5.5.5）"
  msg "  5) TCP / 内核参数调优（含 BBR+fq）"
  msg "  6) SSH：改端口 + 生成密钥 + 仅密钥登录"
  msg "  7) UFW 防火墙（只开 SSH / 80 / Reality 端口）"
  msg "  8) fail2ban（sshd）"
  msg "  9) 仅开启 BBR + fq"
  msg "  0) 返回"
  local c; ask c "请选择 [0-9]" ""
  case "$c" in
    1) harden_update ;;
    2) harden_mirror ;;
    3) harden_clean ;;
    4) harden_dns ;;
    5) harden_tcp ;;
    6) harden_ssh ;;
    7) harden_ufw ;;
    8) harden_f2b ;;
    9) harden_bbr ;;
  esac
}

# -----------------------------------------------------------------------------
# 卸载
# -----------------------------------------------------------------------------
uninstall() {
  state_load || true
  title "卸载"
  warn "将删除：Xray（含配置）、nginx 站点配置 rsite.conf、证书续签任务、VLESS-Enc / mieru / MASQUE、rsite 状态与命令。"
  msg "保留：nginx 软件包、sing-box、UFW 规则、SSH 设置、网站目录（会单独询问）。"
  confirm "确定卸载？" n || return 0
  systemctl disable --now xray >/dev/null 2>&1
  # 一并清理其他协议（若存在）
  systemctl disable --now "$VENC_SVC" >/dev/null 2>&1; rm -f "/etc/systemd/system/${VENC_SVC}.service"; rm -rf "$VENC_DIR" "$VENC_STATE" "${RSITE_DIR}/venc-link.txt"
  systemctl disable --now "$MIERU_SVC" >/dev/null 2>&1; rm -f "/etc/systemd/system/${MIERU_SVC}.service"; rm -rf "$MIERU_DIR" "$MIERU_STATE" "${RSITE_DIR}/mieru-link.txt"
  [ -f "$MQ_STATE" ] && mq_purge quiet
  systemctl daemon-reload 2>/dev/null || true
  bash -c "$(curl -fsSL "$XRAY_INSTALL_URL")" @ remove --purge >/dev/null 2>&1 || rm -f "$XRAY_BIN"
  rm -f "$NGINX_CONF"
  if [ -f "$RSITE_BACKUP/nginx-sites-enabled-default" ] && [ ! -e /etc/nginx/sites-enabled/default ]; then
    mv "$RSITE_BACKUP/nginx-sites-enabled-default" /etc/nginx/sites-enabled/default
  fi
  nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null
  if [ -n "$DOMAIN" ] && [ -x "$ACME" ]; then
    "$ACME" --remove -d "$DOMAIN" --ecc >/dev/null 2>&1
    rm -rf "/etc/nginx/ssl/${DOMAIN}"
  fi
  if [ -n "$WEBROOT" ] && [ -d "$WEBROOT" ] && confirm "同时删除网站目录 ${WEBROOT}？" n; then rm -rf "$WEBROOT"; fi
  rm -rf "$RSITE_DIR"; rm -f "$RSITE_BIN"
  if [ -L "$RL_BIN" ] && [ "$(readlink "$RL_BIN")" = "$RSITE_BIN" ]; then rm -f "$RL_BIN"; fi
  ok "已卸载。Cloudflare 上的 DNS 记录和 Token 请自行处理（建议在 CF 轮换/删除 Token）。"
  exit 0
}

# =============================================================================
#  其他协议：VLESS Encryption（mlkem768x25519plus，无流控）与 mieru
#  （由 rsite 追加；与 Reality 节点各自独立，互不影响）
# =============================================================================
MITA_BIN="/usr/local/bin/mita"
MIERU_DIR="${RSITE_DIR}/mieru"
MIERU_STATE="${RSITE_DIR}/mieru.env"
MIERU_CONF="${MIERU_DIR}/server.json"
MIERU_UDS="/run/rsite-mita.sock"
MIERU_SVC="rsite-mita"
MIERU_REPO="enfein/mieru"
VENC_STATE="${RSITE_DIR}/venc.env"
VENC_DIR="/usr/local/etc/xray-venc"
VENC_CONF="${VENC_DIR}/config.json"
VENC_SVC="xray-venc"
VENC_KEX="mlkem768x25519plus"

# ---------------------------------------------------------------- VLESS Encryption
VENC_KEYS="VENC_PORT VENC_UUID VENC_AUTH VENC_MODE VENC_PRIV VENC_CLIENT VENC_NODE VENC_ADDR VENC_BLOCK_CN"
venc_defaults() {
  VENC_PORT="2443"; VENC_UUID=""; VENC_AUTH="x25519"; VENC_MODE="native"
  VENC_PRIV=""; VENC_CLIENT=""; VENC_NODE="VLESS-ENC"; VENC_ADDR=""; VENC_BLOCK_CN="yes"
}
venc_load() {
  venc_defaults; [ -f "$VENC_STATE" ] || return 1
  local k v
  while IFS='=' read -r k v; do
    case " $VENC_KEYS " in *" $k "*) ;; *) continue ;; esac
    v="${v#\'}"; v="${v%\'}"; printf -v "$k" '%s' "$v"
  done <"$VENC_STATE"; return 0
}
venc_save() {
  mkdir -p "$RSITE_DIR" && chmod 700 "$RSITE_DIR"
  local k tmp="${VENC_STATE}.tmp"; : >"$tmp" && chmod 600 "$tmp"
  for k in $VENC_KEYS; do printf "%s='%s'\n" "$k" "${!k}" >>"$tmp"; done
  mv -f "$tmp" "$VENC_STATE"
}
venc_deployed() { [ -f "$VENC_STATE" ] && [ -f "$VENC_CONF" ] && [ -x "$XRAY_BIN" ]; }

# 生成 server decryption / client encryption 串
venc_dec() { printf '%s.%s.600s.%s' "$VENC_KEX" "$VENC_MODE" "$VENC_PRIV"; }
venc_enc() { printf '%s.%s.0rtt.%s' "$VENC_KEX" "$VENC_MODE" "$VENC_CLIENT"; }

# venc_keygen：按 VENC_AUTH 生成，结果写入 VENC_PRIV / VENC_CLIENT
venc_keygen() {
  local out priv cli
  [ -x "$XRAY_BIN" ] || return 1
  out="$("$XRAY_BIN" "$VENC_AUTH" 2>/dev/null)" || return 1
  case "$VENC_AUTH" in
    x25519)
      priv="$(sed -nE 's/^(PrivateKey|Private key):[[:space:]]*//p' <<<"$out" | head -n1 | tr -d '\r ')"
      cli="$(sed -nE 's/^(Password \(PublicKey\)|Public key|Password):[[:space:]]*//p' <<<"$out" | head -n1 | tr -d '\r ')" ;;
    mlkem768)
      priv="$(sed -nE 's/^Seed:[[:space:]]*//p' <<<"$out" | head -n1 | tr -d '\r ')"
      cli="$(sed -nE 's/^Client:[[:space:]]*//p' <<<"$out" | head -n1 | tr -d '\r ')" ;;
    *) return 1 ;;
  esac
  [ -n "$priv" ] && [ -n "$cli" ] || return 1
  VENC_PRIV="$priv"; VENC_CLIENT="$cli"
}

venc_gen_config() {
  mkdir -p "$VENC_DIR"
  jq -n --argjson port "$VENC_PORT" --arg uuid "$VENC_UUID" --arg email "$VENC_NODE" \
     --arg dec "$(venc_dec)" --argjson cn "$([ "$VENC_BLOCK_CN" = yes ] && echo true || echo false)" '
  {
    log:{loglevel:"warning", access:"none"},
    inbounds:[{
      tag:"venc-in", listen:"0.0.0.0", port:$port, protocol:"vless",
      settings:{clients:[{id:$uuid, email:$email}], decryption:$dec},
      streamSettings:{network:"tcp", security:"none"},
      sniffing:{enabled:true, destOverride:["http","tls","quic"], routeOnly:true}
    }],
    outbounds:[{tag:"direct",protocol:"freedom"},{tag:"block",protocol:"blackhole"}],
    routing:{domainStrategy:"AsIs", rules:(
      [{type:"field",ip:["geoip:private"],outboundTag:"block"},
       {type:"field",protocol:["bittorrent"],outboundTag:"block"}]
      + (if $cn then [{type:"field",ip:["geoip:cn"],outboundTag:"block"}] else [] end))}
  }' >"${VENC_CONF}.tmp" || return 1
  mv -f "${VENC_CONF}.tmp" "$VENC_CONF"
}

venc_write_service() {
  cat >/etc/systemd/system/${VENC_SVC}.service <<EOF
[Unit]
Description=Xray VLESS-Encryption (rsite)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -c ${VENC_CONF}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

venc_link() {
  printf 'vless://%s@%s:%s?encryption=%s&security=none&type=tcp&headerType=none#%s' \
    "$VENC_UUID" "$(link_host "$VENC_ADDR")" "$VENC_PORT" "$(urlenc "$(venc_enc)")" "$(urlenc "$VENC_NODE")"
}

venc_show() {
  venc_load || { warn "尚未部署 VLESS Encryption"; return 1; }
  local link; link="$(venc_link)"
  title "VLESS Encryption 节点"
  kv "节点名" "$VENC_NODE" "连接地址" "$VENC_ADDR" "端口" "$VENC_PORT" \
     "UUID" "$VENC_UUID" "认证/外观" "${VENC_AUTH} / ${VENC_MODE}" "传输/安全" "tcp / none（无 TLS）"
  line
  msg "${C_W}VLESS 链接：${C_0}"; msg "${C_G}${link}${C_0}"
  line
  command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 -m 1 "$link"
  line
  msg "${C_W}Xray 客户端 encryption 字段：${C_0}"; msg "$(venc_enc)"
  msg "提示：VLESS Encryption 需较新客户端（Xray 25.x+ / Mihomo 1.19.30+），sing-box 暂不支持。"
  ( umask 077; printf '%s\n' "$link" >"${RSITE_DIR}/venc-link.txt" )
}

venc_deploy() {
  local reconf=0; venc_load && reconf=1
  title "部署 VLESS Encryption（mlkem768x25519plus，无流控）"
  [ -z "$VENC_ADDR" ] && { state_load 2>/dev/null; VENC_ADDR="${CONNECT_ADDR:-${SERVER_IP:-$(detect_ip || true)}}"; }
  while :; do ask VENC_PORT "对外端口" "$VENC_PORT"; valid_port "$VENC_PORT" && break; warn "端口无效"; done
  while :; do
    ask VENC_ADDR "客户端连接地址（IP 或域名）" "$VENC_ADDR"
    valid_ipv4 "$VENC_ADDR" || valid_ipv6 "$VENC_ADDR" || valid_domain "$VENC_ADDR" && break; warn "地址无效"
  done
  local tmp
  ask tmp "认证密钥类型 1) x25519（默认，短） 2) mlkem768（抗量子，客户端串很长）" "$(case "$VENC_AUTH" in mlkem768) echo 2;; *) echo 1;; esac)"
  case "$tmp" in 2) VENC_AUTH=mlkem768;; *) VENC_AUTH=x25519;; esac
  ask VENC_NODE "节点名称" "$VENC_NODE"; valid_name "$VENC_NODE" || VENC_NODE="VLESS-ENC"
  confirm "拦截回国流量 geoip:cn？" "$([ "$VENC_BLOCK_CN" = yes ] && echo y || echo n)" && VENC_BLOCK_CN=yes || VENC_BLOCK_CN=no
  confirm "开始部署 VLESS Encryption（端口 ${VENC_PORT}）？" y || return 0

  install_xray || return 1
  [ -z "$VENC_UUID" ] && VENC_UUID="$(gen_uuid)"
  venc_keygen || { err "生成密钥失败"; return 1; }
  venc_gen_config || { err "生成配置失败"; return 1; }
  if ! "$XRAY_BIN" run -test -c "$VENC_CONF" >/dev/null 2>&1; then
    err "配置测试失败："; "$XRAY_BIN" run -test -c "$VENC_CONF" 2>&1 | tail -3; return 1
  fi
  venc_write_service
  venc_save
  systemctl enable "$VENC_SVC" >/dev/null 2>&1
  systemctl restart "$VENC_SVC" || { err "启动失败: journalctl -u $VENC_SVC -n 30"; return 1; }
  sleep 1
  systemctl is-active --quiet "$VENC_SVC" || { err "未运行: journalctl -u $VENC_SVC -n 30"; return 1; }
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${VENC_PORT}/tcp" >/dev/null && ok "UFW 已放行 ${VENC_PORT}/tcp"
  fi
  ok "VLESS Encryption 已部署，监听 0.0.0.0:${VENC_PORT}"
  venc_show
}

venc_remove() {
  venc_load || { warn "未部署 VLESS Encryption"; return 0; }
  confirm "删除 VLESS Encryption 节点（不影响 Reality / mieru）？" n || return 0
  systemctl disable --now "$VENC_SVC" >/dev/null 2>&1
  rm -f "/etc/systemd/system/${VENC_SVC}.service"; systemctl daemon-reload
  rm -rf "$VENC_DIR" "$VENC_STATE" "${RSITE_DIR}/venc-link.txt"
  ok "已删除 VLESS Encryption"
}

# ---------------------------------------------------------------- mieru
MIERU_SKEYS="MIERU_PORT MIERU_USER MIERU_PASS MIERU_MTU MIERU_ADDR MIERU_TP MIERU_TP_B64"
mieru_defaults() { MIERU_PORT="2444"; MIERU_USER=""; MIERU_PASS=""; MIERU_MTU="1400"; MIERU_ADDR=""; MIERU_TP="conservative"; MIERU_TP_B64=""; }
mieru_load() {
  mieru_defaults; [ -f "$MIERU_STATE" ] || return 1
  local k v
  while IFS='=' read -r k v; do
    case " $MIERU_SKEYS " in *" $k "*) ;; *) continue ;; esac
    v="${v#\'}"; v="${v%\'}"; printf -v "$k" '%s' "$v"
  done <"$MIERU_STATE"; return 0
}
mieru_save() {
  mkdir -p "$RSITE_DIR" && chmod 700 "$RSITE_DIR"
  local k tmp="${MIERU_STATE}.tmp"; : >"$tmp" && chmod 600 "$tmp"
  for k in $MIERU_SKEYS; do printf "%s='%s'\n" "$k" "${!k}" >>"$tmp"; done
  mv -f "$tmp" "$MIERU_STATE"
}
mieru_deployed() { [ -f "$MIERU_STATE" ] && [ -x "$MITA_BIN" ]; }

mieru_arch() { case "$(uname -m)" in x86_64|amd64) printf amd64 ;; aarch64|arm64) printf arm64 ;; *) return 1 ;; esac; }
mieru_latest_ver() {
  local v
  v="$(curl -fsSL --max-time 15 "https://api.github.com/repos/${MIERU_REPO}/releases/latest" 2>/dev/null \
      | grep -oE '"tag_name"[^,]*' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  [ -n "$v" ] || v="3.36.0"
  printf '%s' "$v"
}
mieru_install_bin() {
  if [ -x "$MITA_BIN" ] && [ "${1:-}" != upgrade ]; then
    ok "mita 已安装: $("$MITA_BIN" version 2>/dev/null | head -n1)"; return 0
  fi
  local arch ver url tmp
  arch="$(mieru_arch)" || { err "不支持的架构: $(uname -m)"; return 1; }
  ver="$(mieru_latest_ver)"
  url="https://github.com/${MIERU_REPO}/releases/download/v${ver}/mita_${ver}_linux_${arch}.tar.gz"
  info "下载 mita v${ver}（${arch}）"
  tmp="$(mktemp -d)"
  if ! curl -fsSL --max-time 120 "$url" -o "$tmp/m.tgz"; then err "下载失败: $url"; rm -rf "$tmp"; return 1; fi
  tar xzf "$tmp/m.tgz" -C "$tmp" 2>/dev/null || { err "解压失败"; rm -rf "$tmp"; return 1; }
  local b; b="$(find "$tmp" -type f -name mita | head -n1)"
  [ -n "$b" ] || { err "包内未找到 mita"; rm -rf "$tmp"; return 1; }
  install -m 0755 "$b" "$MITA_BIN"; rm -rf "$tmp"
  [ -x "$MITA_BIN" ] && ok "mita: $("$MITA_BIN" version 2>/dev/null | head -n1)"
}

# 流量伪装（trafficPattern）需要 mita >= 3.28.0
mieru_tp_supported() {
  local v; v="$("$MITA_BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  [ -n "$v" ] || return 1
  [ "$(printf '%s\n%s\n' 3.28.0 "$v" | sort -V | head -n1)" = 3.28.0 ]
}

# 两档 trafficPattern JSON（与 NoBrand 一致）；off 返回非 0
mieru_tp_object() {
  case "$1" in
    conservative) printf '%s' '{"seed":0,"unlockAll":false,"nonce":{"type":"NONCE_TYPE_PRINTABLE","applyToAllUDPPacket":true,"minLen":4,"maxLen":8},"padding":{"maxMiddlePaddingLen":0,"maxEndPaddingLen":128}}' ;;
    aggressive)   printf '%s' '{"seed":0,"unlockAll":false,"tcpFragment":{"enable":true,"maxSleepMs":8},"nonce":{"type":"NONCE_TYPE_PRINTABLE","applyToAllUDPPacket":true,"minLen":6,"maxLen":12},"padding":{"maxMiddlePaddingLen":64,"maxEndPaddingLen":255}}' ;;
    *) return 1 ;;
  esac
}

mieru_gen_config() {
  mkdir -p "$MIERU_DIR" && chmod 700 "$MIERU_DIR"
  local tp_arg='null'
  if [ "${MIERU_TP:-off}" != off ]; then
    if mieru_tp_supported; then
      tp_arg="$(mieru_tp_object "$MIERU_TP")" || tp_arg='null'
    else
      warn "当前 mita 版本不支持流量伪装（需 ≥3.28.0），本次跳过；升级 mita 后重新部署可启用"
      tp_arg='null'; MIERU_TP=off
    fi
  fi
  jq -n --argjson port "$MIERU_PORT" --arg user "$MIERU_USER" --arg pass "$MIERU_PASS" \
     --argjson mtu "$MIERU_MTU" --argjson tp "$tp_arg" '
  {portBindings:[{port:$port,protocol:"TCP"}],
   users:[{name:$user,password:$pass}],
   loggingLevel:"INFO", mtu:$mtu}
   + (if $tp==null then {} else {trafficPattern:$tp} end)' >"${MIERU_CONF}.tmp" || return 1
  mv -f "${MIERU_CONF}.tmp" "$MIERU_CONF"; chmod 600 "$MIERU_CONF"
}

mieru_write_service() {
  cat >/etc/systemd/system/${MIERU_SVC}.service <<EOF
[Unit]
Description=Mieru mita server (rsite)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=MITA_CONFIG_JSON_FILE=${MIERU_CONF}
Environment=MITA_UDS_PATH=${MIERU_UDS}
Environment=MITA_INSECURE_UDS=1
StateDirectory=mita
ExecStart=${MITA_BIN} run
ExecStartPost=/bin/sh -c 'for i in \$(seq 1 40); do [ -S "\$MITA_UDS_PATH" ] && break; sleep 0.25; done; "${MITA_BIN}" apply config "\$MITA_CONFIG_JSON_FILE" >/dev/null 2>&1 || true; "${MITA_BIN}" start >/dev/null 2>&1 || true'
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

mieru_link() {
  local tp=""
  [ -n "${MIERU_TP_B64:-}" ] && tp="&traffic-pattern=$(urlenc "$MIERU_TP_B64")"
  printf 'mierus://%s:%s@%s?handshake-mode=HANDSHAKE_NO_WAIT&mtu=%s&multiplexing=MULTIPLEXING_OFF&port=%s&profile=default&protocol=TCP%s' \
    "$(urlenc "$MIERU_USER")" "$(urlenc "$MIERU_PASS")" "$(link_host "$MIERU_ADDR")" "$MIERU_MTU" "$MIERU_PORT" "$tp"
}

mieru_client_json() {
  local tp='null'
  [ "${MIERU_TP:-off}" != off ] && tp="$(mieru_tp_object "$MIERU_TP" 2>/dev/null || echo null)"
  jq -n --arg u "$MIERU_USER" --arg p "$MIERU_PASS" --arg h "$MIERU_ADDR" \
     --argjson port "$MIERU_PORT" --argjson mtu "$MIERU_MTU" --argjson tp "$tp" '
  {profiles:[({profileName:"default",
     user:{name:$u,password:$p},
     servers:[{ipAddress:$h,portBindings:[{port:$port,protocol:"TCP"}]}],
     mtu:$mtu} + (if $tp==null then {} else {trafficPattern:$tp} end))],
   activeProfile:"default", rpcPort:8964, socks5Port:1080, loggingLevel:"INFO"}'
}

mieru_show() {
  mieru_load || { warn "尚未部署 mieru"; return 1; }
  local link; link="$(mieru_link)"
  title "mieru 节点"
  local tplabel; case "${MIERU_TP:-off}" in off) tplabel="关闭";; aggressive) tplabel="激进";; *) tplabel="保守";; esac
  kv "连接地址" "$MIERU_ADDR" "端口" "$MIERU_PORT" "协议" "TCP" "用户名" "$MIERU_USER" "MTU" "$MIERU_MTU" "流量伪装" "$tplabel"
  line
  msg "${C_W}mierus:// 分享链接：${C_0}"; msg "${C_G}${link}${C_0}"
  line
  command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 -m 1 "$link"
  line
  msg "${C_W}mieru 客户端 JSON（在电脑/手机 mieru 客户端导入，勿在服务器 mita apply）：${C_0}"
  mieru_client_json
  ( umask 077; printf '%s\n' "$link" >"${RSITE_DIR}/mieru-link.txt" )
  msg ""
  msg "密码（含在链接中，请妥善保存）：${C_Y}${MIERU_PASS}${C_0}"
}

mieru_deploy() {
  mieru_load || true
  title "部署 mieru"
  [ -z "$MIERU_ADDR" ] && { state_load 2>/dev/null; MIERU_ADDR="${CONNECT_ADDR:-${SERVER_IP:-$(detect_ip || true)}}"; }
  while :; do ask MIERU_PORT "对外端口（TCP）" "$MIERU_PORT"; valid_port "$MIERU_PORT" && break; warn "端口无效"; done
  while :; do
    ask MIERU_ADDR "客户端连接地址（IP 或域名）" "$MIERU_ADDR"
    valid_ipv4 "$MIERU_ADDR" || valid_ipv6 "$MIERU_ADDR" || valid_domain "$MIERU_ADDR" && break; warn "地址无效"
  done
  ask MIERU_USER "用户名" "${MIERU_USER:-mieru}"; [ -n "$MIERU_USER" ] || MIERU_USER=mieru
  local defpass="${MIERU_PASS:-$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)}"
  ask MIERU_PASS "密码（回车用随机）" "$defpass"; [ -n "$MIERU_PASS" ] || MIERU_PASS="$defpass"
  while :; do ask MIERU_MTU "MTU" "$MIERU_MTU"; [[ "$MIERU_MTU" =~ ^[0-9]+$ ]] && [ "$MIERU_MTU" -ge 1280 ] && [ "$MIERU_MTU" -le 1500 ] && break; warn "MTU 取值 1280-1500"; done
  local tp_in
  msg "流量伪装（降低流量特征，需 mita ≥3.28.0）: 0) 关闭  1) 保守(推荐，开销低)  2) 激进(更隐蔽但略慢)"
  ask tp_in "选择" "$(case "${MIERU_TP:-conservative}" in off) echo 0;; aggressive) echo 2;; *) echo 1;; esac)"
  case "$tp_in" in 0) MIERU_TP=off;; 2) MIERU_TP=aggressive;; *) MIERU_TP=conservative;; esac
  confirm "开始部署 mieru（端口 ${MIERU_PORT}/TCP，流量伪装: ${MIERU_TP}）？" y || return 0

  mieru_install_bin || return 1
  mieru_gen_config || { err "生成配置失败"; return 1; }
  mieru_write_service
  mieru_save
  systemctl enable "$MIERU_SVC" >/dev/null 2>&1
  systemctl restart "$MIERU_SVC" || { err "启动失败: journalctl -u $MIERU_SVC -n 30"; return 1; }
  # 等待 socket 与 RUNNING
  local i=0 st=""
  while [ "$i" -lt 20 ]; do [ -S "$MIERU_UDS" ] && break; sleep 0.5; i=$((i+1)); done
  i=0
  while [ "$i" -lt 20 ]; do
    st="$(MITA_CONFIG_JSON_FILE="$MIERU_CONF" MITA_UDS_PATH="$MIERU_UDS" MITA_INSECURE_UDS=1 "$MITA_BIN" status 2>/dev/null || true)"
    printf '%s' "$st" | grep -q 'RUNNING' && break; sleep 0.5; i=$((i+1))
  done
  if ! printf '%s' "$st" | grep -q 'RUNNING'; then
    err "mita 未进入 RUNNING，查看: journalctl -u $MIERU_SVC -n 40"; return 1
  fi
  # 导出流量伪装编码，供客户端链接使用
  MIERU_TP_B64=""
  if [ "${MIERU_TP:-off}" != off ]; then
    MIERU_TP_B64="$(MITA_CONFIG_JSON_FILE="$MIERU_CONF" MITA_UDS_PATH="$MIERU_UDS" MITA_INSECURE_UDS=1 \
      "$MITA_BIN" export traffic-pattern 2>/dev/null | tr -d '[:space:]')"
    mieru_save
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${MIERU_PORT}/tcp" >/dev/null && ok "UFW 已放行 ${MIERU_PORT}/tcp"
  fi
  ok "mieru 已部署并 RUNNING，监听 0.0.0.0:${MIERU_PORT}/TCP"
  mieru_show
}

mieru_remove() {
  mieru_load || { warn "未部署 mieru"; return 0; }
  confirm "删除 mieru 节点（不影响 Reality / VLESS Encryption）？" n || return 0
  systemctl disable --now "$MIERU_SVC" >/dev/null 2>&1
  rm -f "/etc/systemd/system/${MIERU_SVC}.service"; systemctl daemon-reload
  rm -rf "$MIERU_DIR" "$MIERU_STATE" "${RSITE_DIR}/mieru-link.txt"
  confirm "同时卸载 mita 程序（${MITA_BIN}）？" n && rm -f "$MITA_BIN"
  ok "已删除 mieru"
}

# =============================================================================
#  MASQUE（HTTP/3 CONNECT-IP，RFC 9484）
#  服务端: Vincent-bin/masque-server（Rust），同一进程可同时开两种认证的监听：
#    · WARP 模式: TLS 双向认证（mTLS），客户端 ECDSA P-256 公私钥对、服务端公钥固定
#                 —— 与 Cloudflare WARP 的 MASQUE 规范一致（mihomo masque / usque 等）
#    · RFC  模式: HTTP Basic 账号密码（RFC 9484 / 9298 通用客户端：Surge、Xray masque 出站等）
#  HTTP/3 走 UDP，与 Reality（TCP）可共用 443 端口号
# =============================================================================
MQ_REPO="Vincent-bin/masque-server"
MQ_FALLBACK_VER="0.13.0"
MQ_BIN="/usr/local/bin/masque-server"
MQ_PROBE_BIN="/usr/local/bin/masque-probe"
MQ_ETC="/etc/masque"
MQ_CONF="${MQ_ETC}/masque.toml"
MQ_CERTS="${MQ_ETC}/certs"
MQ_SVC="masque"
MQ_NAT_SVC="rsite-masque-nat"
MQ_STATE="${RSITE_DIR}/masque.env"
MQ_CLI_DIR="${RSITE_DIR}/masque-clients"
MQ_SELF_DIR="${RSITE_DIR}/masque-selfsigned"
MQ_TUN="masque0"
MQ_TAG="rsite-masque"

MQ_KEYS="MQ_WARP MQ_WARP_PORT MQ_WARP_H2 MQ_RFC MQ_RFC_PORT MQ_RFC_H2 MQ_RFC_USER MQ_RFC_PASS MQ_RFC_HASH MQ_RFC_STEALTH MQ_ADDR MQ_HOST MQ_CERT_SRC MQ_POOL4 MQ_POOL6 MQ_V6 MQ_MTU MQ_SRV_PUB MQ_BLOCK_PRIV MQ_OFFLOAD"
mq_defaults() {
  MQ_WARP=no; MQ_WARP_PORT=""; MQ_WARP_H2=""
  MQ_RFC=no; MQ_RFC_PORT=""; MQ_RFC_H2=""; MQ_RFC_USER="masque"; MQ_RFC_PASS=""; MQ_RFC_HASH=""; MQ_RFC_STEALTH=no
  MQ_ADDR=""; MQ_HOST=""; MQ_CERT_SRC=""; MQ_POOL4=""; MQ_POOL6=""; MQ_V6=no; MQ_MTU=1280
  MQ_SRV_PUB=""; MQ_BLOCK_PRIV=yes; MQ_OFFLOAD=yes
}
mq_load() {
  mq_defaults; [ -f "$MQ_STATE" ] || return 1
  local k v
  while IFS='=' read -r k v; do
    case " $MQ_KEYS " in *" $k "*) ;; *) continue ;; esac
    v="${v#\'}"; v="${v%\'}"; printf -v "$k" '%s' "$v"
  done <"$MQ_STATE"; return 0
}
mq_save() {
  mkdir -p "$RSITE_DIR" && chmod 700 "$RSITE_DIR"
  local k tmp="${MQ_STATE}.tmp"; : >"$tmp" && chmod 600 "$tmp"
  for k in $MQ_KEYS; do printf "%s='%s'\n" "$k" "${!k}" >>"$tmp"; done
  mv -f "$tmp" "$MQ_STATE"
}
mq_any() { [ "$MQ_WARP" = yes ] || [ "$MQ_RFC" = yes ]; }
mq_deployed() { [ -f "$MQ_STATE" ] && [ -x "$MQ_BIN" ] && [ -f "$MQ_CONF" ]; }
mq_ver_now() { [ -x "$MQ_BIN" ] && "$MQ_BIN" --version 2>/dev/null | awk '{print $NF}'; }
mq_arch() { case "$(uname -m)" in x86_64|amd64) printf x86_64 ;; aarch64|arm64) printf aarch64 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------- 安装 / 升级
mq_write_unit() { # 发行包里没有 unit 时的兜底（与上游一致的最小权限）
  cat >/etc/systemd/system/${MQ_SVC}.service <<EOF
[Unit]
Description=MASQUE HTTP/2 and HTTP/3 proxy server
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
NotifyAccess=main
WatchdogSec=30s
User=masque
Group=masque
ExecStart=${MQ_BIN} --config ${MQ_CONF}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=2s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
StateDirectory=masque

[Install]
WantedBy=multi-user.target
EOF
}

# mq_install_bin [upgrade]  —— 下载官方发行包并校验 SHA-256；升级前用新版本检查现有配置，失败自动回滚
mq_install_bin() {
  if [ -x "$MQ_BIN" ] && [ "${1:-}" != upgrade ]; then ok "masque-server 已安装: $(mq_ver_now)"; return 0; fi
  [ "${1:-}" = upgrade ] && [ ! -x "$MQ_BIN" ] && { warn "尚未安装 masque-server（在「其他协议」里部署 MASQUE 时会自动安装）"; return 0; }
  local arch ver old name base tmp exp act dir
  arch="$(mq_arch)" || { err "masque-server 只提供 x86_64 / arm64 版本"; return 1; }
  apt_install curl jq tar openssl >/dev/null || return 1
  ver="${MASQUE_VERSION:-$(gh_latest_tag "$MQ_REPO")}"; ver="${ver#v}"; [ -n "$ver" ] || ver="$MQ_FALLBACK_VER"
  old="$(mq_ver_now)"
  if [ "${1:-}" = upgrade ] && [ "$old" = "$ver" ]; then ok "masque-server 已是最新（${ver}）"; return 0; fi
  name="masque-v${ver}-linux-${arch}.tar.gz"
  base="https://github.com/${MQ_REPO}/releases/download/v${ver}"
  tmp="$(mktemp -d)"
  info "下载 masque-server v${ver}（${arch}）"
  if ! curl -fsSL --max-time 180 "$base/$name" -o "$tmp/$name" || ! curl -fsSL --max-time 30 "$base/$name.sha256" -o "$tmp/sum"; then
    err "下载失败: $base/$name"; rm -rf "$tmp"; return 1
  fi
  exp="$(grep -oE '[0-9a-fA-F]{64}' "$tmp/sum" | head -n1 | tr 'A-F' 'a-f')"
  act="$(sha256sum "$tmp/$name" | awk '{print $1}')"
  if [ -z "$exp" ] || [ "$exp" != "$act" ]; then err "SHA-256 校验失败，已中止"; rm -rf "$tmp"; return 1; fi
  tar xzf "$tmp/$name" -C "$tmp" 2>/dev/null || { err "解压失败"; rm -rf "$tmp"; return 1; }
  dir="$(find "$tmp" -type f -path '*/bin/masque-server' | head -n1)"; dir="${dir%/bin/masque-server}"
  [ -n "$dir" ] && [ -f "$dir/bin/masque-server" ] || { err "发行包内未找到 masque-server"; rm -rf "$tmp"; return 1; }
  chmod 755 "$dir/bin/masque-server"
  if [ -s "$MQ_CONF" ] && ! "$dir/bin/masque-server" --config "$MQ_CONF" check-config >/dev/null 2>&1; then
    err "新版本无法通过现有配置检查，已中止（未改动任何文件）："
    "$dir/bin/masque-server" --config "$MQ_CONF" check-config 2>&1 | tail -n 5
    rm -rf "$tmp"; return 1
  fi
  getent group masque >/dev/null 2>&1 || groupadd --system masque
  id masque >/dev/null 2>&1 || useradd --system --gid masque --home-dir /var/lib/masque \
    --no-create-home --shell /usr/sbin/nologin masque
  mkdir -p "$RSITE_BACKUP"
  [ -x "$MQ_BIN" ] && cp -f "$MQ_BIN" "$RSITE_BACKUP/masque-server.prev"
  install -m 0755 "$dir/bin/masque-server" "$MQ_BIN"
  [ -f "$dir/bin/masque-probe" ] && install -m 0755 "$dir/bin/masque-probe" "$MQ_PROBE_BIN"
  if [ -s "$dir/systemd/masque.service" ]; then
    install -m 0644 "$dir/systemd/masque.service" "/etc/systemd/system/${MQ_SVC}.service"
  else
    mq_write_unit
  fi
  install -d -m 0755 "$MQ_ETC"; install -d -o root -g masque -m 0750 "$MQ_CERTS"
  systemctl daemon-reload
  rm -rf "$tmp"
  if systemctl is-active --quiet "$MQ_SVC"; then
    systemctl restart "$MQ_SVC"; sleep 2
    if ! systemctl is-active --quiet "$MQ_SVC" && [ -s "$RSITE_BACKUP/masque-server.prev" ]; then
      err "新版本启动失败，已回滚旧版本（journalctl -u $MQ_SVC -n 30）"
      install -m 0755 "$RSITE_BACKUP/masque-server.prev" "$MQ_BIN"; systemctl restart "$MQ_SVC"; return 1
    fi
  fi
  ok "masque-server: ${old:-无} → $(mq_ver_now)"
}

# ---------------------------------------------------------------- 证书
# 服务端证书必须是 ECDSA：WARP 风格客户端固定（pin）的就是它的公钥
mq_copy_cert() { # mq_copy_cert 源证书 源私钥
  [ -s "$1" ] && [ -s "$2" ] || { err "证书文件不存在: $1"; return 1; }
  openssl x509 -in "$1" -noout -text 2>/dev/null | grep -q 'id-ecPublicKey' \
    || { err "证书不是 ECDSA 密钥，WARP 模式客户端无法固定公钥"; return 1; }
  install -d -o root -g masque -m 0750 "$MQ_CERTS"
  install -o root -g masque -m 0640 "$1" "$MQ_CERTS/server.crt"
  install -o root -g masque -m 0640 "$2" "$MQ_CERTS/server.key"
  MQ_SRV_PUB="$(openssl x509 -in "$MQ_CERTS/server.crt" -noout -pubkey | openssl pkey -pubin -outform DER 2>/dev/null | base64 -w0)"
  [ -n "$MQ_SRV_PUB" ]
}

mq_prepare_cert() {
  case "$MQ_CERT_SRC" in
    domain)
      state_load && cert_ok || { err "Reality 站点证书不可用，请改用自签证书"; return 1; }
      mq_copy_cert "$(cert_dir)/cert.pem" "$(cert_dir)/key.pem" || return 1
      # 让 acme.sh 续签后自动同步给 MASQUE（acme.sh 默认续签复用私钥，公钥不变）
      [ -x "$ACME" ] && acme_install_cert >/dev/null 2>&1 || true ;;
    *)
      local san="IP:${MQ_ADDR}"
      valid_domain "$MQ_ADDR" && san="DNS:${MQ_ADDR}"
      if [ ! -s "$MQ_SELF_DIR/cert.pem" ]; then
        mkdir -p "$MQ_SELF_DIR" && chmod 700 "$MQ_SELF_DIR"
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
          -subj "/CN=${MQ_HOST:-masque}" -addext "subjectAltName=${san}" \
          -keyout "$MQ_SELF_DIR/key.pem" -out "$MQ_SELF_DIR/cert.pem" >/dev/null 2>&1 \
          || { err "生成自签证书失败"; return 1; }
        chmod 600 "$MQ_SELF_DIR/key.pem"
      fi
      mq_copy_cert "$MQ_SELF_DIR/cert.pem" "$MQ_SELF_DIR/key.pem" || return 1 ;;
  esac
}

mq_cert_sha256() { openssl x509 -in "$MQ_CERTS/server.crt" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'; }

# acme.sh 续签后调用（rsite cert-hook）：重载 nginx；MASQUE 使用站点证书时同步并重载
cert_hook() {
  systemctl reload nginx 2>/dev/null || true
  mq_load 2>/dev/null && mq_any && [ "$MQ_CERT_SRC" = domain ] || return 0
  state_load || return 0
  local old="$MQ_SRV_PUB"
  mq_copy_cert "$(cert_dir)/cert.pem" "$(cert_dir)/key.pem" || return 1
  if [ "$MQ_SRV_PUB" != "$old" ]; then
    mq_save
    logger -t rsite "MASQUE 服务端公钥已变化：WARP 模式客户端需重新导入配置（rl → 其他协议 → 查看 MASQUE）" 2>/dev/null || true
  fi
  systemctl reload "$MQ_SVC" 2>/dev/null || true
}

# ---------------------------------------------------------------- WARP 客户端（ECDSA P-256 密钥对）
C_KEYS="C_NAME C_IDX C_PRIV C_PUB"
mq_client_load() { # mq_client_load 文件
  C_NAME=""; C_IDX=""; C_PRIV=""; C_PUB=""
  local k v
  while IFS='=' read -r k v; do
    case " $C_KEYS " in *" $k "*) ;; *) continue ;; esac
    v="${v#\'}"; v="${v%\'}"; printf -v "$k" '%s' "$v"
  done <"$1"
  [ -n "$C_NAME" ] && [ -n "$C_PUB" ]
}
mq_client_files() { ls "$MQ_CLI_DIR"/*.env 2>/dev/null; }
mq_client_count() { mq_client_files | grep -c . ; }
mq_client_ip4() { local b="${MQ_POOL4%%.0.0/16}" n=$(( $1 + 2 )); printf '%s.%d.%d' "$b" $(( n / 256 )) $(( n % 256 )); }
mq_client_ip6() { printf '%s::%x' "${MQ_POOL6%%::/64}" $(( $1 + 2 )); }
valid_cname() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; }

# mq_client_new 名称  —— 本机 openssl 生成密钥：私钥 SEC1 DER / 公钥 SPKI DER（base64），与 WARP 客户端格式一致
mq_client_new() {
  local name="$1" f idx=0 i tmp
  valid_cname "$name" || { err "客户端名只能用字母数字 _ -（≤32）"; return 1; }
  mkdir -p "$MQ_CLI_DIR" && chmod 700 "$MQ_CLI_DIR"
  [ -e "$MQ_CLI_DIR/$name.env" ] && { err "客户端 ${name} 已存在"; return 1; }
  for f in $(mq_client_files); do
    mq_client_load "$f" && [ "${C_IDX:-0}" -ge "$idx" ] && idx=$(( C_IDX + 1 ))
  done
  tmp="$(mktemp -d)"; chmod 700 "$tmp"
  openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/k.pem" 2>/dev/null || { rm -rf "$tmp"; err "生成密钥失败"; return 1; }
  C_PRIV="$(openssl ec -in "$tmp/k.pem" -outform DER 2>/dev/null | base64 -w0)"
  C_PUB="$(openssl ec -in "$tmp/k.pem" -pubout -outform DER 2>/dev/null | base64 -w0)"
  rm -rf "$tmp"
  [ -n "$C_PRIV" ] && [ -n "$C_PUB" ] || { err "导出密钥失败"; return 1; }
  C_NAME="$name"; C_IDX="$idx"
  ( umask 077; : >"$MQ_CLI_DIR/$name.env"; for i in $C_KEYS; do printf "%s='%s'\n" "$i" "${!i}" >>"$MQ_CLI_DIR/$name.env"; done )
  ok "已生成 WARP 客户端「${name}」的 ECDSA P-256 密钥对（隧道地址 $(mq_client_ip4 "$idx")）"
}

# ---------------------------------------------------------------- 配置生成
mq_listener_toml() { # 端口 http3|http2 client_cert|basic
  printf '\n[[listeners]]\nlisten_addr = "0.0.0.0:%s"\ntransport = "%s"\nshards = 1\n\n[listeners.auth]\nenabled = true\nmode = "%s"\n' "$1" "$2" "$3"
  if [ "$3" = basic ]; then
    printf 'stealth = %s\n\n[[listeners.auth.users]]\nusername = "%s"\npassword_hash = "%s"\n' \
      "$([ "$MQ_RFC_STEALTH" = yes ] && echo true || echo false)" "$MQ_RFC_USER" "$MQ_RFC_HASH"
  fi
}

mq_gen_conf() {
  local f deny='[
    "127.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "169.254.0.0/16", "172.16.0.0/12",
    "192.168.0.0/16", "::1/128", "fc00::/7", "fe80::/10",
]'
  cat <<EOF
# 由 rsite 生成 —— 在 rsite 菜单里修改 MASQUE 会覆盖本文件
[server]
idle_timeout_secs = 60
max_connections = 10000
max_connections_per_ip = 64
max_pending_auth_per_ip = 8
max_tunnels_per_connection = 100

[tls]
cert_path = "${MQ_CERTS}/server.crt"
key_path = "${MQ_CERTS}/server.key"
EOF
  if [ "$MQ_WARP" = yes ]; then
    printf '\n# ---- WARP 模式：mTLS（ECDSA P-256 客户端公钥白名单）\n'
    mq_listener_toml "$MQ_WARP_PORT" http3 client_cert
    [ -n "$MQ_WARP_H2" ] && mq_listener_toml "$MQ_WARP_H2" http2 client_cert
  fi
  if [ "$MQ_RFC" = yes ]; then
    printf '\n# ---- RFC 模式：HTTP Basic 账号密码\n'
    mq_listener_toml "$MQ_RFC_PORT" http3 basic
    [ -n "$MQ_RFC_H2" ] && mq_listener_toml "$MQ_RFC_H2" http2 basic
  fi
  if [ "$MQ_WARP" = yes ]; then
    for f in $(mq_client_files); do
      mq_client_load "$f" || continue
      printf '\n[[clients]]\nname = "%s"\npublic_key = "%s"\nipv4 = "%s"\n' "$C_NAME" "$C_PUB" "$(mq_client_ip4 "$C_IDX")"
      [ "$MQ_V6" = yes ] && printf 'ipv6 = "%s"\n' "$(mq_client_ip6 "$C_IDX")"
    done
  fi
  cat <<EOF

[tcp_proxy]
enabled = true
connect_timeout_secs = 10
allow_targets = ["0.0.0.0/0", "::/0"]
deny_targets = ${deny}

[udp_proxy]
enabled = true
connect_timeout_secs = 10
uri_template = "/.well-known/masque/udp/{target_host}/{target_port}/"
allow_targets = ["0.0.0.0/0", "::/0"]
deny_targets = ${deny}

[ip_proxy]
enabled = true
uri_template = "/.well-known/masque/ip/{target}/{ipproto}/"
connect_protocols = ["connect-ip", "cf-connect-ip"]
tun_name = "${MQ_TUN}"
tun_mtu = ${MQ_MTU}
tun_offload = $([ "$MQ_OFFLOAD" = yes ] && echo true || echo false)
ipv4_pool = "${MQ_POOL4}"
ipv6_pool = "${MQ_POOL6}"
EOF
}

# 选一个与本机路由不重叠的隧道地址池
mq_pick_pool() {
  local b used
  used="$(ip -4 route 2>/dev/null; ip -4 addr 2>/dev/null)"
  if [ -z "$MQ_POOL4" ]; then
    for b in 10.89 10.98 10.123 10.211 172.29; do
      grep -qE "(^|[^0-9])${b//./\\.}\." <<<"$used" || { MQ_POOL4="${b}.0.0/16"; break; }
    done
    [ -n "$MQ_POOL4" ] || MQ_POOL4="10.89.0.0/16"
  fi
  if [ -z "$MQ_POOL6" ]; then
    used="$(ip -6 route 2>/dev/null; ip -6 addr 2>/dev/null)"
    for b in fd00:abcd fd00:a5e9 fd5e:9a1c; do
      grep -qi "$b:" <<<"$used" || { MQ_POOL6="${b}::/64"; break; }
    done
    [ -n "$MQ_POOL6" ] || MQ_POOL6="fd00:abcd::/64"
  fi
}

# ---------------------------------------------------------------- 转发 / NAT（CONNECT-IP 需要）
mq_nat_flush() {
  local ipt t r a
  for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    for t in nat filter mangle; do
      "$ipt" -t "$t" -S 2>/dev/null | grep -- "--comment ${MQ_TAG}" | sed 's/^-A /-D /' | while read -r r; do
        read -ra a <<<"$r"; "$ipt" -t "$t" "${a[@]}" 2>/dev/null
      done
    done
  done
}

mq_nat() { # mq_nat up|down
  mq_nat_flush
  [ "$1" = up ] || return 0
  mq_load && mq_any || return 0
  local c=(-m comment --comment "$MQ_TAG") n iface
  sysctl -qw net.ipv4.ip_forward=1
  iptables -t nat -A POSTROUTING -s "$MQ_POOL4" ! -o "$MQ_TUN" "${c[@]}" -j MASQUERADE
  iptables -I FORWARD 1 -i "$MQ_TUN" "${c[@]}" -j ACCEPT
  iptables -I FORWARD 1 -o "$MQ_TUN" -m conntrack --ctstate RELATED,ESTABLISHED "${c[@]}" -j ACCEPT
  if [ "$MQ_BLOCK_PRIV" = yes ]; then
    for n in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 127.0.0.0/8; do
      iptables -I FORWARD 1 -i "$MQ_TUN" -d "$n" "${c[@]}" -j DROP
    done
  fi
  iptables -t mangle -A FORWARD -i "$MQ_TUN" -p tcp --tcp-flags SYN,RST SYN "${c[@]}" -j TCPMSS --clamp-mss-to-pmtu
  iptables -t mangle -A FORWARD -o "$MQ_TUN" -p tcp --tcp-flags SYN,RST SYN "${c[@]}" -j TCPMSS --clamp-mss-to-pmtu
  if [ "$MQ_V6" = yes ] && command -v ip6tables >/dev/null 2>&1; then
    # 开启 IPv6 转发会让内核忽略 RA，先把出口网卡设为 accept_ra=2，避免 VPS 丢失 IPv6 默认路由
    iface="$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    [ -n "$iface" ] && sysctl -qw "net.ipv6.conf.${iface}.accept_ra=2" 2>/dev/null
    sysctl -qw net.ipv6.conf.all.forwarding=1
    ip6tables -t nat -A POSTROUTING -s "$MQ_POOL6" ! -o "$MQ_TUN" "${c[@]}" -j MASQUERADE 2>/dev/null \
      || warn "内核不支持 ip6tables NAT，隧道内 IPv6 不可用"
    ip6tables -I FORWARD 1 -i "$MQ_TUN" "${c[@]}" -j ACCEPT
    ip6tables -I FORWARD 1 -o "$MQ_TUN" -m conntrack --ctstate RELATED,ESTABLISHED "${c[@]}" -j ACCEPT
    if [ "$MQ_BLOCK_PRIV" = yes ]; then
      for n in fc00::/7 fe80::/10 ::1/128; do ip6tables -I FORWARD 1 -i "$MQ_TUN" -d "$n" "${c[@]}" -j DROP; done
    fi
    ip6tables -t mangle -A FORWARD -i "$MQ_TUN" -p tcp --tcp-flags SYN,RST SYN "${c[@]}" -j TCPMSS --clamp-mss-to-pmtu
    ip6tables -t mangle -A FORWARD -o "$MQ_TUN" -p tcp --tcp-flags SYN,RST SYN "${c[@]}" -j TCPMSS --clamp-mss-to-pmtu
  fi
  return 0
}

mq_write_nat_unit() {
  cat >/etc/systemd/system/${MQ_NAT_SVC}.service <<EOF
[Unit]
Description=rsite MASQUE forwarding / NAT
After=network-online.target
Wants=network-online.target
Before=${MQ_SVC}.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${RSITE_BIN} masque-nat up
ExecStop=${RSITE_BIN} masque-nat down

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

mq_ufw() {
  command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  local p
  if [ "$MQ_WARP" = yes ]; then ufw allow "${MQ_WARP_PORT}/udp" >/dev/null; [ -n "$MQ_WARP_H2" ] && ufw allow "${MQ_WARP_H2}/tcp" >/dev/null; fi
  if [ "$MQ_RFC" = yes ]; then ufw allow "${MQ_RFC_PORT}/udp" >/dev/null; [ -n "$MQ_RFC_H2" ] && ufw allow "${MQ_RFC_H2}/tcp" >/dev/null; fi
  p="$( { [ "$MQ_WARP" = yes ] && printf '%s/udp %s ' "$MQ_WARP_PORT" "${MQ_WARP_H2:+$MQ_WARP_H2/tcp}"; [ "$MQ_RFC" = yes ] && printf '%s/udp %s' "$MQ_RFC_PORT" "${MQ_RFC_H2:+$MQ_RFC_H2/tcp}"; } )"
  ok "UFW 已放行: ${p}"
}

# 写配置 → check-config → 重启；TUN offload 不被内核支持时自动关闭重试
mq_apply() {
  local tmp="${MQ_CONF}.rsite-new" out
  install -d -m 0755 "$MQ_ETC"
  mq_gen_conf >"$tmp" || { err "生成 MASQUE 配置失败"; return 1; }
  chown root:masque "$tmp" 2>/dev/null; chmod 0640 "$tmp"
  if ! out="$("$MQ_BIN" --config "$tmp" check-config 2>&1)"; then
    err "MASQUE 配置检查失败："; msg "$out" | tail -n 8; rm -f "$tmp"; return 1
  fi
  mkdir -p "$RSITE_BACKUP"
  [ -s "$MQ_CONF" ] && cp -f "$MQ_CONF" "$RSITE_BACKUP/masque-$(date +%Y%m%d-%H%M%S).toml"
  mv -f "$tmp" "$MQ_CONF"
  mq_write_nat_unit
  systemctl enable "$MQ_NAT_SVC" >/dev/null 2>&1; systemctl restart "$MQ_NAT_SVC" || warn "转发/NAT 规则加载失败: journalctl -u $MQ_NAT_SVC"
  systemctl enable "$MQ_SVC" >/dev/null 2>&1
  systemctl restart "$MQ_SVC"; sleep 2
  if ! systemctl is-active --quiet "$MQ_SVC" && [ "$MQ_OFFLOAD" = yes ]; then
    warn "masque 未能启动，关闭 TUN offload 后重试..."
    MQ_OFFLOAD=no; mq_save
    mq_gen_conf >"$MQ_CONF"; chown root:masque "$MQ_CONF"; chmod 0640 "$MQ_CONF"
    systemctl restart "$MQ_SVC"; sleep 2
  fi
  systemctl is-active --quiet "$MQ_SVC" || { err "masque 启动失败: journalctl -u $MQ_SVC -n 40"; return 1; }
  mq_ufw
  ok "MASQUE 服务运行中 · $(mq_listen_summary)"
}

mq_listen_summary() {
  local s=""
  [ "$MQ_WARP" = yes ] && s+="WARP(mTLS) udp/${MQ_WARP_PORT}${MQ_WARP_H2:+ + tcp/$MQ_WARP_H2(h2)}  "
  [ "$MQ_RFC" = yes ] && s+="RFC(Basic) udp/${MQ_RFC_PORT}${MQ_RFC_H2:+ + tcp/$MQ_RFC_H2(h2)}"
  printf '%s' "${s:-未启用}"
}

# ---------------------------------------------------------------- 部署前检查：端口 / 协议冲突
# 输出 rsite 自己占用/预留的端口：「端口 说明」；第二个参数是正在配置的 MASQUE 模式（排除自身）
# 在子 shell 里读取各状态文件，避免覆盖部署向导中正在填写的变量
mq_reserved() ( # mq_reserved tcp|udp warp|rfc
  proto="$1"; self="$2"
  if [ "$proto" = tcp ]; then
    if state_load && is_deployed; then
      printf '%s Reality（xray）\n%s nginx 回落（127.0.0.1）\n80 nginx（HTTP 跳转）\n' "$PORT" "$FALLBACK_PORT"
    fi
    venc_load && venc_deployed && printf '%s VLESS-Encryption\n' "$VENC_PORT"
    mieru_load && mieru_deployed && printf '%s mieru\n' "$MIERU_PORT"
    mq_load
    [ "$self" != warp ] && [ "$MQ_WARP" = yes ] && [ -n "$MQ_WARP_H2" ] && printf '%s MASQUE-WARP(h2)\n' "$MQ_WARP_H2"
    [ "$self" != rfc ] && [ "$MQ_RFC" = yes ] && [ -n "$MQ_RFC_H2" ] && printf '%s MASQUE-RFC(h2)\n' "$MQ_RFC_H2"
  else
    mq_load
    [ "$self" != warp ] && [ "$MQ_WARP" = yes ] && printf '%s MASQUE-WARP\n' "$MQ_WARP_PORT"
    [ "$self" != rfc ] && [ "$MQ_RFC" = yes ] && printf '%s MASQUE-RFC\n' "$MQ_RFC_PORT"
  fi
  return 0
)

# 端口冲突说明（空 = 无冲突）
mq_port_conflict() { # tcp|udp 端口 模式
  local proto="$1" p="$2" self="$3" rp rl o
  while read -r rp rl; do
    [ "$rp" = "$p" ] && { printf 'rsite:%s' "$rl"; return 0; }
  done < <(mq_reserved "$proto" "$self")
  if [ "$proto" = udp ]; then o="$(port_owner_udp "$p")"; else o="$(port_owner "$p")"; fi
  [ -n "$o" ] && [ "$o" != masque-server ] && printf 'proc:%s' "$o"
  return 0
}

mq_free_port() { # tcp|udp 起始端口 模式
  local p="$2" i
  for i in $(seq 1 300); do
    p=$(( p + 1 )); [ "$p" -gt 65535 ] && p=2000
    [ -z "$(mq_port_conflict "$1" "$p" "$3")" ] && { printf '%s' "$p"; return 0; }
  done
  printf '%s' "$2"
}

# mq_port_check 变量名 tcp|udp 用途 模式 —— 有冲突时给出解决方案选项
mq_port_check() {
  local __v="$1" proto="$2" what="$3" self="$4" __p __cf __alt __pid __unit __c __np __PU
  __PU="$(tr 'a-z' 'A-Z' <<<"$proto")"
  while :; do
    __p="${!__v}"
    __cf="$(mq_port_conflict "$proto" "$__p" "$self")"
    if [ -z "$__cf" ]; then ok "${what}: ${__PU} ${__p} 可用"; return 0; fi
    warn "${what}: ${__PU} ${__p} 已被「${__cf#*:}」占用"
    __alt="$(mq_free_port "$proto" "$__p" "$self")"
    __unit=""
    if [ "${__cf%%:*}" = proc ]; then __pid="$(port_pid "$proto" "$__p")"; __unit="$(pid_unit "$__pid")"; fi
    msg "  解决方案："
    msg "  1) 改用其他端口（推荐，空闲端口: ${__alt}）"
    if [ -n "$__unit" ]; then
      if [ "$__unit" = xray.service ] && state_load && is_deployed && [ "$proto" = tcp ] && [ "$__p" = "$PORT" ]; then
        msg "     （占用者是本机 Reality，不建议停止）"
        __unit=""
      else
        msg "  2) 停止并禁用占用者「${__unit}」，把端口让给 MASQUE"
      fi
    fi
    msg "  3) 忽略冲突继续（服务大概率启动失败）"
    msg "  0) 取消部署"
    ask __c "请选择" 1
    case "$__c" in
      1) while :; do ask __np "新端口" "$__alt"; valid_port "$__np" && break; warn "端口无效"; done
         printf -v "$__v" '%s' "$__np" ;;
      2) [ -n "$__unit" ] || { warn "无效选择"; continue; }
         confirm "确定停止并禁用 ${__unit}？（该服务提供的节点将失效）" n || continue
         systemctl disable --now "$__unit" >/dev/null 2>&1; sleep 1 ;;
      3) warn "已忽略 ${__PU} ${__p} 的冲突"; return 0 ;;
      0) return 1 ;;
      *) warn "无效选择" ;;
    esac
  done
}

# 总体环境报告：Reality / 443 / 其他 QUIC 协议 / TUN / 地址池
mq_env_report() {
  local t443 u443 r_rsite=0 others f u sv
  title "部署前检查：Reality / 443 / 协议冲突"
  if [ ! -c /dev/net/tun ]; then
    err "本机没有 /dev/net/tun，MASQUE（CONNECT-IP）无法运行"
    msg "  解决：OpenVZ/LXC 小鸡需在服务商面板开启 TUN/TAP；KVM 执行 modprobe tun 后重试"
    return 1
  fi
  ok "/dev/net/tun 可用"
  t443="$(port_owner 443)"; u443="$(port_owner_udp 443)"
  state_load && is_deployed && [ "$PORT" = 443 ] && r_rsite=1
  others="$(grep -ls '"reality"\|realitySettings' /usr/local/etc/xray/*.json /etc/xray/*.json /etc/sing-box/*.json \
            /usr/local/x-ui/bin/config.json /etc/s-ui/*.json 2>/dev/null | grep -v "^${XRAY_CONF}$" | tr '\n' ' ')"
  kv "TCP 443" "${t443:-空闲}$([ "$r_rsite" = 1 ] && printf '（rsite Reality）')" \
     "UDP 443" "${u443:-空闲}"
  [ -n "$others" ] && kv "其他 Reality 配置" "$others"
  if [ "$r_rsite" = 1 ] || [ "$t443" = xray ] || [ "$t443" = sing-box ]; then
    msg "  ${C_G}→ 已有 Reality 占用 TCP 443。MASQUE 默认走 HTTP/3（UDP），可与 Reality 共用 443 端口号互不影响；${C_0}"
    msg "  ${C_G}  只有「HTTP/2 回落」需要 TCP，必须换用其他 TCP 端口。${C_0}"
  fi
  if [ -n "$u443" ] && [ "$u443" != masque-server ]; then
    msg "  ${C_Y}→ UDP 443 已被 ${u443} 占用（Hysteria2 / TUIC / 其他 QUIC 服务？），MASQUE 需改端口或停用它，下一步会给出选项。${C_0}"
  fi
  # 其他代理服务
  for sv in sing-box hysteria-server hysteria tuic tuic-server s-ui x-ui 3x-ui juicity-server naiveproxy caddy warp-svc; do
    systemctl is-active --quiet "$sv" 2>/dev/null && u+="${sv} "
  done
  [ -n "$u" ] && kv "运行中的其他代理服务" "$u"
  if ip link 2>/dev/null | grep -qiE 'CloudflareWARP|wgcf|warp[0-9]*:'; then
    warn "检测到本机 WARP 网卡：若它接管了默认路由，MASQUE 的回包会被带偏；建议 WARP 只作为 Xray 出站使用"
  fi
  msg "  对外监听（非 127.0.0.1）："
  ss -Hlntup 2>/dev/null | while read -r f _ _ _ loc _ proc; do
    case "$loc" in 127.*|"[::1]"*|::1*|"[::ffff:127."*) continue ;; esac
    printf '    %-4s %-6s %s\n' "$f" "${loc##*:}" "$(grep -o '"[^"]*"' <<<"$proc" | head -n1 | tr -d '"')"
  done | sort -u -k1,2
  return 0
}

# ---------------------------------------------------------------- 输出客户端配置
mq_warp_client_out() { # 需先 mq_client_load
  local ip4 ip6=""; ip4="$(mq_client_ip4 "$C_IDX")"; [ "$MQ_V6" = yes ] && ip6="$(mq_client_ip6 "$C_IDX")"
  msg "${C_W}[WARP 客户端 ${C_NAME}] Mihomo / Clash.Meta（type: masque）：${C_0}"
  cat <<EOF
  - name: "MASQUE-${C_NAME}"
    type: masque
    server: ${MQ_ADDR}
    port: ${MQ_WARP_PORT}
    private-key: ${C_PRIV}
    public-key: ${MQ_SRV_PUB}
    ip: ${ip4}/32
EOF
  [ -n "$ip6" ] && printf '    ipv6: %s/128\n' "$ip6"
  printf '    mtu: %s\n    udp: true\n' "$MQ_MTU"
  [ -n "$MQ_WARP_H2" ] && msg "    # 网络封 UDP 时：port 改为 ${MQ_WARP_H2}，并加一行  network: h2"
  local pem js="${MQ_CLI_DIR}/${C_NAME}.usque.json"
  pem="$(openssl x509 -in "$MQ_CERTS/server.crt" -noout -pubkey 2>/dev/null)"
  ( umask 077; jq -n --arg pk "$C_PRIV" --arg e "$MQ_ADDR" --arg pem "$pem" --arg i4 "$ip4" --arg i6 "$ip6" \
      --arg v6 "$(valid_ipv6 "$MQ_ADDR" && echo 1)" '
    {private_key:$pk,
     endpoint_v4:(if $v6=="1" then "" else $e end), endpoint_v6:(if $v6=="1" then $e else "" end),
     endpoint_h2_v4:(if $v6=="1" then "" else $e end), endpoint_h2_v6:(if $v6=="1" then $e else "" end),
     endpoint_pub_key:($pem+"\n"), license:"", id:"", access_token:"", ipv4:$i4, ipv6:$i6}' >"$js" )
  msg "${C_W}usque（JSON 已保存到 ${js}）：${C_0}"
  cat "$js"
  msg "  启动: usque -c ${C_NAME}.usque.json socks -P ${MQ_WARP_PORT}${MQ_WARP_H2:+     （HTTP/2：usque -c ${C_NAME}.usque.json socks -P ${MQ_WARP_H2} --http2）}"
}

mq_rfc_out() {
  local host="$MQ_HOST" self=0 fp=""
  [ "$MQ_CERT_SRC" = domain ] || { self=1; host="$MQ_ADDR"; fp="$(mq_cert_sha256)"; }
  msg "${C_W}[RFC 账号密码模式] 通用参数：${C_0}"
  kv "服务器" "$host" "端口" "${MQ_RFC_PORT}（UDP / HTTP/3）${MQ_RFC_H2:+，HTTP/2: TCP ${MQ_RFC_H2}}" \
     "用户名" "$MQ_RFC_USER" "密码" "$MQ_RFC_PASS" "认证" "HTTP Basic（Proxy-Authorization）" \
     "CONNECT-IP 路径" "/.well-known/masque/ip/{target}/{ipproto}/" \
     "CONNECT-UDP 路径" "/.well-known/masque/udp/{target_host}/{target_port}/" \
     "证书" "$([ "$self" = 1 ] && echo "自签（SHA-256 指纹 ${fp}）" || echo "$host 正式证书")"
  line
  msg "${C_W}Surge：${C_0}"
  printf '[Proxy]\nMASQUE-RFC = masque, %s, %s, username=%s, password=%s%s\n' "$(link_host "$host")" "$MQ_RFC_PORT" \
    "$MQ_RFC_USER" "$MQ_RFC_PASS" "$([ "$self" = 1 ] && printf ', server-cert-fingerprint-sha256=%s' "$fp")"
  line
  msg "${C_W}Xray 出站（需支持 masque 的 Xray 版本）：${C_0}"
  jq -n --arg a "$host" --argjson p "$MQ_RFC_PORT" --arg u "$MQ_RFC_USER" --arg pw "$MQ_RFC_PASS" \
     --arg sni "$host" --arg fp "$fp" '
    {tag:"masque-rfc", protocol:"masque", settings:{address:$a, port:$p},
     streamSettings:{network:"masque", security:"tls",
       masqueSettings:{user:$u, pass:$pw},
       tlsSettings:({serverName:$sni} + (if $fp=="" then {} else {pinnedPeerCertSha256:$fp} end))}}'
  msg "提示：mihomo 的 masque 只支持 WARP 双向证书模式，账号密码模式请用 Surge / Xray 等 RFC 客户端。"
}

mq_show() {
  mq_load && mq_any || { warn "尚未部署 MASQUE"; return 1; }
  local f out="${RSITE_DIR}/masque-clients.txt"
  {
    title "MASQUE 节点"
    kv "服务状态" "$(systemctl is-active "$MQ_SVC" 2>/dev/null)" "版本" "$(mq_ver_now)" \
       "监听" "$(mq_listen_summary)" "连接地址" "$MQ_ADDR" \
       "隧道地址池" "${MQ_POOL4}$([ "$MQ_V6" = yes ] && printf ' / %s' "$MQ_POOL6")" "MTU" "$MQ_MTU" \
       "服务端公钥" "$MQ_SRV_PUB"
    if [ "$MQ_WARP" = yes ]; then
      line
      for f in $(mq_client_files); do mq_client_load "$f" && { mq_warp_client_out; line; }; done
    fi
    [ "$MQ_RFC" = yes ] && { line; mq_rfc_out; }
    line
    msg "云服务商安全组/防火墙需放行上面的 UDP 端口（HTTP/3），否则客户端握手超时。"
  } | tee "$out"
  chmod 600 "$out"
  msg "以上配置含私钥/密码，已保存到 ${out}（仅 root 可读），不要外传。"
}

# ---------------------------------------------------------------- 部署
# mq_deploy warp|rfc
mq_deploy() {
  local mode="$1" c tmp cname="" newcli=0 def
  mq_load || true
  state_load 2>/dev/null || true
  if [ "$mode" = warp ]; then
    title "部署 MASQUE · WARP 双向证书模式（mTLS / ECDSA P-256）"
    msg "客户端用 ECDSA P-256 私钥做 TLS 客户端证书，服务端按公钥白名单放行；客户端固定服务端 ECDSA 公钥。"
    msg "与 Cloudflare WARP 的 MASQUE 规范一致：mihomo（type: masque）、usque 等可直接使用。"
  else
    title "部署 MASQUE · RFC 账号密码模式（HTTP Basic）"
    msg "RFC 9484 CONNECT-IP / RFC 9298 CONNECT-UDP，HTTP Basic 认证：Surge、Xray masque 出站等通用客户端。"
  fi
  mq_env_report || return 1
  apt_install curl jq openssl iptables tar >/dev/null || return 1

  step "1" "连接地址"
  [ -z "$MQ_ADDR" ] && MQ_ADDR="${SERVER_IP:-$(detect_ip || true)}"
  while :; do
    ask MQ_ADDR "服务器公网 IP（WARP 客户端只认 IP）" "$MQ_ADDR"
    valid_ipv4 "$MQ_ADDR" || valid_ipv6 "$MQ_ADDR" && break; warn "请填 IP 地址"
  done

  step "2" "端口（会逐一检查冲突）"
  if [ "$mode" = warp ]; then
    def="${MQ_WARP_PORT:-443}"; [ "$MQ_RFC" = yes ] && [ "$MQ_RFC_PORT" = "$def" ] && def=4443
    while :; do ask MQ_WARP_PORT "HTTP/3 端口（UDP）" "$def"; valid_port "$MQ_WARP_PORT" && break; done
    mq_port_check MQ_WARP_PORT udp "WARP 模式 HTTP/3" warp || { warn "已取消"; return 1; }
    if confirm "额外开启 HTTP/2 回落（TCP，用于封 UDP 的网络）？" "$([ -n "$MQ_WARP_H2" ] && echo y || echo n)"; then
      [ -n "$MQ_WARP_H2" ] || MQ_WARP_H2="$(mq_free_port tcp 2051 warp)"
      while :; do ask MQ_WARP_H2 "HTTP/2 端口（TCP）" "$MQ_WARP_H2"; valid_port "$MQ_WARP_H2" && break; done
      mq_port_check MQ_WARP_H2 tcp "WARP 模式 HTTP/2" warp || { warn "已取消"; return 1; }
    else MQ_WARP_H2=""; fi
  else
    def="${MQ_RFC_PORT:-443}"; [ "$MQ_WARP" = yes ] && [ "$MQ_WARP_PORT" = "$def" ] && def=4443
    while :; do ask MQ_RFC_PORT "HTTP/3 端口（UDP）" "$def"; valid_port "$MQ_RFC_PORT" && break; done
    mq_port_check MQ_RFC_PORT udp "RFC 模式 HTTP/3" rfc || { warn "已取消"; return 1; }
    if confirm "额外开启 HTTP/2 回落（TCP，用于封 UDP 的网络）？" "$([ -n "$MQ_RFC_H2" ] && echo y || echo n)"; then
      [ -n "$MQ_RFC_H2" ] || MQ_RFC_H2="$(mq_free_port tcp 2052 rfc)"
      while :; do ask MQ_RFC_H2 "HTTP/2 端口（TCP）" "$MQ_RFC_H2"; valid_port "$MQ_RFC_H2" && break; done
      mq_port_check MQ_RFC_H2 tcp "RFC 模式 HTTP/2" rfc || { warn "已取消"; return 1; }
    else MQ_RFC_H2=""; fi
  fi
  # 同一 MASQUE 进程内两个监听不能撞端口（上面的检查已排除，这里兜底）
  if [ "$MQ_WARP" = yes ] || [ "$mode" = warp ]; then
    if { [ "$MQ_RFC" = yes ] || [ "$mode" = rfc ]; } && [ "$MQ_WARP_PORT" = "$MQ_RFC_PORT" ]; then
      err "WARP 与 RFC 模式不能使用同一个 UDP 端口（认证方式由 TLS 握手决定）"; return 1
    fi
  fi

  step "3" "认证"
  if [ "$mode" = warp ]; then
    if [ "$(mq_client_count)" -gt 0 ]; then
      msg "已有 $(mq_client_count) 个 WARP 客户端密钥，将保留。"
      if confirm "再新增一个客户端？" n; then newcli=1; fi
    else
      newcli=1
    fi
    if [ "$newcli" = 1 ]; then
      while :; do ask cname "客户端名称（字母数字 _ -）" "device$(( $(mq_client_count) + 1 ))"; valid_cname "$cname" && [ ! -e "$MQ_CLI_DIR/$cname.env" ] && break; warn "名称无效或已存在"; done
    fi
  else
    while :; do ask MQ_RFC_USER "用户名" "$MQ_RFC_USER"; [[ "$MQ_RFC_USER" =~ ^[A-Za-z0-9._-]{1,32}$ ]] && break; warn "用户名只能用字母数字 . _ -"; done
    tmp="${MQ_RFC_PASS:-$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-24)}"
    while :; do ask MQ_RFC_PASS "密码（回车用随机）" "$tmp"; [[ "$MQ_RFC_PASS" =~ ^[A-Za-z0-9._~-]{8,64}$ ]] && break; warn "密码 8~64 位，只能用字母数字 . _ ~ -"; done
    if confirm "开启 stealth（未认证请求一律返回空 404，不暴露 407；Surge 兼容）？" "$([ "$MQ_RFC_STEALTH" = yes ] && echo y || echo n)"; then MQ_RFC_STEALTH=yes; else MQ_RFC_STEALTH=no; fi
  fi

  step "4" "服务端证书（必须是 ECDSA）"
  local can_domain=0 old_src="$MQ_CERT_SRC"
  state_load && is_deployed && cert_ok && can_domain=1
  if [ "$can_domain" = 1 ]; then
    msg "  1) 复用 Reality 站点证书 ${DOMAIN}（ECC，acme.sh 自动续签并同步；RFC 客户端可正常校验，推荐）"
    msg "  2) 自签 ECDSA P-256 证书（10 年；RFC 客户端需固定指纹）"
    ask c "选择" "$([ "$MQ_CERT_SRC" = self ] && echo 2 || echo 1)"
    if [ "$c" = 2 ]; then MQ_CERT_SRC=self; else MQ_CERT_SRC=domain; MQ_HOST="$DOMAIN"; fi
  else
    msg "未检测到可用的 Reality 站点证书，使用自签 ECDSA P-256 证书。"
    MQ_CERT_SRC=self
  fi
  [ "$MQ_CERT_SRC" = self ] && MQ_HOST="$MQ_ADDR"
  if [ -n "$old_src" ] && [ "$old_src" != "$MQ_CERT_SRC" ] && [ "$(mq_client_count)" -gt 0 ]; then
    warn "更换证书来源会改变服务端公钥，已有 WARP 客户端都需要重新导入配置"
  fi

  mq_pick_pool
  if ip -6 route show default 2>/dev/null | grep -q .; then MQ_V6=yes; else MQ_V6=no; fi
  confirm "隧道内禁止访问内网/保留地址（10/8、172.16/12、192.168/16 等）？" "$([ "$MQ_BLOCK_PRIV" = yes ] && echo y || echo n)" && MQ_BLOCK_PRIV=yes || MQ_BLOCK_PRIV=no

  title "确认 MASQUE 配置"
  if [ "$mode" = warp ]; then
    kv "模式" "WARP 双向证书（mTLS / ECDSA P-256）" "HTTP/3" "UDP ${MQ_WARP_PORT}" "HTTP/2 回落" "${MQ_WARP_H2:-关闭}" \
       "新客户端" "${cname:-（不新增）}"
  else
    kv "模式" "RFC 账号密码（HTTP Basic）" "HTTP/3" "UDP ${MQ_RFC_PORT}" "HTTP/2 回落" "${MQ_RFC_H2:-关闭}" \
       "用户名" "$MQ_RFC_USER" "stealth" "$MQ_RFC_STEALTH"
  fi
  kv "连接地址" "$MQ_ADDR" "证书" "$([ "$MQ_CERT_SRC" = domain ] && echo "站点证书 $MQ_HOST" || echo 自签)" \
     "隧道地址池" "${MQ_POOL4}$([ "$MQ_V6" = yes ] && printf ' / %s' "$MQ_POOL6" || printf '（本机无 IPv6，仅 IPv4）')" \
     "内网拦截" "$MQ_BLOCK_PRIV" "IP 转发 / NAT" "自动配置（${MQ_NAT_SVC}.service）"
  line
  confirm "开始部署？" y || { warn "已取消"; return 1; }

  mq_install_bin || return 1
  mq_prepare_cert || return 1
  if [ "$mode" = warp ]; then
    [ "$newcli" = 1 ] && { mq_client_new "$cname" || return 1; }
    MQ_WARP=yes
  else
    MQ_RFC_HASH="$(printf '%s' "$MQ_RFC_PASS" | "$MQ_BIN" hash-password 2>/dev/null | tail -n1 | tr -d '[:space:]')"
    [[ "$MQ_RFC_HASH" == '$argon2id$'* ]] || { err "生成密码哈希失败"; return 1; }
    MQ_RFC=yes
  fi
  mq_save
  mq_apply || return 1
  mq_show
}

# ---------------------------------------------------------------- 客户端管理 / 诊断 / 删除
mq_client_menu() {
  mq_load && mq_any || { warn "尚未部署 MASQUE"; return 1; }
  local c n f
  title "MASQUE 客户端管理"
  if [ "$MQ_WARP" = yes ]; then
    msg "WARP 客户端："
    for f in $(mq_client_files); do mq_client_load "$f" && msg "  - ${C_NAME}  $(mq_client_ip4 "$C_IDX")"; done
  fi
  [ "$MQ_RFC" = yes ] && msg "RFC 账号：${MQ_RFC_USER}"
  msg ""
  msg "  1) 新增 WARP 客户端（生成新的 ECDSA 密钥对）"
  msg "  2) 删除 WARP 客户端（立即断开并吊销）"
  msg "  3) 修改 RFC 模式密码"
  msg "  0) 返回"
  ask c "请选择 [0-3]" ""
  case "$c" in
    1) [ "$MQ_WARP" = yes ] || { warn "未启用 WARP 模式"; return 1; }
       while :; do ask n "客户端名称" "device$(( $(mq_client_count) + 1 ))"; valid_cname "$n" && [ ! -e "$MQ_CLI_DIR/$n.env" ] && break; warn "名称无效或已存在"; done
       mq_client_new "$n" && mq_apply && { mq_client_load "$MQ_CLI_DIR/$n.env"; line; mq_warp_client_out; } ;;
    2) ask n "要删除的客户端名称" ""
       [ -f "$MQ_CLI_DIR/$n.env" ] || { warn "不存在"; return 1; }
       [ "$(mq_client_count)" -le 1 ] && { warn "至少保留一个客户端（不需要了可删除 WARP 模式）"; return 1; }
       rm -f "$MQ_CLI_DIR/$n.env" "$MQ_CLI_DIR/$n.usque.json"; mq_apply && ok "已吊销 ${n}" ;;
    3) [ "$MQ_RFC" = yes ] || { warn "未启用 RFC 模式"; return 1; }
       while :; do ask n "新密码" "$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-24)"; [[ "$n" =~ ^[A-Za-z0-9._~-]{8,64}$ ]] && break; warn "8~64 位字母数字"; done
       MQ_RFC_PASS="$n"
       MQ_RFC_HASH="$(printf '%s' "$MQ_RFC_PASS" | "$MQ_BIN" hash-password 2>/dev/null | tail -n1 | tr -d '[:space:]')"
       [[ "$MQ_RFC_HASH" == '$argon2id$'* ]] || { err "生成哈希失败"; return 1; }
       mq_save; mq_apply && { line; mq_rfc_out; } ;;
  esac
}

mq_doctor() {
  mq_load && mq_any || { warn "尚未部署 MASQUE"; return 1; }
  title "MASQUE 诊断"
  local pass=0 fail=0
  mchk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; pass=$((pass+1)); else printf '%s[FAIL]%s %s\n' "$C_R" "$C_0" "$1"; [ -n "${3:-}" ] && msg "       → $3"; fail=$((fail+1)); fi; }
  mchk "masque 服务运行中" "systemctl is-active --quiet $MQ_SVC" "journalctl -u $MQ_SVC -n 40"
  mchk "转发/NAT 服务已加载" "systemctl is-active --quiet $MQ_NAT_SVC" "systemctl restart $MQ_NAT_SVC"
  mchk "配置检查通过" "$MQ_BIN --config $MQ_CONF check-config"
  [ "$MQ_WARP" = yes ] && mchk "UDP ${MQ_WARP_PORT} 由 masque-server 监听（WARP）" "[ \"\$(port_owner_udp $MQ_WARP_PORT)\" = masque-server ]"
  [ "$MQ_RFC" = yes ] && mchk "UDP ${MQ_RFC_PORT} 由 masque-server 监听（RFC）" "[ \"\$(port_owner_udp $MQ_RFC_PORT)\" = masque-server ]"
  mchk "IPv4 转发已开启" "[ \"\$(sysctl -n net.ipv4.ip_forward)\" = 1 ]"
  mchk "NAT 规则存在（${MQ_POOL4}）" "iptables -t nat -S POSTROUTING | grep -q -- '--comment ${MQ_TAG}'"
  mchk "隧道网卡 ${MQ_TUN} 存在" "ip link show $MQ_TUN"
  if [ -n "$MQ_SRV_PUB" ]; then
    mchk "服务端证书公钥与已下发给 WARP 客户端的一致" \
      "[ \"\$(openssl x509 -in $MQ_CERTS/server.crt -noout -pubkey | openssl pkey -pubin -outform DER | base64 -w0)\" = \"$MQ_SRV_PUB\" ]" \
      "证书私钥变了：重新「查看 MASQUE 配置」并在客户端重新导入"
  fi
  line
  msg "masque-server 自带主机诊断（只读）："
  "$MQ_BIN" --config "$MQ_CONF" doctor 2>&1 | tail -n 20 | sed 's/^/  /'
  line
  msg "通过 ${pass} 项，失败 ${fail} 项。外部连通性可在电脑上用 masque-probe 测试（见 README）。"
}

mq_remove() {
  mq_load && mq_any || { warn "未部署 MASQUE"; return 0; }
  local c
  title "删除 MASQUE"
  msg "当前: $(mq_listen_summary)"
  msg "  1) 只删除 WARP 双向证书模式"
  msg "  2) 只删除 RFC 账号密码模式"
  msg "  3) 全部删除并卸载 masque-server"
  msg "  0) 返回"
  ask c "请选择 [0-3]" ""
  case "$c" in
    1) MQ_WARP=no; MQ_WARP_H2=""; confirm "同时删除所有 WARP 客户端密钥？" y && rm -rf "$MQ_CLI_DIR" ;;
    2) MQ_RFC=no; MQ_RFC_H2=""; MQ_RFC_PASS=""; MQ_RFC_HASH="" ;;
    3) mq_purge; return ;;
    *) return 0 ;;
  esac
  if mq_any; then mq_save; mq_apply
  else mq_purge quiet; fi
}

mq_purge() {
  [ "${1:-}" = quiet ] || confirm "停止并删除 MASQUE 服务、配置、证书副本、客户端密钥？" n || return 0
  systemctl disable --now "$MQ_SVC" >/dev/null 2>&1
  systemctl disable --now "$MQ_NAT_SVC" >/dev/null 2>&1
  mq_nat_flush
  rm -f "/etc/systemd/system/${MQ_SVC}.service" "/etc/systemd/system/${MQ_NAT_SVC}.service"
  systemctl daemon-reload 2>/dev/null || true
  rm -rf "$MQ_ETC" "$MQ_STATE" "$MQ_CLI_DIR" "$MQ_SELF_DIR" "${RSITE_DIR}/masque-clients.txt"
  rm -f "$MQ_BIN" "$MQ_PROBE_BIN"
  ok "已删除 MASQUE（IP 转发 sysctl 保持当前值，重启后恢复系统默认）"
}

mq_status() {
  if mq_load && mq_any; then printf '%s · %s' "$(systemctl is-active "$MQ_SVC" 2>/dev/null)" "$(mq_listen_summary)"
  else printf '未部署'; fi
}

# ---------------------------------------------------------------- 子菜单
other_menu() {
  while :; do
    local vs ms
    vs="$(venc_deployed && systemctl is-active "$VENC_SVC" 2>/dev/null || echo 未部署)"
    ms="$(mieru_deployed && systemctl is-active "$MIERU_SVC" 2>/dev/null || echo 未部署)"
    title "其他协议：mieru / VLESS Encryption / MASQUE"
    msg "VLESS Encryption: ${vs}    mieru: ${ms}"
    msg "MASQUE: $(mq_status)"
    msg ""
    msg "  1) 部署 / 重装 VLESS Encryption"
    msg "  2) 查看 VLESS Encryption 链接"
    msg "  3) 删除 VLESS Encryption"
    msg "  4) 部署 / 重装 mieru"
    msg "  5) 查看 mieru 链接"
    msg "  6) 删除 mieru"
    msg "  7) 重启以上全部服务"
    msg "  ---- MASQUE（HTTP/3 CONNECT-IP，可与 Reality 共用 443：UDP vs TCP）----"
    msg "  8) 部署 MASQUE · WARP 双向证书模式（mTLS，ECDSA P-256 公私钥对）"
    msg "  9) 部署 MASQUE · RFC 标准账号密码模式（HTTP Basic）"
    msg " 10) 查看 MASQUE 客户端配置（mihomo / usque / Surge / Xray）"
    msg " 11) MASQUE 客户端管理（新增/吊销 WARP 设备、改密码）"
    msg " 12) MASQUE 诊断"
    msg " 13) 删除 MASQUE"
    msg "  0) 返回"
    local c; ask c "请选择 [0-13]" ""
    case "$c" in
      1) venc_deploy ;;
      2) venc_show ;;
      3) venc_remove ;;
      4) mieru_deploy ;;
      5) mieru_show ;;
      6) mieru_remove ;;
      7) systemctl restart "$VENC_SVC" 2>/dev/null; systemctl restart "$MIERU_SVC" 2>/dev/null
         mq_load && mq_any && systemctl restart "$MQ_NAT_SVC" "$MQ_SVC" 2>/dev/null; ok "已尝试重启" ;;
      8) mq_deploy warp ;;
      9) mq_deploy rfc ;;
      10) mq_show ;;
      11) mq_client_menu ;;
      12) mq_doctor ;;
      13) mq_remove ;;
      0) return 0 ;;
      *) warn "无效选择" ;;
    esac
    [ "$c" = 0 ] || pause
  done
}

# -----------------------------------------------------------------------------
# 主菜单
# -----------------------------------------------------------------------------
main_menu() {
  while :; do
    local st="${C_Y}未部署${C_0}" xs ns
    if state_load && is_deployed; then
      xs="$(systemctl is-active xray 2>/dev/null)"; ns="$(systemctl is-active nginx 2>/dev/null)"
      st="${C_G}已部署${C_0}  ${DOMAIN}  :${PORT}   xray: $([ "$xs" = active ] && echo "${C_G}运行${C_0}" || echo "${C_R}${xs}${C_0}")  nginx: $([ "$ns" = active ] && echo "${C_G}运行${C_0}" || echo "${C_R}${ns}${C_0}")"
    fi
    msg ""
    msg "${C_W}========== Reality-Site OneClick v${RSITE_VERSION} ==========${C_0}"
    msg "nginx 伪装站 + VLESS Reality（自有域名做 target）"
    msg "状态: ${st}"
    msg ""
    msg "  1) 一键部署 / 重新部署"
    msg "  2) 查看节点链接 / 二维码"
    msg "  3) 修改节点参数（UUID / shortId / 密钥 / 端口）"
    msg "  4) 诊断 Doctor"
    msg "  5) 证书管理"
    msg "  6) 服务管理"
    msg "  7) 防偷跑 / 访问统计"
    msg "  8) 系统优化 / 加固（更新源/DNS/TCP/SSH/UFW/BBR）"
    msg "  9) 其他协议：mieru / VLESS Encryption / MASQUE"
    msg " 10) 核心管理：Xray 升级 / sing-box 安装与升级"
    msg " 11) 卸载"
    msg "  0) 退出"
    msg ""
    msg "${C_G}下次直接输入 rl 即可调出本菜单${C_0}（等同 rsite）"
    msg "快捷命令: rl link | rl doctor | rl install | rl masque | rl core"
    local c; ask c "请选择 [0-11]" ""
    case "$c" in
      1) wizard ;;
      2) show_node ;;
      3) rotate_menu ;;
      4) doctor ;;
      5) cert_menu ;;
      6) service_menu ;;
      7) abuse_menu ;;
      8) harden_menu ;;
      9) other_menu ;;
      10) core_menu ;;
      11) uninstall ;;
      0|q|Q) exit 0 ;;
      *) warn "无效选择"; continue ;;
    esac
    pause
  done
}

main() {
  require_root
  require_os
  self_install
  case "${1:-}" in
    install) apt_install curl jq >/dev/null || exit 1; wizard ;;
    link) show_node ;;
    doctor) doctor ;;
    masque) mq_show ;;
    core) apt_install curl jq >/dev/null || exit 1; core_menu ;;
    cert-hook) cert_hook ;;                 # acme.sh 续签后调用
    masque-nat) mq_nat "${2:-up}" ;;        # rsite-masque-nat.service 调用
    -v|--version) msg "$RSITE_VERSION" ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
    "") apt_install curl jq || exit 1; main_menu ;;
    *) err "未知参数: $1（可用: install / link / doctor / masque / core）"; exit 1 ;;
  esac
}

[ "${RSITE_NO_MAIN:-0}" = 1 ] || main "$@"
