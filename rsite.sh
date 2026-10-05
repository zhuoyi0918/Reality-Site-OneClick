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
#
#  支持: Debian 11+ / Ubuntu 20.04+ (x86_64 / arm64)，需 root
# =============================================================================

set -o pipefail

RSITE_VERSION="1.0.3"
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
  mkdir -p "$(cert_dir)"
  "$ACME" --install-cert -d "$DOMAIN" --ecc \
    --key-file "$(cert_dir)/key.pem" --fullchain-file "$(cert_dir)/cert.pem" \
    --reloadcmd "systemctl reload nginx 2>/dev/null || true" >/dev/null || { err "安装证书失败"; return 1; }
  chmod 600 "$(cert_dir)/key.pem"
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
    7) install_xray upgrade && state_load && apply_xray ;;
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

harden_ssh() {
  local cur newp; cur="$(ssh_port_now)"; cur="${cur:-22}"
  warn "修改前请确认：你已能用【密钥】登录本机。关闭密码登录后只能用密钥。"
  if [ ! -s /root/.ssh/authorized_keys ] && ! ls /home/*/.ssh/authorized_keys >/dev/null 2>&1; then
    err "没有找到任何 authorized_keys，关闭密码登录会把你锁在外面。已中止。"
    return 1
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

harden_menu() {
  title "系统加固（可选，按需执行）"
  msg "  1) 系统更新 + 自动安全更新（apt full-upgrade, unattended-upgrades）"
  msg "  2) SSH：改端口 + 仅密钥登录"
  msg "  3) UFW 防火墙（只开 SSH / 80 / Reality 端口）"
  msg "  4) fail2ban（sshd）"
  msg "  5) 开启 BBR + fq"
  msg "  0) 返回"
  local c; ask c "请选择 [0-5]" ""
  case "$c" in
    1) DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade \
         && apt_install unattended-upgrades && ok "系统已更新" ;;
    2) harden_ssh ;;
    3) harden_ufw ;;
    4) harden_f2b ;;
    5) harden_bbr ;;
  esac
}

# -----------------------------------------------------------------------------
# 卸载
# -----------------------------------------------------------------------------
uninstall() {
  state_load || true
  title "卸载"
  warn "将删除：Xray（含配置）、nginx 站点配置 rsite.conf、证书续签任务、rsite 状态与命令。"
  msg "保留：nginx 软件包、UFW 规则、SSH 设置、网站目录（会单独询问）。"
  confirm "确定卸载？" n || return 0
  systemctl disable --now xray >/dev/null 2>&1
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
  if [ -L "$RL_BIN" ] && [ "$(readlink "$RL_BIN")" = "$RSITE_BIN" ]; then rm -f "$RL_BIN"; fi
  ok "已卸载。Cloudflare 上的 DNS 记录和 Token 请自行处理（建议在 CF 轮换/删除 Token）。"
  exit 0
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
    msg "  8) 系统加固（SSH / UFW / fail2ban / BBR）"
    msg "  9) 卸载"
    msg "  0) 退出"
    msg ""
    msg "${C_G}下次直接输入 rl 即可调出本菜单${C_0}（等同 rsite）"
    msg "快捷命令: rl link | rl doctor | rl install"
    local c; ask c "请选择 [0-9]" ""
    case "$c" in
      1) wizard ;;
      2) show_node ;;
      3) rotate_menu ;;
      4) doctor ;;
      5) cert_menu ;;
      6) service_menu ;;
      7) abuse_menu ;;
      8) harden_menu ;;
      9) uninstall ;;
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
    -v|--version) msg "$RSITE_VERSION" ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' ;;
    "") apt_install curl jq || exit 1; main_menu ;;
    *) err "未知参数: $1（可用: install / link / doctor）"; exit 1 ;;
  esac
}

[ "${RSITE_NO_MAIN:-0}" = 1 ] || main "$@"
