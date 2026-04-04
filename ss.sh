#!/bin/bash

# Ask for container name (default: ss)
read -p "Enter container name [default: ss]: " NAME
NAME=${NAME:-ss}

# Ask for port (default: 8388)
read -p "Enter port [default: 8388]: " PORT
PORT=${PORT:-8388}

# Ask for password (must specify)
read -s -p "Enter password: " PASSWORD
echo
if [ -z "$PASSWORD" ]; then
  echo "No password entered. Exiting."
  exit 1
fi

# Run Docker container
docker run -d --name ${NAME} \
  -p ${PORT}:8388 \
  -p ${PORT}:8388/udp \
  shadowsocks/shadowsocks-libev \
  ss-server -s 0.0.0.0 -p 8388 -m aes-256-gcm -k ${PASSWORD}

