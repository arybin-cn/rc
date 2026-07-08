#!/bin/sh
# ==============================================================================
# Description: Persistent deployment for OpenCode TUI.
# Features: Runtime detection, Persistent config, and Skip-permissions alias.
# Optimizations: Added SYS_PTRACE capability and 4GB SHM size for development.
# ==============================================================================

# --- 0. Version Configuration ---
OC_VERSION="1.17.15"

# --- 1. Runtime Auto-Detection (Prioritizing Podman) ---
if command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
elif command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
else
    printf "Enter container runtime command (e.g., podman): "
    read -r RUNTIME
fi

if [ -z "$RUNTIME" ]; then
    echo "[!] Error: No container runtime specified. Exiting."
    exit 1
fi

echo "[>] Runtime: Using [$RUNTIME] for deployment"

# --- 2. Image Preparation (Using Slim Base + Prebuilt Binary) ---
LOCAL_TAG="opencode:$OC_VERSION"
IMG_ID=$($RUNTIME images -q "$LOCAL_TAG" 2>/dev/null)

if [ -z "$IMG_ID" ]; then
    echo "[>] Building OpenCode TUI Image (Debian Bookworm-Slim)"
    TMP_DF=$(mktemp)
    if [ $? -ne 0 ]; then
        echo "[!] Error: Failed to create temporary file."
        exit 1
    fi

    cat <<EOF > "$TMP_DF"
