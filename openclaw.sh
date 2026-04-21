#!/bin/sh

# --- Container Engine Detection ---
CONTAINER_RUNTIME=""

if command -v podman >/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
elif command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
else
    echo "Error: Podman or Docker not found."
    printf "Please enter your container engine (e.g., docker, podman): "
    read -r MANUAL_RUNTIME
    if [ -n "$MANUAL_RUNTIME" ] && command -v "$MANUAL_RUNTIME" >/dev/null 2>&1; then
        CONTAINER_RUNTIME="$MANUAL_RUNTIME"
    else
        echo "Error: '$MANUAL_RUNTIME' not found. Exiting."
        exit 1
    fi
fi

echo "Using runtime: $CONTAINER_RUNTIME"

# --- Directory Configuration & Check ---
DEFAULT_APP_DIR="$HOME/.openclaw"
printf "Enter deployment directory [default: $DEFAULT_APP_DIR]: "
read -r APP_DIR
APP_DIR=${APP_DIR:-$DEFAULT_APP_DIR}

if [ -d "$APP_DIR" ]; then
    echo "Error: Directory '$APP_DIR' already exists. Exiting to prevent overwrite."
    exit 1
fi

# --- Configuration Input ---
echo "--------------------------------------------------"
echo "OpenClaw Deployment Configuration"
echo "--------------------------------------------------"

# Generate a random 64-char hex token (32 bytes) for Gateway
if command -v openssl >/dev/null 2>&1; then
    OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)
else
    OPENCLAW_GATEWAY_TOKEN=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | fold -w 64 | head -n 1)
fi

# TG Token input
printf "Enter Telegram Bot Token (Optional, press Enter to skip): "
read -r TG_TOKEN

echo "Select your LLM Provider:"
echo "1) OpenAI          5) OpenRouter       9) Synthetic"
echo "2) Anthropic       6) Google Gemini   10) Minimax"
echo "3) DeepSeek        7) Zhipu (ZAI)     11) Other / Custom"
echo "4) Moonshot (Kimi) 8) DashScope       12) Skip for now"
printf "Enter choice [1-12, default: 12]: "
read -r LLM_CHOICE
LLM_CHOICE=${LLM_CHOICE:-12}

LLM_ENV_VAR=""
case $LLM_CHOICE in
    1)  LLM_ENV_VAR="OPENAI_API_KEY" ;;
    2)  LLM_ENV_VAR="ANTHROPIC_API_KEY" ;;
    3)  LLM_ENV_VAR="DEEPSEEK_API_KEY" ;;
    4)  LLM_ENV_VAR="MOONSHOT_API_KEY" ;;
    5)  LLM_ENV_VAR="OPENROUTER_API_KEY" ;;
    6)  LLM_ENV_VAR="GOOGLE_API_KEY" ;;
    7)  LLM_ENV_VAR="ZAI_API_KEY" ;;
    8)  LLM_ENV_VAR="DASHSCOPE_API_KEY" ;;
    9)  LLM_ENV_VAR="SYNTHETIC_API_KEY" ;;
    10) LLM_ENV_VAR="MINIMAX_API_KEY" ;;
    11) printf "Enter custom environment variable name: "; read -r LLM_ENV_VAR ;;
    *)  LLM_ENV_VAR="" ;;
esac

LLM_API_KEY=""
if [ -n "$LLM_ENV_VAR" ]; then
    printf "Enter API Key (multi-keys with comma supported): "
    read -r LLM_API_KEY
    if echo "$LLM_API_KEY" | grep -q ","; then
        case $LLM_ENV_VAR in
            OPENAI_API_KEY|ANTHROPIC_API_KEY|GOOGLE_API_KEY)
                LLM_ENV_VAR="${LLM_ENV_VAR}S" 
                echo "Notice: Detected multiple keys. Variable set to $LLM_ENV_VAR" ;;
        esac
    fi
fi

printf "Enter Listen Port [default: 18789]: "
read -r LISTEN_PORT
LISTEN_PORT=${LISTEN_PORT:-18789}

printf "Enter Container Name [default: openclaw]: "
read -r CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-openclaw}

# --- Environment Setup ---
mkdir -p "$APP_DIR/config" "$APP_DIR/workspace"

# --- Build Run Command ---
echo "Preparing deployment (ghcr.io/openclaw/openclaw:2026.4.15)..."

$CONTAINER_RUNTIME rm -f "${CONTAINER_NAME}" 2>/dev/null

# Initial run command with core variables
RUN_CMD="$CONTAINER_RUNTIME run -d \
    --name ${CONTAINER_NAME} \
    --restart always \
    -p ${LISTEN_PORT}:18789 \
    -v $APP_DIR/config:/app/config \
    -v $APP_DIR/workspace:/workspace \
    -e OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN} \
    -e NODE_ENV=production"

# Add LLM Key if provided
if [ -n "$LLM_ENV_VAR" ] && [ -n "$LLM_API_KEY" ]; then
    RUN_CMD="$RUN_CMD -e $LLM_ENV_VAR=$LLM_API_KEY"
fi

# Add Telegram Token via Env Var as per screenshot
if [ -n "$TG_TOKEN" ]; then
    RUN_CMD="$RUN_CMD -e TELEGRAM_BOT_TOKEN=$TG_TOKEN"
fi

RUN_CMD="$RUN_CMD ghcr.io/openclaw/openclaw:2026.4.15"

# --- Execute ---
eval "$RUN_CMD"

if [ $? -ne 0 ]; then echo "Error: Container failed to start!"; exit 1; fi

# --- Final Output ---
SERVER_IP=$(curl -s https://api.ipify.org || echo "YOUR_SERVER_IP")

echo "--------------------------------------------------"
echo "Deployment Complete!"
echo "--------------------------------------------------"
echo "Web UI Access: http://$SERVER_IP:$LISTEN_PORT"
echo "Gateway Token: $OPENCLAW_GATEWAY_TOKEN"
echo "Config Directory: $APP_DIR"

if [ -n "$TG_TOKEN" ]; then
    echo "--------------------------------------------------"
    echo "Telegram Bot is enabled via Environment Variable."
    echo "Next Steps:"
    echo "1. Send a message to your bot on Telegram."
    echo "2. Run the following command to approve (Replace CODE):"
    echo ""
    echo "$CONTAINER_RUNTIME exec -it ${CONTAINER_NAME} node dist/index.js pairing approve telegram CODE"
fi
echo "--------------------------------------------------"

# QR Code generation
echo "Generating QR Code for Web UI..."
$CONTAINER_RUNTIME run --rm -it -e PIP_ROOT_USER_ACTION=ignore docker.io/library/python:3.12-slim sh -c \
    "pip install -q --disable-pip-version-check qrcode && qr 'http://$SERVER_IP:$LISTEN_PORT'"
echo "--------------------------------------------------"
