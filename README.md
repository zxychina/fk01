⚠️ 严正声明 (License & Copyright)
本项目采用 CC BY-NC 4.0 协议进行分发。
无论你是直接 Fork、修改源码还是重新分发，都必须保留原作者的署名，且严禁用于任何商业牟利行为。一经发现侵权，作者保留追究责任的权利。

# 🚀 科学上网节点极速部署指南 (Sing-box + Cloudflare Tunnel)

本项目提供了一个基于 Docker 容器的轻量级、高隐匿性科学上网节点部署方案。通过集成 `sing-box`、`cloudflared` 和 `HAProxy`，你可以轻松地在各类云平台（如 Railway、Koyeb、Render 等）或个人 VPS 上一键构建安全隧道。

## ✨ 核心特性

* **轻量高效**：基于 Alpine Linux 和 Docker 构建，占用资源极低。
* **高隐匿性**：利用 Cloudflare Tunnel 穿透内网，隐藏真实服务器 IP，有效防封锁。
* **协议齐全**：采用 `sing-box` 核心，支持 VLESS、VMess、Trojan 三种主流协议。
* **优选IP自动测速**：启动时并行测量 TLS 连接延迟，随机选取最优域名，降低风控概率。
* **定时刷新**：可配置定时任务（默认每 6 小时）自动重新优选，保持线路质量。
* **多协议订阅**：自动生成标准订阅（base64 URI）、Clash YAML 和原始节点列表。
* **流媒体解锁**：支持可选的 Cloudflare WARP 出站，自动分流海外域名和流媒体流量。
* **订阅认证**：可选启用 `SUBSCRIBE_KEY`，防止订阅链接泄露导致凭证暴露。
* **自动化构建**：已配置 GitHub Actions，推送 main 分支自动打包 Docker 镜像到 GitHub Packages (`ghcr.io`)。
* **健康检查**：Docker HEALTHCHECK 持续监控订阅接口可用性。

---

## 📦 项目结构

| 文件 | 说明 |
| :--- | :--- |
| `Dockerfile` | 自动拉取 sing-box、cloudflared、haproxy，构建轻量容器镜像 |
| `config.json` | sing-box 协议配置文件（UUID/TROJAN_PASSWORD 由启动时动态替换） |
| `start.sh` | 容器入口脚本：测速优选 → 生成订阅 → 启动 sing-box → HAProxy → cloudflared |
| `haproxy.cfg` | HTTP/WebSocket 路径路由 + 订阅认证控制 |
| `.github/workflows/main.yml` | GitHub Actions 自动构建并推送 Docker 镜像到 ghcr.io |

---

## 🛠️ 部署教程

### 准备工作

