#!/bin/sh
set -e

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

# 定时刷新间隔（小时），设为 0 则关闭定时优选
REFRESH_INTERVAL="${REFRESH_INTERVAL:-6}"

# 订阅密钥（可为空，为空则不要求认证）
SUBSCRIBE_KEY="${SUBSCRIBE_KEY:-}"
export SUBSCRIBE_KEY

SUBSCRIBE_DIR="/app/subscribe"
mkdir -p "$SUBSCRIBE_DIR"

# ========== 测速优选函数 ==========
run_speedtest() {
  if [ "${AUTO_PREFERRED_IP:-true}" != "true" ] || [ -n "${PREFERRED_ADDR:-}" ]; then
    # 手动指定了 PREFERRED_ADDR 或关闭了自动优选，跳过测速
    VLESS_ADDR="${PREFERRED_ADDR:-$VLESS_DOMAIN}"
    VMESS_ADDR="${PREFERRED_ADDR:-$VMESS_DOMAIN}"
    TROJAN_ADDR="${PREFERRED_ADDR:-$TROJAN_DOMAIN}"
    return 0
  fi

  echo "========== 自动检测优选IP =========="

  # 可自定义列表（空格分隔），默认优选15个低延迟 Cloudflare 域名
  # 按 TLS 握手延迟排序，全部使用域名避免 IP 被封
  IP_LIST="${PREFERRED_IP_LIST:-cf.tencentapp.cn cloudflare.182682.xyz cm.cloudflare.byoip.top cmcc.877774.xyz ct.877774.xyz ct.cloudflare.byoip.top cu.877774.xyz cu.cloudflare.byoip.top r2.dev static.cloudflareinsights.com cf.877774.xyz www.shopify.com www.asda.com www.emerson.com markmonitor.com}"

  TOTAL=$(echo "$IP_LIST" | wc -w)
  echo "正在测试 $TOTAL 个地址（并行测速，测量 TLS 真实连接延迟）..."

  # 并行测速：每个地址后台执行，测量 TLS 握手完成时间 (time_appconnect)
  TEST_DIR="/tmp/speedtest"
  rm -rf "$TEST_DIR"
  mkdir -p "$TEST_DIR"

  for IP in $IP_LIST; do
    (
      TIME=$(curl -o /dev/null -s -w '%{time_appconnect}' \
        --connect-timeout 3 --max-time 5 \
        -k "https://$IP" 2>/dev/null || echo "9999")
      if [ "$TIME" != "000000.000000" ] && [ -n "$TIME" ]; then
        echo "$TIME" > "$TEST_DIR/$IP"
      fi
    ) &
  done

  wait

  # 汇总结果：地址|延迟
  RESULTS=""
  for IP in $IP_LIST; do
    if [ -f "$TEST_DIR/$IP" ]; then
      TIME=$(cat "$TEST_DIR/$IP")
      if [ "$TIME" != "9999" ]; then
        RESULTS="$RESULTS$IP|$TIME"$'\n'
      fi
    fi
  done
  rm -rf "$TEST_DIR"

  # 按延迟排序并取前5
  BEST_LIST=$(echo "$RESULTS" | sort -t'|' -k2 -n | head -5)

  COUNT=$(echo "$BEST_LIST" | grep -c '|' || true)
  if [ "$COUNT" -gt 0 ]; then
    echo ""
    echo "延迟最低的前 $COUNT 个地址:"
    echo "$BEST_LIST" | awk -F'|' '{printf "  %s - %.4fs\n", $1, $2}'
    echo ""

    # 保存前5个IP到临时文件（仅IP，不带延迟）
    echo "$BEST_LIST" | cut -d'|' -f1 > /tmp/top_ips.txt

    # 从 top 列表中随机选一个
    PICK_INDEX=$(( (RANDOM % COUNT) + 1 ))
    PREFERRED_ADDR=$(echo "$BEST_LIST" | sed -n "${PICK_INDEX}p" | cut -d'|' -f1)
    PICK_TIME=$(echo "$BEST_LIST" | sed -n "${PICK_INDEX}p" | cut -d'|' -f2)
    echo "✓ 随机选中: $PREFERRED_ADDR (延迟: ${PICK_TIME}s, 共 $COUNT 个候选)"
  else
    echo "✗ 未检测到可用优选IP，使用默认域名"
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
      set +e
      # 重新测速并更新 /tmp/top_ips.txt
      run_speedtest
      # 重新生成订阅文件
      generate_subscriptions
      set -e
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
# HAProxy 的 ACL 只在本 section 生效，因此认证判断必须写在 frontend 内；
# 同时 HAProxy 不会自动展开环境变量，故在启动前把认证块注入到 haproxy.cfg 的占位符处。
if [ -n "$SUBSCRIBE_KEY" ]; then
  cat > /tmp/auth_block.txt <<EOF
  # 订阅认证已启用：订阅路径需携带 X-Key 请求头（或 ?key= 由 Cloudflare 转发为头）
  acl sub_key_match req.hdr(X-Key) -i $SUBSCRIBE_KEY
  http-request deny deny_status 401 if is_sub !sub_key_match
EOF
  echo "订阅认证已启用（SUBSCRIBE_KEY 已设置）"
else
  echo "  # 订阅认证未启用（未设置 SUBSCRIBE_KEY，订阅公开访问）" > /tmp/auth_block.txt
  echo "订阅认证未启用（订阅公开访问）"
fi

# 将认证块插入占位符位置（读入文件后删除占位行）
if grep -q '#__AUTH_BLOCK__' /app/haproxy.cfg 2>/dev/null; then
  sed -i "/#__AUTH_BLOCK__/r /tmp/auth_block.txt" /app/haproxy.cfg
  sed -i "/#__AUTH_BLOCK__/d" /app/haproxy.cfg
  echo "已注入订阅认证配置到 haproxy.cfg"
fi

echo "Starting HAProxy..."
haproxy -f /app/haproxy.cfg
echo "HAProxy started on :7080, distributing paths: /vless→8080, /vmess→8081, /trojan→8082, 其他→8088"

# 启动定时优选任务（后台）
refresh_loop

echo "Starting cloudflared..."
cloudflared tunnel --no-autoupdate --protocol http2 --reconnect-delay 3s run --token "$ARGO_TOKEN" &
CLOUDFLARED_PID=$!
wait $CLOUDFLARED_PID
