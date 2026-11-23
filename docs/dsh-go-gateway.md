# DSH Go 私有直连通道：电脑端安装与配对说明

> 适用于 DSH Go（iOS，巨魔/越狱环境可直接安装未签名 IPA）。
>
> 本文所有域名、端口、令牌一律用占位符表示，**按你自己的环境替换**：
>
> | 占位符 | 含义 | 示例 |
> |---|---|---|
> | `YOUR_DOMAIN` | 你拥有并可解析的域名 | `example.com` |
> | `TUNNEL_PORT` | 隧道服务分配给你的公网端口 | `42429` |
> | `LOCAL_WEB_PORT` | DSH 网页版在本机监听的端口（每次启动可能变化） | `9799` |
> | `GATEWAY_PORT` | 移动网关监听端口，默认 `3081` | `3081` |
> | `PHONE_LAN_IP` | 电脑在局域网的地址 | `192.168.1.20` |

---

## 0. 这套方式解决什么问题

DSH Go 原本通过 `ds-harness-remote` 插件走公网中继（relay）+ WebRTC：

```
手机 ──► 中继服务器 ──► 电脑
        （对称 NAT 下 100% 走 TURN 转发，实测建立连接 34~85 秒，会断）
```

本方案换成一条**单连接 WebSocket**：

```
手机 ──wss──► 你自己的域名（TLS） ──► 隧道 ──► 本机网关 /ws/mobile ──► DSH
```

| 维度 | 中继方案 | 本方案 |
|---|---|---|
| 建连 | 34~85 秒，对称 NAT 下必走 TURN | 一次 TLS + 一次 WS 升级，实测秒级 |
| 数据路径 | 中继（第三方）+ TURN 转发 | 你的域名 → 你的隧道 → 你的电脑 |
| 会话列表 | 面板预热抢 Node 单线程，列表慢 | 网关直接回 `sessions` 帧，自带标题 |
| 账号依赖 | 需登录 DSH Remote（GitHub/知乎/Google/QQ） | **不需要任何账号**，配对码即可 |

两条通道**并存**，原中继方式完全保留，随时可切回。

---

## 1. 前置条件

- 电脑上已安装并运行 DSH（本文按 DSH `0.2.2-rc.5` 编写）
- 有一个域名，且能修改它的 DNS 记录（用 DNS-01 验证签证书时需要）
- 一个能把本机端口暴露到公网的方式，三选一：
  - **A. 内网穿透服务**（natfrp / 花生壳 / frp 服务端等）
  - **B. Cloudflare Tunnel**（cloudflared）
  - **C. 有公网 IP 的 VPS + 反向代理**
- 手机与电脑在同一局域网时，也可以先用局域网地址不用隧道（见 §9）

---

## 2. 第一步：安装移动网关插件

插件名：`dsh-plugin-mobile-gateway`

### 2.1 通过插件市场安装

DSH 网页版 → 设置 → 插件 → 搜索 `mobile gateway` → 安装 → 重启 DSH。

### 2.2 手动安装（离线场景）

把插件目录放到 DSH 的插件位置后重启。安装完成后确认：

```bash
# 列出已安装插件
dsh plugin list

# 期望能看到
#   dsh-plugin-mobile-gateway  0.12.2
#   ds-harness-remote          0.6.7      ← 原中继插件，保留不要卸载
```

> 两个插件可以同时存在，互不干扰。

---

## 3. 第二步：打开移动网关

DSH 网页版 → 设置 → 移动设备（或"连接与配对"）→ 打开**移动网关**，并把模式设为**常驻**：

| 配置项 | 建议值 | 说明 |
|---|---|---|
| `gatewayEnabled` | `true` | 打开网关 |
| `gatewayMode` | `persistent` | 常驻，DSH 重启后仍在 |
| 监听端口 | `3081` | 默认值，被占用时换一个 |
| `webrtc.enabled` | `false` | 本方案纯 WebSocket，关掉省资源 |

开启后本机应能访问：

```bash
curl -s http://127.0.0.1:3081/mgw/status
```

返回里应包含 `"gatewayEnabled":true`、`"gatewayMode":"persistent"`。

> `/mgw/*` 这组接口挂在 **DSH 网页版自己的端口**上（`LOCAL_WEB_PORT`），不是网关端口。所以 `status`、`devices`、`pair` 都打在 `http://127.0.0.1:LOCAL_WEB_PORT/mgw/...`。
>
> DSH 每次启动端口可能变化，脚本里应自动探测（见 §7.2）。

---

## 4. 第三步：把网关暴露到公网

网关只监听本机 `/ws/mobile`，需要一个 TLS 入口。**必须用 TLS**：App 只接受 `wss://`。

### 方案 A：内网穿透服务（推荐，无需公网 IP）

以 natfrp 为例：

