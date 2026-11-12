#!/bin/sh
# 不再全局 set -e：测速/订阅生成过程中有较多"失败属正常"的命令（curl 超时、空结果），
# set -e 会导致脚本在这些非致命错误时整体退出，订阅文件永远不生成。
# 改用命令级 || true 兜底 + 关键校验 : "${VAR:?}" 严格中断。
set -u

# 优雅退出：收到 SIGTERM 时，先停所有子进程再退出
cleanup() {
  echo "收到关闭信号，正在停止进程..."
  kill $(jobs -p) 2>/dev/null || true
  wait
  echo "所有进程已停止，退出。"
  exit 0
}
trap cleanup TERM INT

echo "========== start.sh 已执行 =========="

# 调试：检查必需的环境变量是否已设置（不打印值，避免泄露敏感信息）
echo "========== 环境变量检查 =========="
for v in UUID TROJAN_PASSWORD ARGO_TOKEN VLESS_DOMAIN VMESS_DOMAIN TROJAN_DOMAIN; do
  eval "val=\${$v}"
  if [ -n "$val" ]; then
    echo "  ✓ $v (已设置, 长度: ${#val})"
  else
    echo "  ✗ $v (未设置或为空)"
  fi
done
echo "=================================="

: "${UUID:?UUID is required}"
: "${TROJAN_PASSWORD:?TROJAN_PASSWORD is required}"
: "${ARGO_TOKEN:?ARGO_TOKEN is required}"

: "${VLESS_DOMAIN:?VLESS_DOMAIN is required}"
: "${VMESS_DOMAIN:?VMESS_DOMAIN is required}"
: "${TROJAN_DOMAIN:?TROJAN_DOMAIN is required}"

# ========== 可选变量集中初始化 ==========
# 在脚本开头一次性给所有可选变量赋默认值，避免 set -u 下裸引用触发
# "parameter not set"。后续代码可直接裸用 $ENABLE_WARP / $REFRESH_INTERVAL 等。
ENABLE_WARP="${ENABLE_WARP:-false}"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-6}"
AUTO_PREFERRED_IP="${AUTO_PREFERRED_IP:-true}"
PREFERRED_ADDR="${PREFERRED_ADDR:-}"
WARP_PRIVATE_KEY="${WARP_PRIVATE_KEY:-}"
WARP_ADDRESS="${WARP_ADDRESS:-}"
WARP_PUBLIC_KEY="${WARP_PUBLIC_KEY:-}"
WARP_ENDPOINT="${WARP_ENDPOINT:-}"
WARP_STREAM_OUTBOUND="${WARP_STREAM_OUTBOUND:-warp}"

# 动态优选域名来源（支持空格分隔多 URL，第一个有内容就用）
# 默认从 bestcf.pages.dev 迷你版拉取，可改为 "https://bestcf.pages.dev/domain/Domain-Asia.txt" 等
PREFERRED_DOMAIN_SOURCE="${PREFERRED_DOMAIN_SOURCE:-https://bestcf.pages.dev/domain/mini.txt}"
# 最多测速域名数（太多会慢，默认 40）
MAX_TEST_COUNT="${MAX_TEST_COUNT:-40}"
# 从预检通过的域名里取前几个作为订阅节点 + 当前节点（默认 5）
PICK_COUNT="${PICK_COUNT:-5}"

# 订阅密钥（可为空，为空则不要求认证）
# Railway 环境变量里如果用户不小心把注释 / 空格写进值的尾部，
# 这里自动清理：去掉前后空格、#号及其后所有内容。
_raw_key="${SUBSCRIBE_KEY:-}"
# 先截掉 # 号后的注释部分
SUBSCRIBE_KEY="${_raw_key%%#*}"
# 去前后空格（xargs 对纯空格的结果是空，正好）
SUBSCRIBE_KEY=$(echo "$SUBSCRIBE_KEY" | xargs)
unset _raw_key
export SUBSCRIBE_KEY