FROM debian:bookworm-slim
# Install dependencies, Node.js, and OpenCode in single layer
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        procps git curl ca-certificates ripgrep fzf && \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    npm install -g opencode-ai@${OC_VERSION} && \
    npm cache clean --force && \
    apt-get purge -y curl && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/* /tmp/* /root/.npm
RUN echo "alias oc='opencode'" >> /root/.bashrc
WORKDIR /workspace
ENTRYPOINT ["/bin/bash"]
EOF

    $RUNTIME build -t "$LOCAL_TAG" -f "$TMP_DF" .
    if [ $? -ne 0 ]; then
        echo "[!] Error: Container image build failed."
        echo "[>] Dockerfile content:"
        cat "$TMP_DF"
        exit 1
    fi

    IMG_ID=$($RUNTIME images -q "$LOCAL_TAG" 2>/dev/null)
    rm "$TMP_DF" 2>/dev/null
fi

if [ -z "$IMG_ID" ]; then
    echo "[!] Error: Image ID could not be resolved."
    exit 1
fi

# --- 5. Workspace & Config Configuration ---
echo "[>] Configuring OpenCode TUI Deployment"

DEFAULT_WORKSPACE="$HOME/Projects"
printf "Local workspace folder [%s]: " "$DEFAULT_WORKSPACE"
read -r WORKSPACE_FOLDER
WORKSPACE_FOLDER=${WORKSPACE_FOLDER:-$DEFAULT_WORKSPACE}

# Path Expansion: Handle ~ and $HOME strings
WORKSPACE_FOLDER=$(echo "$WORKSPACE_FOLDER" | sed "s|^~|$HOME|")
WORKSPACE_FOLDER=$(eval echo "$WORKSPACE_FOLDER")

CONFIG_DIR="$WORKSPACE_FOLDER/.config/opencode"
CONFIG_FILE="$CONFIG_DIR/opencode.jsonc"
LOCAL_DIR="$WORKSPACE_FOLDER/.local"

mkdir -p "$CONFIG_DIR" 2>/dev/null
mkdir -p "$LOCAL_DIR" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "[!] Error: Failed to create configuration directory at $CONFIG_DIR. Check permissions."
    exit 1
fi


if [ -f "$CONFIG_FILE" ]; then
    echo "[>] Existing configuration found at $CONFIG_FILE"
else
    echo "[!] Initial Setup: API Configuration Required"
    echo "[>] Please configure your provider, model, and API key in $CONFIG_FILE after deployment."

    cat <<EOF > "$CONFIG_FILE"
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "opencode-go": {
      "options": {
        "baseURL": "https://opencode.ai/zen/go/v1",
        "apiKey": ""
      },
      "models": {
        "mimo-v2.5": {}
      }
    }
  },
  "model": "opencode-go/mimo-v2.5",
  "default_agent": "build",
  "autoupdate": false,
  "compaction": {
    "auto": true
  }
}
EOF
fi

# --- 6. Container Naming & Hostname ---
DEFAULT_CONTAINER_NAME="oc"
printf "Container name [%s]: " "$DEFAULT_CONTAINER_NAME"
read -r CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}
CONTAINER_HOSTNAME="$(hostname)-$CONTAINER_NAME"

# --- 7. Shell Configuration Setup ---
FUNC_NAME="oc$CONTAINER_NAME"
START_SIG="# <OC-MANAGED-START:$FUNC_NAME>"
END_SIG="# <OC-MANAGED-END:$FUNC_NAME>"

printf "Update '%s' function in shell config? [Y/n]: " "$FUNC_NAME"
read -r CONFIRM_SHELL
CONFIRM_SHELL=${CONFIRM_SHELL:-y}

if [ "$CONFIRM_SHELL" = "y" ] || [ "$CONFIRM_SHELL" = "Y" ]; then
    FUNC_BODY="$START_SIG
function $FUNC_NAME() {
    if $RUNTIME ps -a --format '{{.Names}}' | grep -Eq \"^$CONTAINER_NAME\\\$\"; then
        if [ \"\$($RUNTIME inspect -f '{{.State.Running}}' $CONTAINER_NAME 2>/dev/null)\" != \"true\" ]; then
            echo \"[>] Starting container: $CONTAINER_NAME\"
            $RUNTIME start $CONTAINER_NAME >/dev/null
        fi
        $RUNTIME exec -it $CONTAINER_NAME /bin/bash
    else
        echo \"[!] Error: Container $CONTAINER_NAME not found. Run deployment script again.\"
    fi
}
$END_SIG"

    for RC_FILE in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$RC_FILE" ]; then
            [ -n "$(tail -c1 "$RC_FILE" 2>/dev/null)" ] && printf "\n" >> "$RC_FILE"

            if grep -q "function $FUNC_NAME()" "$RC_FILE"; then
                if grep -q "$START_SIG" "$RC_FILE"; then
                    TMP_RC=$(mktemp)
                    sed "/$START_SIG/,/$END_SIG/d" "$RC_FILE" > "$TMP_RC"
                    cat "$TMP_RC" > "$RC_FILE"
                    rm "$TMP_RC" 2>/dev/null
                    echo "$FUNC_BODY" >> "$RC_FILE"
                    echo "[>] Updated '$FUNC_NAME' in $RC_FILE"
                else
                    echo "[!] Warning: Custom '$FUNC_NAME' exists. Skipping automated update."
                fi
            else
                echo "$FUNC_BODY" >> "$RC_FILE"
                echo "[>] Added '$FUNC_NAME' to $RC_FILE"
            fi
        fi
    done
fi

# --- 8. Launch Initial Container ---
echo "[>] Launching OpenCode TUI Container"
$RUNTIME rm -f "$CONTAINER_NAME" 2>/dev/null

$RUNTIME run -it \
  --name "$CONTAINER_NAME" \
  --hostname "$CONTAINER_HOSTNAME" \
  --user root \
  --pull never \
  --cap-add=SYS_PTRACE \
  --shm-size=4g \
  -e IS_SANDBOX=1 \
  -v "$WORKSPACE_FOLDER:/workspace:Z" \
  -v "$WORKSPACE_FOLDER/.config:/root/.config:Z" \
  -v "$WORKSPACE_FOLDER/.local:/root/.local:Z" \
  "$IMG_ID"

if [ $? -eq 0 ]; then
    echo "[>] Session Finished"
else
    echo "[!] Error: Container execution failed."
    exit 1
fi
