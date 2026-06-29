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

: "${UUID:?UUID is required}"
: "${TROJAN_PASSWORD:?TROJAN_PASSWORD is required}"
: "${ARGO_TOKEN:?ARGO_TOKEN is required}"

: "${VLESS_DOMAIN:?VLESS_DOMAIN is required}"
: "${VMESS_DOMAIN:?VMESS_DOMAIN is required}"
: "${TROJAN_DOMAIN:?TROJAN_DOMAIN is required}"

# ========== 自动优选IP检测 ==========
# 默认启用，可通过设置 AUTO_PREFERRED_IP=false 关闭
# 自动从列表中测试并选择延迟最低的 Cloudflare 优选地址（IP或域名均可）
if [ "${AUTO_PREFERRED_IP:-true}" = "true" ] && [ -z "${PREFERRED_ADDR:-}" ]; then
  echo "========== 自动检测优选IP =========="

  # 可自定义列表（空格分隔），默认包含网络公开收集的优选域名和IP
  # 来源：https://bestcf.pages.dev/domain/all.txt 和 ygkkk 优选列表
  IP_LIST="${PREFERRED_IP_LIST:-cloudflare.com cloudflare.net pages.dev r2.dev cdnjs.com cloudflare-eth.com static.cloudflareinsights.com cdn.jsdelivr.net www.speedtest.net skk.moe bestcf.030101.xyz cf.877774.xyz yg1.ygkkk.dpdns.org yg2.ygkkk.dpdns.org yg3.ygkkk.dpdns.org yg4.ygkkk.dpdns.org yg5.ygkkk.dpdns.org yg6.ygkkk.dpdns.org yg7.ygkkk.dpdns.org yg8.ygkkk.dpdns.org yg9.ygkkk.dpdns.org yg10.ygkkk.dpdns.org yg11.ygkkk.dpdns.org yg12.ygkkk.dpdns.org yg13.ygkkk.dpdns.org cf.877774.xyz cf.090227.xyz cf.tencentapp.cn ct.877774.xyz www.visa.cn}"

  TOTAL=$(echo "$IP_LIST" | wc -w)
  echo "正在测试 $TOTAL 个地址..."
  RESULTS=""

  # 收集所有测速结果
  for IP in $IP_LIST; do
    TIME=$(curl -o /dev/null -s -w '%{time_connect}' --connect-timeout 2 "https://$IP" 2>/dev/null || echo "9999")
    if [ "$TIME" != "9999" ]; then
      RESULTS="$RESULTS$IP|$TIME"$'\n'
    fi
  done

  # 按延迟排序并取前15
  BEST_LIST=$(echo "$RESULTS" | sort -t'|' -k2 -n | head -15)

  COUNT=$(echo "$BEST_LIST" | grep -c '|' || true)
  if [ "$COUNT" -gt 0 ]; then
    echo ""
    echo "延迟最低的前 $COUNT 个地址:"
    echo "$BEST_LIST" | awk -F'|' '{printf "  %s - %.4fs\n", $1, $2}'
    echo ""

    # 保存前15个IP到临时文件（仅IP，不带延迟）
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
fi

# 单个优选地址：
# 如果设置了 PREFERRED_ADDR（手动或自动检测），三个协议的 address/server 都用它
# 如果没设置，则分别使用各自域名
VLESS_ADDR="${PREFERRED_ADDR:-$VLESS_DOMAIN}"
VMESS_ADDR="${PREFERRED_ADDR:-$VMESS_DOMAIN}"
TROJAN_ADDR="${PREFERRED_ADDR:-$TROJAN_DOMAIN}"

echo "========== 参数检查 =========="
echo "UUID exists"
echo "TROJAN_PASSWORD exists"
echo "ARGO_TOKEN length: ${#ARGO_TOKEN}"
echo "VLESS_DOMAIN: $VLESS_DOMAIN"
echo "VMESS_DOMAIN: $VMESS_DOMAIN"
echo "TROJAN_DOMAIN: $TROJAN_DOMAIN"

if [ -n "$PREFERRED_ADDR" ]; then
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

echo "========== Final config.json =========="
cat config.json
echo "======================================="

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

# ========== 生成订阅文件 ==========
echo "========== 生成订阅文件 =========="

SUBSCRIBE_DIR="/app/subscribe"
mkdir -p "$SUBSCRIBE_DIR"

# 判断是否有优选IP列表
TOP_IPS_FILE="/tmp/top_ips.txt"
if [ -s "$TOP_IPS_FILE" ]; then
  ALL_IPS=$(cat "$TOP_IPS_FILE")
  IP_COUNT=$(echo "$ALL_IPS" | wc -l)
  echo "使用 $IP_COUNT 个优选地址生成多节点订阅..."
else
  # 没有优选IP时，只使用当前地址
  ALL_IPS="$VLESS_DOMAIN"
  IP_COUNT=1
  echo "未检测到优选IP，使用单节点订阅..."
fi

# 清空节点列表文件
> "$SUBSCRIBE_DIR/nodes.txt"

INDEX=0
# 遍历每个优选地址生成节点
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
done <<< "$ALL_IPS"

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
done <<< "$ALL_IPS"

# 复制 subscribe.txt 作为默认首页
cp "$SUBSCRIBE_DIR/subscribe.txt" "$SUBSCRIBE_DIR/index.html"

echo "✦ 标准订阅: http://localhost:8088/subscribe.txt"
echo "✦ Clash订阅: http://localhost:8088/clash.yaml"
echo "✦ 节点URI:   http://localhost:8088/nodes.txt"

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

echo "订阅文件已生成到 $SUBSCRIBE_DIR"

echo "=============================="

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

echo "Starting HAProxy..."
haproxy -f /app/haproxy.cfg
echo "HAProxy started on :7080, distributing paths: /vless→8080, /vmess→8081, /trojan→8082, 其他→8088"

echo "Starting cloudflared..."
cloudflared tunnel --no-autoupdate run --token "$ARGO_TOKEN"