if [ -n "$SUBSCRIBE_KEY" ]; then
  echo "✓ SUBSCRIBE_KEY 已设置（${#SUBSCRIBE_KEY} 字符，已自动清理空格和注释）"
else
  echo "ℹ SUBSCRIBE_KEY 未设置 → 订阅公开访问（建议设置防止泄露）"
fi

SUBSCRIBE_DIR="/app/subscribe"
mkdir -p "$SUBSCRIBE_DIR"

# ========== 动态拉取优选域名列表 ==========
# 从 bestcf.pages.dev 拉取最新优选域名，支持环境变量自定义来源
# 格式：host:port#备注 （每行一个）
# 拉取失败或为空 → fallback 本地硬编码列表
fetch_domain_list() {
  # 可自定义来源（URL），默认从 bestcf.pages.dev 拉
  SOURCES="${PREFERRED_DOMAIN_SOURCE:-https://bestcf.pages.dev/domain/mini.txt}"

  REMOTE_LIST=""
  for src in $SOURCES; do
    echo "  拉取优选域名源: $src" >&2
    tmp=$(curl -sS --connect-timeout 5 --max-time 10 "$src" 2>/dev/null) || true
    if [ -n "$tmp" ]; then
      REMOTE_LIST="$REMOTE_LIST"$'\n'"$tmp"
    fi
  done

  if [ -n "$REMOTE_LIST" ]; then
    # 解析 "host:port#备注" 格式，提取 host 部分：
    #   1. 每行取 # 前的部分（去备注）
    #   2. 再取 : 前的部分（去端口）
    #   3. 去空行、去重、排序
    CLEAN=$(echo "$REMOTE_LIST" \
      | sed 's/#.*//' \
      | sed 's/:.*//' \
      | sed '/^$/d' \
      | sort -u)

    COUNT=$(echo "$CLEAN" | wc -l)
    echo "  ✓ 远程拉取成功: $COUNT 个唯一地址" >&2

    # 限制最多取 MAX_TEST_COUNT（默认 40）个，避免测速太久
    MAX_TEST_COUNT="${MAX_TEST_COUNT:-40}"
    if [ "$COUNT" -gt "$MAX_TEST_COUNT" ]; then
      CLEAN=$(echo "$CLEAN" | head -"$MAX_TEST_COUNT")
      echo "  ℹ 过多，截断为前 $MAX_TEST_COUNT 个（$COUNT 总数）" >&2
    fi

    echo "$CLEAN"
    return 0
  fi

  # === fallback: 本地硬编码列表 ===
  echo "  ✗ 远程拉取失败，使用本地备用列表" >&2
  echo "cf.tencentapp.cn"
  echo "cloudflare.182682.xyz"
  echo "cm.cloudflare.byoip.top"
  echo "cmcc.877774.xyz"
  echo "ct.877774.xyz"
  echo "ct.cloudflare.byoip.top"
  echo "cu.877774.xyz"
  echo "cu.cloudflare.byoip.top"
  echo "r2.dev"
  echo "static.cloudflareinsights.com"
  echo "cf.877774.xyz"
  echo "www.shopify.com"
  echo "www.asda.com"
  echo "www.emerson.com"
  echo "markmonitor.com"
  echo "openai.com"
  echo "www.sage.com"
  echo "investor.apple.com"
  echo "www.speedtest.net"
  echo "www.affirm.com"
  echo "digitalocean.com"
  echo "chrono24.com"
  echo "cdn.jsdelivr.net"
  echo "www.broadcom.com"
  echo "www.nestle.com"
  echo "visit.honeywell.com"
  echo "polestar.com"
  echo "deepin.org"
  echo "engage.cloudflareclient.com"
  echo "cloudflare.dev"
  echo "pages.dev"
  echo "cdnjs.com"
  echo "cloudflare-ech.com"
  return 1
}

