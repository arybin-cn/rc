#!/bin/bash

# 1. Input Parameters
read -p "Enter container engine [default: docker]: " CONTAINER_ENGINE
CONTAINER_ENGINE=${CONTAINER_ENGINE:-docker}

read -p "Enter container name [default: rr]: " CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-rr}

read -p "Enter listen port [default: 2053]: " LISTEN_PORT
LISTEN_PORT=${LISTEN_PORT:-2053}

read -p "Enter destination (dest) [default: dash.cloudflare.com:2053]: " DESTINATION
DESTINATION=${DESTINATION:-dash.cloudflare.com:2053}

read -p "Enter SNI [default: dash.cloudflare.com]: " SNI_NAME
SNI_NAME=${SNI_NAME:-dash.cloudflare.com}

# 2. Generate UUID and REALITY Keypair
USER_UUID=$(cat /proc/sys/kernel/random/uuid)
echo "Generating keys using sing-box..."
KEY_DATA=$($CONTAINER_ENGINE run --rm ghcr.io/sagernet/sing-box:latest generate reality-keypair)

if [ $? -ne 0 ]; then
  echo "Error: Failed to generate keys. Make sure $CONTAINER_ENGINE is running."
  exit 1
fi

PRIVATE_KEY=$(echo "$KEY_DATA" | grep "PrivateKey" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEY_DATA" | grep "PublicKey" | awk '{print $2}')
SHORT_ID=$(head /dev/urandom | tr -dc 'a-f0-9' | head -c 16)

# 3. Create hidden config directory
CONFIG_DIR="$HOME/.sing-box"
mkdir -p "$CONFIG_DIR" || { echo "Error: Failed to create directory $CONFIG_DIR"; exit 1; }

# 4. Write Configuration File
DEST_HOST=$(echo $DESTINATION | cut -d: -f1)
DEST_PORT=$(echo $DESTINATION | grep -q ":" && echo $DESTINATION | cut -d: -f2 || echo 443)

cat <<EOF > "$CONFIG_DIR/config.json"
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": 8388,
      "users": [{ "uuid": "$USER_UUID", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "$SNI_NAME",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$DEST_HOST", "server_port": $DEST_PORT },
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF

# 5. Run Container
echo "Starting container ${CONTAINER_NAME}..."
$CONTAINER_ENGINE rm -f ${CONTAINER_NAME} 2>/dev/null

$CONTAINER_ENGINE run -d \
  --name ${CONTAINER_NAME} \
  --restart always \
  -v "$CONFIG_DIR/config.json:/etc/sing-box/config.json" \
  -p ${LISTEN_PORT}:8388 \
  -p ${LISTEN_PORT}:8388/udp \
  ghcr.io/sagernet/sing-box:latest \
  -c /etc/sing-box/config.json run

if [ $? -ne 0 ]; then
  echo "Error: Failed to start the container."
  exit 1
fi

# 6. Output Connection Details & Import URL
SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || echo "YOUR_IP")
URL_REMARK="VLESS_$SERVER_IP"
IMPORT_URL="vless://$USER_UUID@$SERVER_IP:$LISTEN_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI_NAME&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&headerType=none#$URL_REMARK"

echo "--------------------------------------------------"
echo "Deployment Complete!"
echo "--------------------------------------------------"
echo "Address:     $SERVER_IP"
echo "Port:        $LISTEN_PORT"
echo "Public Key:  $PUBLIC_KEY"
echo "Short ID:    $SHORT_ID"
echo "SNI:         $SNI_NAME"
echo "--------------------------------------------------"
echo "Import URL:"
echo ""
echo "$IMPORT_URL"
echo ""
echo "--------------------------------------------------"
echo "Generating QR Code..."
echo "--------------------------------------------------"
# Use specified CONTAINER_ENGINE for QR code generation
$CONTAINER_ENGINE run --rm -it -e PIP_ROOT_USER_ACTION=ignore python:slim sh -c "pip install -q qrcode && qr '$IMPORT_URL'"
echo "--------------------------------------------------"
