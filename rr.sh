#!/bin/bash

# 1. Input Parameters
read -p "Enter container name [default: rr]: " NAME
NAME=${NAME:-rr}

read -p "Enter listen port [default: 2053]: " PORT
PORT=${PORT:-2053}

read -p "Enter destination (dest) [default: dash.cloudflare.com:2053]: " DEST
DEST=${DEST:-dash.cloudflare.com:2053}

read -p "Enter SNI [default: dash.cloudflare.com]: " SNI
SNI=${SNI:-dash.cloudflare.com}

# 2. Generate UUID and REALITY Keypair
UUID=$(cat /proc/sys/kernel/random/uuid)
echo "Generating keys using sing-box image..."
KEYS=$(docker run --rm ghcr.io/sagernet/sing-box:latest generate reality-keypair)

if [ $? -ne 0 ]; then
  echo "Error: Failed to generate keys. Make sure Docker is running."
  exit 1
fi

PRIVATE_KEY=$(echo "$KEYS" | grep "PrivateKey" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEYS" | grep "PublicKey" | awk '{print $2}')
SHORT_ID=$(head /dev/urandom | tr -dc 'a-f0-9' | head -c 16)

# 3. Create hidden config directory in Home directory
CONF_DIR="$HOME/.sing-box"
mkdir -p "$CONF_DIR" || { echo "Error: Failed to create directory $CONF_DIR"; exit 1; }

# 4. Write Configuration File
DEST_HOST=$(echo $DEST | cut -d: -f1)
DEST_PORT=$(echo $DEST | grep -q ":" && echo $DEST | cut -d: -f2 || echo 443)

cat <<EOF > "$CONF_DIR/config.json"
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": 8388,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$DEST_HOST",
            "server_port": $DEST_PORT
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

# 5. Run Docker Container
echo "Starting container ${NAME}..."
docker rm -f ${NAME} 2>/dev/null

docker run -d \
  --name ${NAME} \
  --restart always \
  -v "$CONF_DIR/config.json:/etc/sing-box/config.json" \
  -p ${PORT}:8388 \
  -p ${PORT}:8388/udp \
  ghcr.io/sagernet/sing-box:latest \
  -c /etc/sing-box/config.json run

# --- Error Check ---
if [ $? -ne 0 ]; then
  echo "--------------------------------------------------"
  echo "Error: Failed to start the Docker container."
  echo "Common issues: Port $PORT is already in use or Docker daemon is down."
  echo "--------------------------------------------------"
  exit 1
fi

# Double check if container is actually running
if [ "$(docker inspect -f '{{.State.Running}}' ${NAME} 2>/dev/null)" != "true" ]; then
  echo "Error: Container started but stopped immediately. Check logs with: docker logs ${NAME}"
  exit 1
fi

# 6. Output Connection Details
IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || echo "[Your_Server_IP]")

echo "--------------------------------------------------"
echo "Deployment Complete!"
echo "--------------------------------------------------"
echo "Protocol:    vless"
echo "Address:     $IP"
echo "Port:        $PORT"
echo "UUID:        $UUID"
echo "Flow:        xtls-rprx-vision"
echo "Encryption:  none"
echo "Network:     tcp"
echo "SNI:         $SNI"
echo "Fingerprint: chrome"
echo "PublicKey:   $PUBLIC_KEY"
echo "ShortID:     $SHORT_ID"
echo "SpiderX:     /"
echo "--------------------------------------------------"
echo "Config Path: $CONF_DIR/config.json"
echo "--------------------------------------------------"
