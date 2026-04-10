#!/bin/bash

# 1. Input Parameters
read -p "Enter container engine [default: docker]: " CONTAINER_ENGINE
CONTAINER_ENGINE=${CONTAINER_ENGINE:-docker}

read -p "Enter container name [default: ss]: " CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-ss}

read -p "Enter port [default: 8388]: " SERVICE_PORT
SERVICE_PORT=${SERVICE_PORT:-8388}

read -p "Enter password: " SERVICE_PASSWORD
if [ -z "$SERVICE_PASSWORD" ]; then
  echo "Error: No password entered. Exiting."
  exit 1
fi

# 2. Run Container
# Updated encryption method to chacha20-ietf-poly1305
echo "Starting container ${CONTAINER_NAME}..."
$CONTAINER_ENGINE rm -f ${CONTAINER_NAME} 2>/dev/null

$CONTAINER_ENGINE run -d \
  --name ${CONTAINER_NAME} \
  --restart always \
  -p ${SERVICE_PORT}:8388 \
  -p ${SERVICE_PORT}:8388/udp \
  shadowsocks/shadowsocks-libev \
  ss-server -s 0.0.0.0 -p 8388 -m chacha20-ietf-poly1305 -k ${SERVICE_PASSWORD}

# 3. Error Check
if [ $? -ne 0 ]; then
  echo "Error: Failed to start the container."
  exit 1
fi

# 4. Output Connection Details & Import URL
SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || echo "YOUR_IP")
CRYPTO_METHOD="chacha20-ietf-poly1305"
URL_REMARK="SS_$SERVER_IP"

# Base64 encode for SS link
AUTH_BASE64=$(echo -n "$CRYPTO_METHOD:$SERVICE_PASSWORD" | base64 | tr -d '\n')
IMPORT_URL="ss://$AUTH_BASE64@$SERVER_IP:$SERVICE_PORT#$URL_REMARK"

echo "--------------------------------------------------"
echo "Deployment Complete!"
echo "--------------------------------------------------"
echo "Protocol:    Shadowsocks (SS)"
echo "Address:     $SERVER_IP"
echo "Port:        $SERVICE_PORT"
echo "Password:    $SERVICE_PASSWORD"
echo "Method:      $CRYPTO_METHOD"
echo "--------------------------------------------------"
echo "Import URL:"
echo ""
echo "$IMPORT_URL"
echo ""
echo "--------------------------------------------------"
echo "Generating QR Code..."
echo "--------------------------------------------------"
$CONTAINER_ENGINE run --rm -it -e PIP_ROOT_USER_ACTION=ignore python:slim sh -c "pip install -q qrcode && qr '$IMPORT_URL'"
echo "--------------------------------------------------"
