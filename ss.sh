#!/bin/bash

# 1. Input Parameters
read -p "Enter container name [default: ss]: " NAME
NAME=${NAME:-ss}

read -p "Enter port [default: 8388]: " PORT
PORT=${PORT:-8388}

# Password is required
read -p "Enter password: " PASSWORD
if [ -z "$PASSWORD" ]; then
  echo "Error: No password entered. Exiting."
  exit 1
fi

# 2. Run Docker Container
echo "Starting container ${NAME}..."
# Remove existing container with the same name if it exists
docker rm -f ${NAME} 2>/dev/null

docker run -d \
  --name ${NAME} \
  --restart always \
  -p ${PORT}:8388 \
  -p ${PORT}:8388/udp \
  shadowsocks/shadowsocks-libev \
  ss-server -s 0.0.0.0 -p 8388 -m aes-256-gcm -k ${PASSWORD}

# 3. Error Check
if [ $? -ne 0 ]; then
  echo "--------------------------------------------------"
  echo "Error: Failed to start the Docker container."
  echo "Common issues: Port $PORT is already in use."
  echo "--------------------------------------------------"
  exit 1
fi

# Verify if container is actually running
if [ "$(docker inspect -f '{{.State.Running}}' ${NAME} 2>/dev/null)" != "true" ]; then
  echo "Error: Container started but stopped immediately."
  echo "Check logs with: docker logs ${NAME}"
  exit 1
fi

# 4. Output Connection Details
IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || echo "[Your_Server_IP]")

echo "--------------------------------------------------"
echo "Deployment Complete!"
echo "--------------------------------------------------"
echo "Protocol:    Shadowsocks (SS)"
echo "Address:     $IP"
echo "Port:        $PORT"
echo "Password:    $PASSWORD"
echo "Method:      aes-256-gcm"
echo "--------------------------------------------------"
echo "Manage:      docker logs ${NAME} / docker restart ${NAME}"
echo "--------------------------------------------------"
