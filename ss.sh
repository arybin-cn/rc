#!/bin/bash
read -p "Enter port: " PORT
if [ -z "$PORT" ]; then
  echo "No port entered. Exiting."
  exit 1
fi
read -s -p "Enter password: " PASSWORD
echo
if [ -z "$PASSWORD" ]; then
  echo "No password entered. Exiting."
  exit 1
fi
docker run -d --name ss \
  -p ${PORT}:8388 \
  -p ${PORT}:8388/udp \
  shadowsocks/shadowsocks-libev \
  ss-server -s 0.0.0.0 -p 8388 -m aes-256-gcm -k ${PASSWORD}