1. 控制台新建一条 **TCP 隧道**：本地地址 `127.0.0.1`，本地端口填 **反向代理的 HTTPS 端口**（下文用 `7789`），不要直接填 3081
2. 隧道会给你一个公网端口 `TUNNEL_PORT`
3. 如需自定义域名访问，在该隧道的域名设置里绑定 `YOUR_DOMAIN` 并加一条 DNS 记录指向隧道入口
4. 免费账号通常只给 1~2 条隧道，注意配额

> 为什么中间要加一层反代？因为隧道只做 TCP 转发，没有证书；而 App 要 `wss://`。证书由本机的 Caddy 提供（§5）。

### 方案 B：Cloudflare Tunnel

```bash
# 安装 cloudflared 后
cloudflared tunnel login
cloudflared tunnel create dsh-gateway
cloudflared tunnel route dns dsh-gateway YOUR_DOMAIN
```

`~/.cloudflared/config.yml`：

```yaml
tunnel: dsh-gateway
credentials-file: /path/to/<tunnel-id>.json
ingress:
  - hostname: YOUR_DOMAIN
    service: https://127.0.0.1:7789
    originRequest:
      noTLSVerify: true
  - service: http_status:404
```

```bash
cloudflared tunnel run dsh-gateway
```

这种方式公网端口是默认的 443，配对地址写 `wss://YOUR_DOMAIN/ws/mobile`（不带端口）。

### 方案 C：VPS + 反向代理

VPS 上用 Nginx/Caddy 把 `YOUR_DOMAIN` 反代到一条从电脑发起的 SSH 反向隧道：

```bash
# 在电脑上（把 VPS 的 7789 映射回本机 7789）
ssh -N -R 7789:127.0.0.1:7789 user@YOUR_VPS
```

VPS 侧 Caddy：

```
YOUR_DOMAIN {
    reverse_proxy 127.0.0.1:7789
}
```

---

## 5. 第四步：本机 TLS 反向代理（Caddy）

网关本身不提供 TLS，用 Caddy 在 `7789` 上终止 TLS 并转发到 `3081`。

`Caddyfile`：

```
YOUR_DOMAIN:7789 {
    reverse_proxy 127.0.0.1:3081
}
```

启动：

```bash
caddy run --config Caddyfile
```

用 DNS-01 自动签证书（域名没有 80/443 公网入口时必须）：

```bash
# Cloudflare 托管 DNS 的例子，令牌只放在环境变量里，不要写进文件
export CF_DNS_API_TOKEN=YOUR_CLOUDFLARE_TOKEN
caddy run --config Caddyfile
```

证书落地后验证：

```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://YOUR_DOMAIN:TUNNEL_PORT/ws/mobile
```

- 返回 **`401`** → 正确（未鉴权的 WebSocket 升级被拒绝）
- 返回 `502/504` → 反向代理或网关没起来
- 证书报错 → 检查 DNS-01 记录、令牌权限（需要 `Zone.DNS:Edit`）

---

## 6. 第五步：确认公网链路通

从**外网**（手机蜂窝网络，不要用 Wi-Fi）访问：

```bash
curl -sS -v https://YOUR_DOMAIN:TUNNEL_PORT/ws/mobile 2>&1 | grep -Ei 'SSL certificate verify|HTTP/'
```

期望：

```
SSL certificate verify ok.
< HTTP/1.1 401 Unauthorized
```

`401` 是**成功标志** —— 说明 TLS 通了、路径对了、只是没带设备令牌。

---

## 7. 第六步：生成配对码

配对码是一个 **Base64URL（无 padding）编码的 JSON**，`version: 2`，**5 分钟过期**。

载荷结构：

```json
{
  "version": 2,
  "publicUrl": "wss://YOUR_DOMAIN:TUNNEL_PORT/ws/mobile",
  "endpoints": [
    "wss://YOUR_DOMAIN:TUNNEL_PORT/ws/mobile",
    "ws://PHONE_LAN_IP:3081/ws/mobile"
  ],
  "pairingCode": "<服务端生成的一次性码>",
  "expiresAt": 1700000000000,
  "gatewayId": "<网关 id>",
  "gatewayName": "<网关显示名>"
}
```

### 7.1 用面板生成

DSH 网页版 → 设置 → 移动设备 → **生成配对码**。页面会显示二维码和可复制的文本，用它直接配对即可。

### 7.2 用脚本生成（可选，适合反复出码）

脚本要做四件事：

1. 探测 DSH 网页端口（`LOCAL_WEB_PORT`）——在监听端口里找返回 `/mgw/status` 的那个
2. 确认网关已开启（必要时 `POST /mgw/connection` 设为 `persistent`）
3. `POST http://127.0.0.1:LOCAL_WEB_PORT/mgw/pair`，请求体带 `publicUrl`（就是 §6 验证过的那个 `wss://` 地址）
4. 把返回的 `payload` 写进文本文件 + 生成二维码 SVG，并复制到剪贴板

PowerShell 骨架：

