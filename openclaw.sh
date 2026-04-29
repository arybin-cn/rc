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
CONFIG_FILE="$APP_DIR/openclaw.json"

# --- Pre-set Port and Name ---
printf "Enter Listen Port [default: 18789]: "
read -r LISTEN_PORT
LISTEN_PORT=${LISTEN_PORT:-18789}

printf "Enter Container Name [default: openclaw]: "
read -r CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-openclaw}

# --- Configuration Logic ---
SKIP_CONFIG=false

if [ -f "$CONFIG_FILE" ]; then
    echo "--------------------------------------------------"
    echo "Configuration found at $CONFIG_FILE"
    echo "Skipping setup and keeping all files in $APP_DIR"
    echo "--------------------------------------------------"
    SKIP_CONFIG=true
else
    mkdir -p "$APP_DIR"
fi

if [ "$SKIP_CONFIG" = false ]; then
    echo "OpenClaw Deployment Configuration (Root Mode)"
    echo "--------------------------------------------------"

    # Gateway Password Setup
    printf "Enter Gateway Password (REQUIRED): "
    read -r OPENCLAW_GATEWAY_PASSWORD
    while [ -z "$OPENCLAW_GATEWAY_PASSWORD" ]; do
        printf "Password cannot be empty. Please enter again: "
        read -r OPENCLAW_GATEWAY_PASSWORD
    done

    # Telegram Setup
    printf "Enter Telegram Bot Token (Optional, Enter to skip): "
    read -r TG_TOKEN
    TG_ALLOWLIST=""
    DM_POLICY="pairing"
    if [ -n "$TG_TOKEN" ]; then
        printf "Enter Telegram Allowlist (Numeric IDs ONLY, e.g., tg:123456): "
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

    LLM_KEY_NAME=""
    case $LLM_CHOICE in
        1)  LLM_KEY_NAME="OPENAI_API_KEY" ;;
        2)  LLM_KEY_NAME="ANTHROPIC_API_KEY" ;;
        3)  LLM_KEY_NAME="DEEPSEEK_API_KEY" ;;
        4)  LLM_KEY_NAME="MOONSHOT_API_KEY" ;;
        5)  LLM_KEY_NAME="OPENROUTER_API_KEY" ;;
        6)  LLM_KEY_NAME="GOOGLE_API_KEY" ;;
        7)  LLM_KEY_NAME="ZAI_API_KEY" ;;
        8)  LLM_KEY_NAME="DASHSCOPE_API_KEY" ;;
        9)  LLM_KEY_NAME="SYNTHETIC_API_KEY" ;;
        10) LLM_KEY_NAME="MINIMAX_API_KEY" ;;
        11) printf "Enter custom env var name: "; read -r LLM_KEY_NAME ;;
    esac

    LLM_API_KEY=""
    if [ -n "$LLM_KEY_NAME" ]; then
        printf "Enter API Key: "
        read -r LLM_API_KEY
    fi

    # --- Generate JSON5 Config File ---
    FORMATTED_ALLOWLIST=""
    if [ -n "$TG_ALLOWLIST" ]; then
        FORMATTED_ALLOWLIST=$(echo "$TG_ALLOWLIST" | sed "s/,/\",\"/g" | sed 's/^/\"/' | sed 's/$/\"/')
    fi

    ENV_ENTRY=""
    if [ -n "$LLM_KEY_NAME" ] && [ -n "$LLM_API_KEY" ]; then
        ENV_ENTRY="\"$LLM_KEY_NAME\": \"$LLM_API_KEY\""
    fi

    cat <<EOF > "$CONFIG_FILE"
{
  // System Gateway Settings
  gateway: {
    bind: "lan",
    port: 18789,
    mode: "local",
    auth: {
      mode: "password",
      password: "${OPENCLAW_GATEWAY_PASSWORD}"
    },
    controlUi: {
      enabled: true,
      allowedOrigins: [
        "http://localhost",
        "http://localhost:${LISTEN_PORT}",
        "http://127.0.0.1:${LISTEN_PORT}"
      ]
    }
  },

  // Environment Variables (LLM Keys)
  env: {
    ${ENV_ENTRY}
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
fi

# --- Execute Deployment ---
echo "Starting container as root (Version: 2026.4.10)..."

$CONTAINER_RUNTIME rm -f "${CONTAINER_NAME}" 2>/dev/null

RUN_CMD="$CONTAINER_RUNTIME run -d \
    --name ${CONTAINER_NAME} \
    --restart always \
    --user root \
    -p ${LISTEN_PORT}:18789 \
    -v $APP_DIR:/root/.openclaw:Z \
    -e NODE_ENV=production \
    ghcr.io/openclaw/openclaw:2026.4.10"

eval "$RUN_CMD"

if [ $? -eq 0 ]; then
    echo "--------------------------------------------------"
    echo "Deployment Complete!"
    SERVER_IP=$(curl -s --max-time 2 https://api.ipify.org || echo "YOUR_SERVER_IP")
    echo "Web UI Access: http://${SERVER_IP}:${LISTEN_PORT}"
    echo "Config directory: $APP_DIR"
    echo "--------------------------------------------------"
else
    echo "Error: Container failed to start!"
    exit 1
fi
