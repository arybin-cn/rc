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

# --- Directory Configuration ---
DEFAULT_APP_DIR="$HOME/.openclaw"
printf "Enter deployment directory [default: $DEFAULT_APP_DIR]: "
read -r APP_DIR
APP_DIR=${APP_DIR:-$DEFAULT_APP_DIR}

# --- Environment Setup ---
mkdir -p "$APP_DIR"

# --- Configuration Input ---
echo "--------------------------------------------------"
echo "OpenClaw Deployment Configuration"
echo "--------------------------------------------------"

# Generate gateway security token
if command -v openssl >/dev/null 2>&1; then
    OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)
else
    OPENCLAW_GATEWAY_TOKEN=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | fold -w 64 | head -n 1)
fi

# Telegram Setup
printf "Enter Telegram Bot Token (Optional, Enter to skip): "
read -r TG_TOKEN
TG_ALLOWLIST=""
DM_POLICY="pairing"
if [ -n "$TG_TOKEN" ]; then
    # Updated: Explicitly mentioning Numeric IDs only
    printf "Enter Telegram Allowlist (Numeric IDs ONLY, e.g., tg:123456,tg:789012): "
    read -r TG_ALLOWLIST
    [ -n "$TG_ALLOWLIST" ] && DM_POLICY="allowlist"
fi

# LLM Provider Selection
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
    11) printf "Enter custom env var name: "; read -r LLM_ENV_VAR ;;
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
                echo "Notice: Multiple keys detected. Variable set to $LLM_ENV_VAR" ;;
        esac
    fi
fi

printf "Enter Listen Port [default: 18789]: "
read -r LISTEN_PORT
LISTEN_PORT=${LISTEN_PORT:-18789}

printf "Enter Container Name [default: openclaw]: "
read -r CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-openclaw}

# --- Generate JSON5 Config File ---
# Secure allowed origins: Local access only
ALLOWED_ORIGINS="\"http://localhost\", \"http://localhost:${LISTEN_PORT}\", \"http://127.0.0.1:${LISTEN_PORT}\""

FORMATTED_ALLOWLIST=""
if [ -n "$TG_ALLOWLIST" ]; then
    FORMATTED_ALLOWLIST=$(echo "$TG_ALLOWLIST" | sed "s/,/\",\"/g" | sed 's/^/\"/' | sed 's/$/\"/')
fi

cat <<EOF > "$APP_DIR/openclaw.json"
{
  // System Gateway Settings
  gateway: {
    controlUi: {
      allowedOrigins: [${ALLOWED_ORIGINS}]
    }
  },
  // Communication Channels
  channels: {
    telegram: {
      enabled: $([ -n "$TG_TOKEN" ] && echo "true" || echo "false"),
      botToken: "${TG_TOKEN}",
      dmPolicy: "${DM_POLICY}", 
      allowFrom: [${FORMATTED_ALLOWLIST}]
    }
  }
}
EOF

# --- Build Runtime-Specific Flags ---
EXTRA_FLAGS=""
if [ "$CONTAINER_RUNTIME" = "podman" ]; then
    # Podman: keep-id maps host user to container user (node)
    EXTRA_FLAGS="--userns keep-id"
else
    # Docker: map host UID/GID directly
    EXTRA_FLAGS="--user $(id -u):$(id -g)"
fi

# --- Build Run Command ---
echo "Preparing deployment (ghcr.io/openclaw/openclaw:2026.4.15)..."

$CONTAINER_RUNTIME rm -f "${CONTAINER_NAME}" 2>/dev/null

RUN_CMD="$CONTAINER_RUNTIME run -d \
    --name ${CONTAINER_NAME} \
    --restart always \
    $EXTRA_FLAGS \
    -p ${LISTEN_PORT}:18789 \
    -v $APP_DIR:/home/node/.openclaw:Z \
    -e OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN} \
    -e NODE_ENV=production"

if [ -n "$LLM_ENV_VAR" ] && [ -n "$LLM_API_KEY" ]; then
    RUN_CMD="$RUN_CMD -e $LLM_ENV_VAR=$LLM_API_KEY"
fi

RUN_CMD="$RUN_CMD ghcr.io/openclaw/openclaw:2026.4.15"

# --- Execute ---
eval "$RUN_CMD"

if [ $? -eq 0 ]; then
    echo "--------------------------------------------------"
    echo "Deployment Complete!"
    echo "--------------------------------------------------"
    SERVER_IP=$(curl -s https://api.ipify.org || echo "YOUR_SERVER_IP")
    echo "Web UI Access: http://${SERVER_IP}:${LISTEN_PORT}"
    echo "Gateway Token: ${OPENCLAW_GATEWAY_TOKEN}"
    echo "Config Directory: $APP_DIR"
    echo "Policy Applied: $DM_POLICY"
    if [ "$DM_POLICY" = "allowlist" ]; then
        echo "Whitelist IDs: $TG_ALLOWLIST"
    fi
    echo "--------------------------------------------------"
else
    echo "Error: Container failed to start!"
    exit 1
fi