# ========== 测速优选函数 ==========
# 策略：bestcf.pages.dev 本身就是社区优选好的 Top 列表（每半小时更新），
# Railway 容器在 Cloudflare 内网，curl Cloudflare 域名全是 ~0ms，
# 二次延迟测速没有意义，所以这里改成：
#   1. 从 bestcf 拉最新列表
#   2. 做快速连通性预检（curl --connect-timeout 2 --max-time 3，能通就行）
#   3. 取预检通过的前 K 个（默认 5），作为订阅节点 + 当前 PREFERRED_ADDR
#   4. bestcf 拉不到 → fallback 本地硬编码 + 同样的预检逻辑
#
# 为什么要预检？bestcf 也会失效一些域名，预检能过滤掉不能连的。
# 为什么不测延迟？内网对 CF 域名全是 0ms，测了白测。
run_speedtest() {
  if [ "${AUTO_PREFERRED_IP:-true}" != "true" ] || [ -n "${PREFERRED_ADDR:-}" ]; then
    # 手动指定了 PREFERRED_ADDR 或关闭了自动优选，跳过测速
    VLESS_ADDR="${PREFERRED_ADDR:-$VLESS_DOMAIN}"
    VMESS_ADDR="${PREFERRED_ADDR:-$VMESS_DOMAIN}"
    TROJAN_ADDR="${PREFERRED_ADDR:-$TROJAN_DOMAIN}"
    return 0
  fi

  echo "========== 自动检测优选IP =========="

  PICK_COUNT="${PICK_COUNT:-5}"  # 从预检通过的域名里取前几个作为节点
  echo "目标: 从最新优选列表里预检连通性，取前 $PICK_COUNT 个可用的..."

  # 优先级：环境变量 PREFERRED_IP_LIST > 远程拉取 bestcf > 本地硬编码
  if [ -n "${PREFERRED_IP_LIST:-}" ]; then
    echo "ℹ 使用自定义 PREFERRED_IP_LIST（跳过远程拉取）"
    IP_LIST="$PREFERRED_IP_LIST"
  else
    echo "正在从 bestcf.pages.dev 拉取最新优选域名列表..."
    IP_LIST=$(fetch_domain_list)
  fi

  # 过滤空行、去重、取前 MAX_TEST_COUNT 个
  IP_LIST=$(echo "$IP_LIST" | grep -v '^[[:space:]]*$' | sort -u | head -"${MAX_TEST_COUNT:-40}")
  TOTAL=$(echo "$IP_LIST" | grep -c .)
  echo "候选地址总数: $TOTAL"

  if [ "$TOTAL" -eq 0 ]; then
    echo "✗ 候选列表为空，使用默认域名"
    VLESS_ADDR="$VLESS_DOMAIN"
    VMESS_ADDR="$VMESS_DOMAIN"
    TROJAN_ADDR="$TROJAN_DOMAIN"
    echo "============================="
    return 0
  fi

  # 并行预检连通性（只看能不能通，不测延迟）
  # 能通就在 $TEST_DIR/<ip> 里写个 "ok"，不通就跳过
  TEST_DIR="/tmp/speedtest"
  rm -rf "$TEST_DIR"
  mkdir -p "$TEST_DIR"

  for IP in $IP_LIST; do
    (
      # 只取 host 部分（万一还有端口混进来）
      HOST="${IP%%:*}"
      [ -z "$HOST" ] && exit 0
      curl -o /dev/null -s --connect-timeout 2 --max-time 3 \
        -k "https://$HOST" 2>/dev/null && echo "ok" > "$TEST_DIR/$HOST"
    ) &
  done
  wait

  # 收集预检通过的地址（保留原顺序，取前 PICK_COUNT 个）
  PASSED=""
  PASSED_COUNT=0
  for IP in $IP_LIST; do
    HOST="${IP%%:*}"
    if [ -f "$TEST_DIR/$HOST" ]; then
      PASSED="$PASSED${HOST}"$'\n'
      PASSED_COUNT=$((PASSED_COUNT + 1))
      [ "$PASSED_COUNT" -ge "$PICK_COUNT" ] && break
    fi
  done
  rm -rf "$TEST_DIR"

  # 去掉尾空行
  PASSED=$(echo "$PASSED" | grep -v '^[[:space:]]*$')

  if [ "$PASSED_COUNT" -gt 0 ]; then
    echo ""
    echo "✓ 预检通过 $PASSED_COUNT / $TOTAL 个地址:"
    echo "$PASSED" | awk '{printf "  %s\n", $1}'
    echo ""

    # 保存到 /tmp/top_ips.txt（去尾空行，避免 wc -l 多算）
    echo "$PASSED" | grep -v '^[[:space:]]*$' > /tmp/top_ips.txt

    # 从预检通过的列表里随机选一个作为当前 PREFERRED_ADDR
    # （订阅里仍然是全部 $PASSED_COUNT 个，客户端自己挑）
    PICK_INDEX=$(( (RANDOM % PASSED_COUNT) + 1 ))
    PREFERRED_ADDR=$(echo "$PASSED" | sed -n "${PICK_INDEX}p")
    echo "✓ 当前节点随机选: $PREFERRED_ADDR (候选共 $PASSED_COUNT 个)"
  else
    echo "⚠ 预检全挂（可能容器出网有问题），直接用第一个候选"
    FIRST=$(echo "$IP_LIST" | grep -v '^[[:space:]]*$' | head -1 | sed 's/:.*//')
    echo "$FIRST" > /tmp/top_ips.txt
    PREFERRED_ADDR="$FIRST"
  fi
  echo "============================="

  VLESS_ADDR="${PREFERRED_ADDR:-$VLESS_DOMAIN}"
  VMESS_ADDR="${PREFERRED_ADDR:-$VMESS_DOMAIN}"
  TROJAN_ADDR="${PREFERRED_ADDR:-$TROJAN_DOMAIN}"
}

