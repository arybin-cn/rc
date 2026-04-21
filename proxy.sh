#!/bin/sh

# --- Container Engine Detection ---
CONTAINER_RUNTIME=""

if command -v podman >/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
elif command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
else
    echo "Error: Podman or Docker not found."
    printf "Please enter your container engine (e.g., docker, podman, k3s): "
    read MANUAL_RUNTIME
    if [ -n "$MANUAL_RUNTIME" ] && command -v "$MANUAL_RUNTIME" >/dev/null 2>&1; then
        CONTAINER_RUNTIME="$MANUAL_RUNTIME"
    else
        echo "Error: '$MANUAL_RUNTIME' not found. Exiting."
        exit 1
    fi
fi

echo "Using runtime: $CONTAINER_RUNTIME"

# 1. Select Protocol with Default to REALITY
echo "--------------------------------------------------"
echo "Select the protocol you want to deploy:"
echo "1) REALITY (VLESS + XTLS Vision) [Default]"
echo "2) Shadowsocks (chacha20-ietf-poly1305)"
echo "--------------------------------------------------"
printf "Enter choice [1-2, default: 1]: "
read PROTO_CHOICE
PROTO_CHOICE=${PROTO_CHOICE:-1}

# 2. Common Parameters
SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || echo "YOUR_IP")

# 3. Protocol Specific Logic
if [ "$PROTO_CHOICE" = "1" ]; then
    printf "Enter container name [default: rr]: "
    read CONTAINER_NAME
    CONTAINER_NAME=${CONTAINER_NAME:-rr}

    printf "Enter listen port [default: 2053]: "
    read LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-2053}

    printf "Enter destination [default: dash.cloudflare.com:2053]: "
    read DESTINATION
    DESTINATION=${DESTINATION:-dash.cloudflare.com:2053}

    printf "Enter SNI [default: dash.cloudflare.com]: "
    read SNI_NAME
    SNI_NAME=${SNI_NAME:-dash.cloudflare.com}

    echo "Generating keys and configuration..."
    if [ -f /proc/sys/kernel/random/uuid ]; then
        USER_UUID=$(cat /proc/sys/kernel/random/uuid)
    else
        USER_UUID=$(od -x -N 16 /dev/urandom | head -n 1 | awk '{printf "%s%s-%s-%s-%s-%s%s%s", $2,$3,$4,$5,$6,$7,$8,$9}')
    fi

    # Fixed version to sing-box v1.11.4
    KEY_DATA=$($CONTAINER_RUNTIME run --rm ghcr.io/sagernet/sing-box:v1.11.4 generate reality-keypair)
    if [ $? -ne 0 ]; then echo "Error: Key generation failed!"; exit 1; fi

    PRIVATE_KEY=$(echo "$KEY_DATA" | grep "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEY_DATA" | grep "PublicKey" | awk '{print $2}')
    SHORT_ID=$(head -c 8 /dev/urandom | od -An -t x1 | tr -d ' \n')

    CONFIG_DIR="$HOME/.sing-box"
    mkdir -p "$CONFIG_DIR" || { echo "Error: Failed to create directory $CONFIG_DIR"; exit 1; }

    DEST_HOST=$(echo "$DESTINATION" | cut -d: -f1)
    if echo "$DESTINATION" | grep -q ":"; then
        DEST_PORT=$(echo "$DESTINATION" | cut -d: -f2)
    else
        DEST_PORT=443
    fi

    cat <<EOF > "$CONFIG_DIR/config.json"
{
  "log": { "level": "info" },
  "inbounds": [{
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
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF

    $CONTAINER_RUNTIME rm -f "${CONTAINER_NAME}" 2>/dev/null

    # Fixed version to sing-box v1.11.4
    $CONTAINER_RUNTIME run -d --name "${CONTAINER_NAME}" --restart always \
      -v "$CONFIG_DIR/config.json:/etc/sing-box/config.json" \
      -p "${LISTEN_PORT}:8388" -p "${LISTEN_PORT}:8388/udp" \
      ghcr.io/sagernet/sing-box:v1.11.4 -c /etc/sing-box/config.json run

    if [ $? -ne 0 ]; then echo "Error: REALITY container failed to start!"; exit 1; fi

    IMPORT_URL="vless://$USER_UUID@$SERVER_IP:$LISTEN_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI_NAME&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&headerType=none#VLESS_$SERVER_IP"
    SHOW_INFO="Protocol: VLESS-REALITY\nAddress: $SERVER_IP\nPort: $LISTEN_PORT\nUUID: $USER_UUID\nFlow: xtls-rprx-vision\nSNI: $SNI_NAME\nPublic Key: $PUBLIC_KEY\nShort ID: $SHORT_ID"

elif [ "$PROTO_CHOICE" = "2" ]; then
    printf "Enter container name [default: ss]: "
    read CONTAINER_NAME
    CONTAINER_NAME=${CONTAINER_NAME:-ss}

    printf "Enter port [default: 8388]: "
    read SERVICE_PORT
    SERVICE_PORT=${SERVICE_PORT:-8388}

    printf "Enter password: "
    read SERVICE_PASSWORD
    if [ -z "$SERVICE_PASSWORD" ]; then echo "Error: Password required."; exit 1; fi

    $CONTAINER_RUNTIME rm -f "${CONTAINER_NAME}" 2>/dev/null

    CRYPTO_METHOD="chacha20-ietf-poly1305"
    # Fixed version to shadowsocks-libev v3.3.5
    $CONTAINER_RUNTIME run -d --name "${CONTAINER_NAME}" --restart always \
      -p "${SERVICE_PORT}:8388" -p "${SERVICE_PORT}:8388/udp" \
      docker.io/shadowsocks/shadowsocks-libev:v3.3.5 \
      ss-server -s 0.0.0.0 -p 8388 -m $CRYPTO_METHOD -k "${SERVICE_PASSWORD}"

    if [ $? -ne 0 ]; then echo "Error: Shadowsocks container failed to start!"; exit 1; fi

    AUTH_BASE64=$(printf "%s:%s" "$CRYPTO_METHOD" "$SERVICE_PASSWORD" | base64 | tr -d '\n')
    IMPORT_URL="ss://$AUTH_BASE64@$SERVER_IP:$SERVICE_PORT#SS_$SERVER_IP"
    SHOW_INFO="Protocol: Shadowsocks\nAddress: $SERVER_IP\nPort: $SERVICE_PORT\nPassword: $SERVICE_PASSWORD\nMethod: $CRYPTO_METHOD"

else
    echo "Invalid choice. Exiting."
    exit 1
fi

# 4. Final Output
echo "--------------------------------------------------"
echo "Deployment Complete!"
echo "--------------------------------------------------"
printf "%b\n" "$SHOW_INFO"
echo "--------------------------------------------------"
echo "Import URL:"
echo ""
echo "$IMPORT_URL"
echo ""
echo "--------------------------------------------------"
echo "Generating QR Code..."
echo "--------------------------------------------------"
# Fixed version to python:3.12-slim and disabled pip version check notice
$CONTAINER_RUNTIME run --rm -it -e PIP_ROOT_USER_ACTION=ignore docker.io/library/python:3.12-slim sh -c \
    "pip install -q --disable-pip-version-check qrcode && qr '$IMPORT_URL'"
echo "--------------------------------------------------"