1. **Cloudflare Tunnel（必选）**：
   - 登录 [Cloudflare Zero Trust](https://dash.teams.cloudflare.com/) 面板。
   - 导航至 **Networks** -> **Tunnels**，创建一个新的 Tunnel。
   - 保存生成的 **Tunnel Token**（即 `ARGO_TOKEN`）。
   - 为该 Tunnel 配置一个 **Public Hostname**（例如 `proxy.yourdomain.com`），并将服务指向 **`http://localhost:7080`**。

2. **生成 UUID**：
   - 使用在线工具或命令行（如 `uuidgen`）生成一个符合标准格式的 UUID。

3. **设置环境变量**：

| 变量名 | 必需 | 说明 | 示例 |
| :--- | :---: | :--- | :--- |
| `UUID` | ✅ | 节点连接密码 | `your-uuid-here` |
| `TROJAN_PASSWORD` | ✅ | Trojan 协议密码 | `your-password-here` |
| `ARGO_TOKEN` | ✅ | Cloudflare Tunnel Token | `eyJh...` |
| `VLESS_DOMAIN` | ✅ | VLESS 协议 SNI/Host 域名 | `a.b.c.d` |
| `VMESS_DOMAIN` | ✅ | VMess 协议 SNI/Host 域名 | `e.f.g.h` |
| `TROJAN_DOMAIN` | ✅ | Trojan 协议 SNI/Host 域名 | `i.j.k.l` |
| `SUBSCRIBE_KEY` | ⚪ | 订阅认证密钥，为空则无需认证 | `my-secret-key` |
| `ENABLE_WARP` | ⚪ | 是否启用 Cloudflare WARP 出站 | `true` 或 `false` |
| `REFRESH_INTERVAL` | ⚪ | 定时优选间隔（小时），`0` 关闭 | `6` |
| `PREFERRED_IP_LIST` | ⚪ | 自定义测速列表（空格分隔域名） | `cf.tencentapp.cn cloudflare.182682.xyz` |

> 💡 **订阅使用方法**：若设置了 `SUBSCRIBE_KEY`，请求订阅时需携带 `X-Key` 请求头，或在 URL 中使用 `?key=` 参数：
> ```
> https://你的域名/subscribe.txt?key=你的密钥
> https://你的域名/clash.yaml?key=你的密钥
> ```

### 开始部署

在部署平台（如 Railway）创建新应用时，请填写上述环境变量，平台会自动从 GitHub 仓库构建。

---

## 📡 客户端连接

### 快捷分享链接

VLESS：
```
vless://你的UUID@你的Tunnel域名:443?encryption=none&security=tls&sni=你的VLESS_DOMAIN&type=ws&host=你的VLESS_DOMAIN&path=%2Fvless#Railway-VLESS
```

Trojan：
```
trojan://你的TROJAN_PASSWORD@你的Tunnel域名:443?security=tls&sni=你的TROJAN_DOMAIN&type=ws&host=你的TROJAN_DOMAIN&path=%2Ftrojan#Railway-Trojan
```

### 手动配置（v2rayN / Clash 等）

| 字段 | 值 |
| :--- | :--- |
| 地址 | 你的 Public Hostname |
| 端口 | 443 |
| UUID | `$UUID` |
| 传输协议 | ws |
| 路径 | /vless |
| SNI | `$VLESS_DOMAIN` |
| TLS | 开启 |

### 订阅链接

- **标准订阅**：`https://你的域名/subscribe.txt?key=${SUBSCRIBE_KEY}`
- **Clash 订阅**：`https://你的域名/clash.yaml?key=${SUBSCRIBE_KEY}`
- **原始节点**：`https://你的域名/nodes.txt?key=${SUBSCRIBE_KEY}`

---

## ⚙️ 进阶功能

### Cloudflare WARP 出站（解锁流媒体）

若需要解锁 Netflix、ChatGPT 等流媒体，设置以下环境变量：

```
ENABLE_WARP=true
WARP_PRIVATE_KEY=你的WARP私钥
WARP_ADDRESS=162.15.192.1  # WARP IPv4
```

生成 WARP 私钥的方法：

```bash
wg genkey | tee /tmp/private.key | wg pubkey
# 将第一行输出设为 WARP_PRIVATE_KEY
# 将第二行输出设为 WARP_ADDRESS（可选，默认已内置）
```

启用后，sing-box 会自动将以下域名的流量路由至 WARP：
- YouTube、Netflix、OpenAI、Anthropic、Google Video 等
- 国内 IP 段 (`geoip:cn`) 直连不走代理

---

## 🐳 Docker 构建 & GitHub Actions

项目已内置 GitHub Actions，推送到 `main` 分支后会自动构建 Docker 镜像并推送到 GitHub Container Registry (`ghcr.io`)。

如需手动拉取镜像：
```bash
docker pull ghcr.io/<你的用户名>/<仓库名>:latest
```

---

> **Disclaimer**: 本项目仅供学习和交流网络协议之用，请在遵守当地法律法规的前提下使用。
>
> ⚠️ 严正声明 (License & Copyright)
> 本项目采用 CC BY-NC 4.0 协议进行分发。
> 无论你是直接 Fork、修改源码还是重新分发，都必须保留原作者的署名，且严禁用于任何商业牟利行为。一经发现侵权，作者保留追究责任的权利。