# ========== 生成订阅文件函数 ==========
generate_subscriptions() {
  echo "========== 生成订阅文件 =========="

  TOP_IPS_FILE="/tmp/top_ips.txt"
  if [ -s "$TOP_IPS_FILE" ]; then
    ALL_IPS=$(cat "$TOP_IPS_FILE")
    IP_COUNT=$(echo "$ALL_IPS" | wc -l)
    echo "使用 $IP_COUNT 个优选地址生成多节点订阅..."
  else
    ALL_IPS="$VLESS_DOMAIN"
    IP_COUNT=1
    echo "$VLESS_DOMAIN" > "$TOP_IPS_FILE"
    echo "未检测到优选IP，使用单节点订阅..."
  fi

  # 清空节点列表文件
  > "$SUBSCRIBE_DIR/nodes.txt"

  INDEX=0
  while IFS= read -r IP; do
    [ -z "$IP" ] && continue
    INDEX=$((INDEX + 1))
    PAD=$(printf "%02d" $INDEX)

    # VLESS 节点
    echo "vless://$UUID@$IP:443?encryption=none&security=tls&sni=$VLESS_DOMAIN&type=ws&host=$VLESS_DOMAIN&path=%2Fvless#VLESS-${PAD}" >> "$SUBSCRIBE_DIR/nodes.txt"

    # Trojan 节点
    echo "trojan://$TROJAN_PASSWORD@$IP:443?security=tls&sni=$TROJAN_DOMAIN&type=ws&host=$TROJAN_DOMAIN&path=%2Ftrojan#Trojan-${PAD}" >> "$SUBSCRIBE_DIR/nodes.txt"

    # VMess 节点
    VMESS_URI="vmess://$(printf '{"v":"2","ps":"VMess-%s","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"/vmess","tls":"tls","sni":"%s"}' "$PAD" "$IP" "$UUID" "$VMESS_DOMAIN" "$VMESS_DOMAIN" | base64 -w 0)"
    echo "$VMESS_URI" >> "$SUBSCRIBE_DIR/nodes.txt"
  done < "$TOP_IPS_FILE"

  TOTAL_NODES=$(( INDEX * 3 ))
  echo "已生成 $TOTAL_NODES 个节点（${INDEX}个地址 × 3种协议）"

  # 标准订阅（base64 编码节点列表，v2rayN 等客户端可用）
  base64 -w 0 "$SUBSCRIBE_DIR/nodes.txt" > "$SUBSCRIBE_DIR/subscribe.txt"

  # 同时提供 Clash 订阅格式
  cat > "$SUBSCRIBE_DIR/clash.yaml" << YAML
