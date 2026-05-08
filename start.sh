#!/bin/sh
set -e

echo "========== start.sh 已执行 =========="

: "${UUID:?UUID is required}"
: "${TROJAN_PASSWORD:?TROJAN_PASSWORD is required}"
: "${ARGO_TOKEN:?ARGO_TOKEN is required}"

: "${VLESS_DOMAIN:?VLESS_DOMAIN is required}"
: "${VMESS_DOMAIN:?VMESS_DOMAIN is required}"
: "${TROJAN_DOMAIN:?TROJAN_DOMAIN is required}"

# 单个优选地址：
# 如果设置了 PREFERRED_ADDR，三个协议的 address/server 都用它
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

echo "=============================="

echo "Starting sing-box..."
sing-box run -c config.json &

sleep 3

echo "Starting cloudflared..."
cloudflared tunnel --no-autoupdate run --token "$ARGO_TOKEN"
