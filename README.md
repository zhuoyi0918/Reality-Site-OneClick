# Reality-Site-OneClick

nginx 伪装站 + VLESS Reality（**自有域名做 target**）一键部署脚本。终端交互菜单，不依赖 S-UI 等面板。

输入 Cloudflare Token、域名、IP、端口 → 自动完成 DNS（灰云）→ acme.sh DNS-01 证书 → nginx 回落站 → Xray Reality → 输出 `vless://` 链接、二维码、Mihomo / sing-box 配置。

```
访客/探测 ──443──► Xray(Reality) ──认证失败──► 127.0.0.1:8443 nginx（真实网站）
你的客户端 ─443──► Xray(Reality) ──认证成功──► 代理出站
```

SNI 与证书都是你自己的域名，完全一致。

## 安装

```bash
curl -fsSLO https://github.com/zhuoyi0918/Reality-Site-OneClick/releases/latest/download/rsite.sh
sudo bash rsite.sh
```

首次运行后会安装管理命令 `rsite`：

```bash
rsite            # 交互菜单（也可输入短命令 rl）
rl               # 等同 rsite
rsite install    # 直接进入部署向导
rsite link       # 节点链接 / 二维码 / 客户端配置
rsite doctor     # 诊断
```

支持 Debian 11+ / Ubuntu 20.04+，需 root 与 systemd。

## 部署前准备

1. 域名托管在 Cloudflare。
2. 在 CF「我的个人资料 → API 令牌」创建 Token：模板「编辑区域 DNS」，区域资源只授权该域名所在区域（可选：客户端 IP 筛选只允许 VPS IP）。
3. Token 等同密码，不要贴到聊天、截图或公开文档里；泄露后在 CF 里「轮换」即可。

## 向导内容

| 步骤 | 内容 |
|---|---|
| 1 | 域名（如 `123456.example.com`） |
| 2 | CF Token（不回显，自动查找所属区域；已有有效证书时可跳过；同一主域名下换子域名时可直接复用 acme.sh 已保存的 Token） |
| 3 | VPS 公网 IPv4（自动探测）、Reality 端口（默认 443）、nginx 回落端口（默认 8443） |
| 4 | UUID / shortId / fingerprint / 节点名（回车自动生成） |
| 5 | 网站目录与标题（内置纯静态胸外科科普模板） |
| 6 | 证书邮箱、自动写 A 记录（灰云）、geoip:cn 拦截、limitFallback 防偷跑 |

确认汇总后执行，最后自检并输出链接。

## 菜单功能

1. 一键部署 / 重新部署
2. 查看节点链接 / 二维码
3. 修改节点参数（UUID / shortId / 密钥 / 连接地址）
4. 诊断 Doctor（服务、端口、证书、DNS 灰云、回落 200、错误 SNI 拒绝握手、续签任务）
5. 证书管理（强制续签 / 换 Token 重签）
6. 服务管理（状态、重启、日志、更新 Xray）
7. 防偷跑 / 访问统计（Top IP、ufw 封禁）
8. 系统加固（SSH 改端口 + 仅密钥、UFW、fail2ban、BBR，均为可选）
9. 卸载

## 细节

- nginx 只监听 `127.0.0.1:回落端口`，开启 `proxy_protocol`；Xray `xver: 1` 与之对应，nginx 能拿到真实来源 IP，按 IP 限连接数 / 请求频率 / 速率。
- 非本域名 SNI 拒绝握手；80 端口只为本域名跳 https，其余 444。
- 自动停用 nginx 默认站点；兼容老版本 nginx（`http2` 写法、无 `ssl_reject_handshake` 时自签兜底）。
- 兼容 Xray 新旧版本（`target` / `dest`、`x25519` 输出格式）。
- 签发前清理 acme.sh 中写死的 `SAVED_CF_Zone_ID / SAVED_CF_Account_ID`，避免 `count:0` 类错误。
- 443 被 S-UI 占用时可一键停用 s-ui。
- 状态保存在 `/etc/rsite/rsite.env`（600），链接保存在 `/etc/rsite/link.txt`。

「只有自己能用代理」靠的是 UUID + shortId + 私钥，这三样不要外传。

## 常见问题

### 报错 `9109: Cannot use the access token from location: x.x.x.x`

```
[错误] Cloudflare API 返回错误: 9109: Cannot use the access token from location: 203.0.113.10
```

Token 本身没问题（复制粘贴也没问题），是这个 Token 设置了「客户端 IP 地址筛选」，而报错里的 IP（当前 VPS 的出口 IP）不在名单里。

1. CF「我的个人资料 → API 令牌」→ 找到该 Token →「编辑」。
2. 在「客户端 IP 地址筛选」里加入报错中的 IP；VPS 有 IPv6 的话把 IPv6 也加上，否则 acme.sh 走 IPv6 签证书时会报同样的错。
3. 点「继续以显示摘要」→「更新令牌」，**不点更新不会生效**。
4. 回到 VPS 重新运行 `rsite install`，粘贴同一个 Token 即可，不需要新建。

每新增一台 VPS 都要补一次 IP。也可以删掉 IP 筛选、只保留「区域资源只授权该主域名」，更省事，但 Token 泄露后任何地方都能改该域名的 DNS。

### 新 VPS、主域名不变，要不要新建 Token？

不用，同一个 Token 可以用在同一主域名（CF 同一区域）下的任意子域名和任意 VPS 上。注意：

- 新 VPS 上 acme.sh 还没保存过 Token，第一次部署要输入一次；之后自动续签用本机保存的那份。
- CF 只在创建时显示一次完整 Token。没留底的话，可在已部署的 VPS 上查：`grep SAVED_CF_Token ~/.acme.sh/account.conf`。不要为此去点「轮换」，轮换后旧值立即失效，已部署机器的自动续签会失败。
- 设置了 IP 筛选的，先把新 VPS 的 IP 加进去（见上一条）。
- 每台 VPS 用不同的子域名；两台用同一个子域名时，A 记录会被改到新 IP，旧节点就连不上了。

### Token 看不到区域（`count:0`）

检查 Token 的「区域资源」是否包含该主域名所在区域，以及在 CF 上编辑后是否点了「更新令牌」保存。

## 附带：麻将连连看

[`lianliankan.html`](lianliankan.html) 是一个单文件、无依赖的麻将连连看小游戏（万 / 筒 / 条 / 风 / 箭，三档难度，提示、重排、最佳用时）。可以直接用浏览器打开，也可以放进伪装站目录作为一个页面：

```bash
curl -fsSL https://github.com/zhuoyi0918/Reality-Site-OneClick/releases/latest/download/lianliankan.html \
  -o /var/www/123456/lianliankan.html
```

## 网站内容建议

纯静态 HTML/CSS，不放大文件或视频。