mixed-port: 7890
mode: rule
proxies:
YAML

  INDEX=0
  while IFS= read -r IP; do
    [ -z "$IP" ] && continue
    INDEX=$((INDEX + 1))
    PAD=$(printf "%02d" $INDEX)

    cat >> "$SUBSCRIBE_DIR/clash.yaml" << YAML
  - name: VLESS-${PAD}
    type: vless
    server: $IP
    port: 443
    uuid: $UUID
    network: ws
    tls: true
    udp: true
    ws-opts:
      path: /vless
      headers:
        Host: $VLESS_DOMAIN
    servername: $VLESS_DOMAIN
  - name: VMess-${PAD}
    type: vmess
    server: $IP
    port: 443
    uuid: $UUID
    alterId: 0
    cipher: auto
    network: ws
    tls: true
    ws-opts:
      path: /vmess
      headers:
        Host: $VMESS_DOMAIN
    servername: $VMESS_DOMAIN
  - name: Trojan-${PAD}
    type: trojan
    server: $IP
    port: 443
    password: $TROJAN_PASSWORD
    network: ws
    tls: true
    udp: true
    ws-opts:
      path: /trojan
      headers:
        Host: $TROJAN_DOMAIN
    servername: $TROJAN_DOMAIN
YAML
  done < "$TOP_IPS_FILE"

  # 复制 subscribe.txt 作为默认首页
  cp "$SUBSCRIBE_DIR/subscribe.txt" "$SUBSCRIBE_DIR/index.html"

  echo "✦ 标准订阅: http://localhost:8088/subscribe.txt"
  echo "✦ Clash订阅: http://localhost:8088/clash.yaml"
  echo "✦ 节点URI:   http://localhost:8088/nodes.txt"
  echo "订阅文件已生成到 $SUBSCRIBE_DIR"
  echo "=============================="
}

# ========== 打印节点链接函数 ==========
print_node_links() {
  echo "========== 节点链接 =========="

  echo "VLESS:"
  echo "vless://$UUID@$VLESS_ADDR:443?encryption=none&security=tls&sni=$VLESS_DOMAIN&insecure=0&allowInsecure=0&type=ws&host=$VLESS_DOMAIN&path=%2Fvless#Railway-VLESS"
  echo

  echo "Trojan:"
  echo "trojan://$TROJAN_PASSWORD@$TROJAN_ADDR:443?security=tls&sni=$TROJAN_DOMAIN&insecure=0&allowInsecure=0&type=ws&host=$TROJAN_DOMAIN&path=%2Ftrojan#Railway-Trojan"
  echo

  echo "VMess 参数:"
  echo "地址: $VMESS_ADDR"
  echo "端口: 443"
  echo "UUID: $UUID"
  echo "alterId: 0"
  echo "传输: ws"
  echo "路径: /vmess"
  echo "TLS: tls"
  echo "Host: $VMESS_DOMAIN"
  echo "SNI: $VMESS_DOMAIN"
  echo
  echo "VMess URI (可直接导入客户端):"
  VMESS_JSON=$(printf '{"v":"2","ps":"Railway-VMess","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"/vmess","tls":"tls","sni":"%s","alpn":""}' "$VMESS_ADDR" "$UUID" "$VMESS_DOMAIN" "$VMESS_DOMAIN")
  echo "vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"
  echo "=============================="
}