```powershell
# 1) 探测端口
$port = $null
Get-NetTCPConnection -State Listen | ForEach-Object {
    $p = $_.LocalPort
    $s = curl.exe -s --max-time 2 "http://127.0.0.1:$p/mgw/status"
    if ($s -match 'gatewayEnabled') { $port = $p; break }
}

# 2) 出码
$publicUrl = "wss://YOUR_DOMAIN:TUNNEL_PORT/ws/mobile"
$body = @{ publicUrl = $publicUrl } | ConvertTo-Json -Compress
$resp = Invoke-RestMethod "http://127.0.0.1:$port/mgw/pair" -Method Post `
          -ContentType 'application/json' -Body $body

# 3) 落地
$resp.payload | Set-Content DSH配对码.txt -Encoding UTF8
$resp.payload | Set-Clipboard
```

> 二维码内容就是这段 `payload` 原文。用任意二维码生成器把它转成 SVG/PNG 即可，App 的扫码入口能直接读。

### 7.3 查看已配对设备

```bash
curl -s http://127.0.0.1:LOCAL_WEB_PORT/mgw/devices
```

返回设备列表（`id` / `name` / 权限）。每个 App 每次成功配对都会新增一条设备记录，各自持有独立令牌。

---

## 8. 第七步：手机上配对

装好 DSH Go 后，`远程主机`页面有**三条路**，全部通向同一个网关：

| 入口 | 位置 | 适合 |
|---|---|---|
| `移动网关` → `添加移动网关` | 远程主机页独立分区，**不需要登录任何账号** | 粘贴配对串 |
| `扫码配对电脑`（相机） | `DSH Remote` 卡片内 | 对着电脑屏幕上的二维码扫 |
| `粘贴配对链接` / `从相册识别` | 同上 | 剪贴板里的配对串，或相册里的二维码截图 |

App 会**自动识别**扫到/粘到的东西：

- 是网关载荷（Base64URL JSON，以 `eyJ` 开头）→ 走本方案的直连配对
- 不是 → 原样交给 `ds-harness-remote` 的中继配对流程，行为与以前完全一致

配对成功后 App 会提示 `已添加移动网关：<名称>`，并自动把它设为当前主机。

### 配对成功后的验证

电脑侧再查一次：

```bash
curl -s http://127.0.0.1:LOCAL_WEB_PORT/mgw/status
```

`connectedClients` 会从原来的值增加 2（App 打开两条通道：控制 + 事件）。

---

## 9. 只用局域网（不折腾隧道）

同一 Wi-Fi 下可以直接用局域网地址，跳过 §4~§6：

```bash
curl -sS -o /dev/null -w "%{http_code}\n" http://PHONE_LAN_IP:3081/ws/mobile
# 期望 401
```

配对时把 `publicUrl` 换成 `ws://PHONE_LAN_IP:3081/ws/mobile` 即可（局域网内不需要 TLS）。

适合先验证链路是否通，再上隧道。

---

## 10. 排错表

| 现象 | 原因 | 处理 |
|---|---|---|
| 配对页提示"配对串无效或已过期" | 超过 5 分钟，或复制不完整 | 重新生成；注意整串不能断行 |
| 提示"网关要求重新配对"（auth） | 设备记录被撤销，或令牌被清 | 重新生成配对码 |
| 提示"电脑上的移动网关已关闭" | `gatewayEnabled` 被关掉了 | 重新开启并设为 `persistent` |
| 提示"连不上网关地址" | 隧道断、证书错、端口不通 | 回 §6 逐条验：`curl` 必须拿到 `401` |
| `curl` 拿到 `502` | 反向代理起来了但网关没起 | 查 `http://127.0.0.1:GATEWAY_PORT/mgw/status` |
| 证书校验失败 | DNS-01 没成功 / 令牌权限不够 | 看 Caddy 日志里的 ACME 报错 |
| 连上但列表空 | 网关没订阅到会话 | 查 `/mgw/status` 的 `connectedClients` 是否增加 |
| 换网络后一连就断 | 公网端口变了 | 重新生成配对码，把新 `publicUrl` 带上 |

---

## 11. 安全须知

1. **配对码等同临时钥匙**：5 分钟内有效，一次性使用，不要贴到群里或截图外发
2. **令牌存在系统钥匙串**：App 侧写在 Keychain（`gateway.<网关id>.token`），不进普通配置文件
3. **每个 App 一台设备**：`/mgw/devices` 里能看到全部设备；不用的一定要撤销
4. **不要直接把网关端口暴露到公网**：中间必须有 TLS 反向代理，否则 `ws://` 明文传输
5. **隧道与 DNS 令牌只放环境变量**，不要提交到仓库
6. 本文档中所有 `YOUR_DOMAIN` / `TUNNEL_PORT` / 令牌均为占位符

---

## 12. 与原有中继方式的关系

- 两条通道**互不影响**，`ds-harness-remote` 保持原样
- `远程主机`页里，中继主机与移动网关主机**并列显示**，随时切换
- 想彻底停用中继：退出 DSH Remote 账号即可，移动网关分区不受影响