# ========== 定时刷新优选IP函数 ==========
refresh_loop() {
  if [ "$REFRESH_INTERVAL" = "0" ]; then
    echo "定时优选已关闭 (REFRESH_INTERVAL=0)"
    return 0
  fi

  echo "========== 启动定时优选任务 =========="
  echo "每 $REFRESH_INTERVAL 小时自动刷新优选IP并更新订阅文件"
  echo "======================================"

  (
    INTERVAL_SECONDS=$(( REFRESH_INTERVAL * 3600 ))
    while true; do
      sleep "$INTERVAL_SECONDS"
      echo ""
      echo "========== [定时任务] 开始刷新优选IP $(date '+%Y-%m-%d %H:%M:%S') =========="
      # 重新测速并更新 /tmp/top_ips.txt（测速可能全失败，函数内部已有兜底）
      run_speedtest || echo "[定时] 测速返回非零，继续尝试生成订阅..."
      # 重新生成订阅文件
      generate_subscriptions || echo "[定时] 生成订阅返回非零"
      echo "========== [定时任务] 刷新完成 $(date '+%Y-%m-%d %H:%M:%S') =========="
      echo ""
    done
  ) &
  REFRESH_PID=$!
  echo "定时优选任务已启动 (PID: $REFRESH_PID)"
}

# ========================================
# 主流程开始
# ========================================

# 第一次测速优选
run_speedtest

echo "========== 参数检查 =========="
echo "UUID exists"
echo "TROJAN_PASSWORD exists"
echo "ARGO_TOKEN length: ${#ARGO_TOKEN}"
echo "VLESS_DOMAIN: $VLESS_DOMAIN"
echo "VMESS_DOMAIN: $VMESS_DOMAIN"
echo "TROJAN_DOMAIN: $TROJAN_DOMAIN"

if [ -n "${PREFERRED_ADDR:-}" ]; then
  echo "PREFERRED_ADDR: $PREFERRED_ADDR"
else
  echo "PREFERRED_ADDR: 未设置，使用各自域名"
fi

echo "VLESS_ADDR: $VLESS_ADDR"
echo "VMESS_ADDR: $VMESS_ADDR"
echo "TROJAN_ADDR: $TROJAN_ADDR"
echo "============================="

sed -i "s/PASTE_UUID_HERE/$UUID/g" config.json
sed -i "s/PASTE_TROJAN_PASSWORD_HERE/$TROJAN_PASSWORD/g" config.json

# 若启用 WARP 出站，注入 outbounds 和 rules
if [ "$ENABLE_WARP" = "true" ] && [ -z "${WARP_PRIVATE_KEY:-}" ]; then
  echo "⚠ 警告: ENABLE_WARP=true 但未设置 WARP_PRIVATE_KEY，已跳过 WARP 出站（使用纯直连）"
  ENABLE_WARP=false
fi

if [ "$ENABLE_WARP" = "true" ]; then
  echo "正在注入 Cloudflare WARP 出站配置..."
  python3 << 'PYEOF'
import json, os
with open('/app/config.json') as f:
    cfg = json.load(f)

private_key = os.environ.get("WARP_PRIVATE_KEY", "")
if not private_key:
    raise SystemExit("WARP_PRIVATE_KEY 为空，跳过 WARP 注入")

warp = {
    "type": "wireguard",
    "tag": "warp",
    "server": os.environ.get("WARP_ENDPOINT") or "engage.cloudflareclient.com",
    "server_port": int(os.environ.get("WARP_ENDPOINT_PORT") or 2408),
    "local_address": ["%s/32" % (os.environ.get("WARP_ADDRESS") or "172.16.0.2")],
    "private_key": private_key,
    "peer_public_key": os.environ.get("WARP_PUBLIC_KEY") or "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
    "mtu": 1280
}
cfg["outbounds"] = [warp] + cfg.get("outbounds", [{"type": "direct", "tag": "direct"}])

# 仅需解锁的流媒体/海外域名走 WARP，其余默认直连
# 注意：使用 domain_suffix，不依赖 geoip/geosite 数据库（sing-box 1.10 需额外下载）
stream_suffix = [
    "googlevideo.com", "ytimg.com", "ggpht.cn", "gvt1.com",
    "youtube.com", "googleusercontent.com", "doubleclick.net",
    "netflix.com", "nflxvideo.net", "nflximg.net", "nflxext.com",
    "nflximage.net", "openai.com", "chatgpt.com", "oaistatic.com",
    "oaiusercontent.com", "anthropic.com", "claude.ai",
    "a248.e.akamai.net", "spotify.com", "scdn.co", "telegram.org",
    "t.me", "twitter.com", "x.com", "twimg.com"
]
stream_outbound = os.environ.get("WARP_STREAM_OUTBOUND") or "warp"

route = cfg.get("route", {})
route["rules"] = [
    {"domain_suffix": stream_suffix, "outbound": stream_outbound}
]
route["final"] = "direct"
cfg["route"] = route

with open('/app/config.json', 'w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
print("  ✓ WARP 出站已启用：指定流媒体域名 → warp，其余 → direct")
PYEOF
fi

echo "========== 配置摘要 =========="
echo "UUID: ${#UUID} 字符"
echo "TROJAN_PASSWORD: ${#TROJAN_PASSWORD} 字符"
echo "ARGO_TOKEN: ${#ARGO_TOKEN} 字符"
echo "ENABLE_WARP: ${ENABLE_WARP:-false}"
echo "SUBSCRIBE_KEY: ${SUBSCRIBE_KEY:-未设置（订阅无需认证）}"
echo "==============================="

print_node_links

# 生成订阅文件
generate_subscriptions

echo ""
echo "📌 公开订阅链接使用方法:"
echo "   在 Cloudflare Tunnel 仪表盘中添加一个 Public Hostname:"
echo "     服务指向 → localhost:7080"
echo "   HAProxy 会自动按路径分发:"
echo "     /vless        → sing-box VLESS (8080)"
echo "     /vmess        → sing-box VMess (8081)"
echo "     /trojan       → sing-box Trojan (8082)"
echo "     其他路径       → 订阅服务 (8088)"
echo "   然后节点地址为:"
echo "     https://你的域名 (VLESS / VMess / Trojan 共用)"
echo "   订阅地址为:"
echo "     https://你的域名/subscribe.txt"
echo "     https://你的域名/clash.yaml"
echo ""

echo "Starting subscription HTTP server on :8088..."
python3 -m http.server 8088 --directory "$SUBSCRIBE_DIR" &
HTTPD_PID=$!
sleep 1
if kill -0 $HTTPD_PID 2>/dev/null; then
  echo "Subscription HTTP server started (PID: $HTTPD_PID)."
else
  echo "警告: 订阅 HTTP 服务器启动失败，端口 8088 可能被占用。"
fi

echo "Starting sing-box..."
sing-box run -c config.json &
SINGBOX_PID=$!

# 轮询检测 sing-box 端口就绪，最长等30秒
echo "等待 sing-box 就绪..."
for i in $(seq 1 30); do
  if busybox nc -z 127.0.0.1 8080 2>/dev/null; then
    echo "sing-box 已就绪（等待 ${i}s）。"
    break
  fi
  if [ $i -eq 30 ]; then
    echo "警告: sing-box 未能在30秒内就绪，继续启动..."
  fi
  sleep 1
done

# ========== 生成并注入订阅认证配置块 ==========
# 仅支持路径前缀认证 /sub/<KEY>/...
# 为什么不用 query string? HAProxy 没有 q() fetch method，
# 用正则 req.hdr(url) 模拟 query 太脆弱且不同版本差异大。
# 路径前缀方案：所有 HAProxy 版本都支持 path_beg + regsub，v2rayN/Clash/Surge 全部通用。

AUTH_BLOCK=""
if [ -n "$SUBSCRIBE_KEY" ]; then
  # HAProxy 的 regsub 会把 . * [ ] ^ $ + ? ( ) { } | 等当成正则，先 escape
  KEY_REGEX=$(echo "$SUBSCRIBE_KEY" | sed 's/[.[\*^$()+?{|]/\\&/g')
  AUTH_BLOCK=$(cat <<BLOCK_EOF
  # ===== 订阅认证已启用 =====
  # 【顺序关键】先 deny 非法请求（此时仍是原始路径），再 rewrite 合法请求。
  # 如果先 rewrite 再 deny，rewrite 后的路径会被 deny 规则误杀！
  acl sub_match_path path_beg /sub/$KEY_REGEX/

  # deny：
  #   - 原始订阅路径（没有 /sub/ 前缀）一律 deny
  #   - /sub/ 前缀但 key 不对 → deny
  http-request deny deny_status 401 if is_sub_raw
  http-request deny deny_status 401 if is_sub_path_prefix !sub_match_path

  # rewrite：合法的 /sub/<KEY>/xxx → /xxx，让后端 8088 正常服务
  http-request set-path %[path,regsub(^/sub/$KEY_REGEX/,/)] if sub_match_path
BLOCK_EOF
)
  echo ""
  echo "✓ 订阅认证已启用（SUBSCRIBE_KEY=$SUBSCRIBE_KEY）"
  echo "  订阅 URL（路径前缀，所有客户端通用）:"
  echo "    /sub/${SUBSCRIBE_KEY}/subscribe.txt"
  echo "    /sub/${SUBSCRIBE_KEY}/clash.yaml"
  echo "    /sub/${SUBSCRIBE_KEY}/nodes.txt"
else
  AUTH_BLOCK="  # ===== 订阅认证未启用（SUBSCRIBE_KEY 为空，订阅公开访问）====="
  echo "ℹ 订阅认证未启用（SUBSCRIBE_KEY 为空 → 订阅公开访问）"
fi

# 注入 haproxy.cfg（替换占位符 __AUTH_BLOCK__）
# 我们用 sed /__AUTH_BLOCK__/r 把 AUTH_BLOCK 写入文件，再删掉占位行
AUTH_FILE="/tmp/haproxy_auth_block.txt"
printf '%s\n' "$AUTH_BLOCK" > "$AUTH_FILE"
if grep -q '__AUTH_BLOCK__' /app/haproxy.cfg 2>/dev/null; then
  sed -i "/__AUTH_BLOCK__/r $AUTH_FILE" /app/haproxy.cfg
  sed -i "/__AUTH_BLOCK__/d" /app/haproxy.cfg
  echo "✓ 已注入认证配置到 haproxy.cfg"
fi
rm -f "$AUTH_FILE"

echo "Starting HAProxy..."
haproxy -f /app/haproxy.cfg
echo "HAProxy started on :7080, distributing paths: /vless→8080, /vmess→8081, /trojan→8082, 其他→8088"

# 启动定时优选任务（后台）
refresh_loop

echo "Starting cloudflared..."
# 命令刻意保持最保守：只用 --no-autoupdate（顶层全局）+ --token（run 子命令）。
# 所有额外 flag（--protocol / --reconnect-delay / --http2-origin 等）要么
# 已在新版本中删除，要么有严格 flag 分层，容易因位置错误导致启动失败。
# cloudflared tunnel run 的标准形式: cloudflared [global flags] tunnel run [run flags]
CF_CMD="cloudflared --no-autoupdate tunnel run --token $ARGO_TOKEN"

# cloudflared 守护循环：进程如果崩掉帮助日志里常见的 "flag not defined"、
# token 过期、网络瞬断导致的退出 → 自动重启而不是让容器挂掉。
# wait 返回后 sleep 2 秒再拉起，防止崩溃风暴。
while true; do
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] cloudflared 启动..."
  # 用 exec 让 cloudflared 直接替换当前 shell 进程（在子进程里跑循环），
  # 方便 trap cleanup 正确处理信号；同时把 PID 打出来方便排查。
  $CF_CMD &
  CFPID=$!
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] cloudflared PID=$CFPID 已启动，等待退出..."
  wait $CFPID
  EXIT=$?
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] cloudflared 退出 code=$EXIT, 2 秒后重启..."
  sleep 2
done
