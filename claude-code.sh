#!/bin/sh

# ==============================================================================
# Description: Persistent Node-based deployment for Claude Code.
# Features: Runtime detection, Persistent config, and Skip-permissions alias.
# ==============================================================================

# --- 0. Version Configuration ---
CC_VERSION="2.1.133"

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

# --- 2. Image Preparation (Using Official Node Base + procps) ---
LOCAL_TAG="claude-code:$CC_VERSION"
IMG_ID=$($RUNTIME images -q "$LOCAL_TAG" 2>/dev/null)

if [ -z "$IMG_ID" ]; then
    echo "[>] Building Claude Code Image (Node Bookworm-Slim @$CC_VERSION)"
    TMP_DF=$(mktemp)
    cat <<EOF > "$TMP_DF"
FROM node:20-bookworm-slim
RUN apt-get update && apt-get install -y procps && \\
    rm -rf /var/lib/apt/lists/*
RUN npm install -g @anthropic-ai/claude-code@$CC_VERSION && \\
    npm cache clean --force
# Pre-configure onboarding and add skip-permissions alias
RUN echo '{"hasCompletedOnboarding": true}' > /root/.claude.json && \\
    echo 'alias claude="claude --dangerously-skip-permissions"' >> /root/.bashrc
WORKDIR /workspace
ENTRYPOINT ["/bin/bash"]
EOF
    $RUNTIME build -t "$LOCAL_TAG" -f "$TMP_DF" .
    IMG_ID=$($RUNTIME images -q "$LOCAL_TAG" 2>/dev/null)
    rm "$TMP_DF"

    if [ -z "$IMG_ID" ]; then
        echo "[!] Error: Image build failed."
        exit 1
    fi
fi

# --- 3. Workspace & Config Configuration ---
echo "[>] Configuring Claude Code Deployment"

DEFAULT_WORKSPACE="$HOME/Projects"
printf "Local workspace folder [%s]: " "$DEFAULT_WORKSPACE"
read -r WORKSPACE_FOLDER
WORKSPACE_FOLDER=${WORKSPACE_FOLDER:-$DEFAULT_WORKSPACE}

# Path Expansion: Handle ~ and $HOME strings
WORKSPACE_FOLDER=$(echo "$WORKSPACE_FOLDER" | sed "s|^~|$HOME|")
WORKSPACE_FOLDER=$(eval echo "$WORKSPACE_FOLDER")

CONFIG_DIR="$WORKSPACE_FOLDER/.claude"
SETTINGS_FILE="$CONFIG_DIR/settings.json"

mkdir -p "$CONFIG_DIR" 2>/dev/null

if [ -f "./CLAUDE.md" ]; then
    if [ ! -f "$CONFIG_DIR/CLAUDE.md" ]; then
        echo "[>] Copying CLAUDE.md to config directory"
        cp "./CLAUDE.md" "$CONFIG_DIR/CLAUDE.md"
    else
        echo "[>] CLAUDE.md already exists. Skipping."
    fi
fi

if [ -f "$SETTINGS_FILE" ]; then
    echo "[>] Existing configuration found at $SETTINGS_FILE"
else
    echo "[!] Initial Setup: API Configuration Required"
    while [ -z "$INPUT_BASE_URL" ]; do printf "ANTHROPIC_BASE_URL: "; read -r INPUT_BASE_URL; done
    while [ -z "$INPUT_TOKEN" ]; do printf "ANTHROPIC_AUTH_TOKEN: "; read -r INPUT_TOKEN; done
    while [ -z "$INPUT_MODEL" ]; do printf "ANTHROPIC_MODEL: "; read -r INPUT_MODEL; done

    cat <<EOF > "$SETTINGS_FILE"
{
  "env": {
    "ANTHROPIC_BASE_URL": "$INPUT_BASE_URL",
    "ANTHROPIC_AUTH_TOKEN": "$INPUT_TOKEN",
    "ANTHROPIC_MODEL": "$INPUT_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "$INPUT_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "$INPUT_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "$INPUT_MODEL",
    "DISABLE_AUTOUPDATER": "1"
  },
  "effortLevel": "low",
  "theme": "dark",
  "autoCompactEnabled": true,
  "showTurnDuration": true,
  "showMessageTimestamps": true,
  "permissions": {
    "allow": ["Bash(*)", "Edit(*)", "Write(*)", "NotebookEdit(*)"]
  }
}
EOF
fi

# --- 4. Container Naming & Hostname ---
DEFAULT_CONTAINER_NAME="cc"
printf "Container name [%s]: " "$DEFAULT_CONTAINER_NAME"
read -r CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}
CONTAINER_HOSTNAME="$(hostname)-$CONTAINER_NAME"

# --- 5. Shell Configuration Setup ---
FUNC_NAME="cc$CONTAINER_NAME"
START_SIG="# <CC-MANAGED-START:$FUNC_NAME>"
END_SIG="# <CC-MANAGED-END:$FUNC_NAME>"

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
                    rm "$TMP_RC"

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

# --- 6. Launch Initial Container ---
echo "[>] Launching Claude Code Container"
$RUNTIME rm -f "$CONTAINER_NAME" 2>/dev/null

$RUNTIME run -it \
    --name "$CONTAINER_NAME" \
    --hostname "$CONTAINER_HOSTNAME" \
    --user root \
    --pull never \
    -e IS_SANDBOX=1 \
    -v "$WORKSPACE_FOLDER:/workspace" \
    -v "$CONFIG_DIR:/root/.claude" \
    "$IMG_ID"

if [ $? -eq 0 ]; then
    echo "[>] Session Finished"
else
    echo "[!] Error: Container execution failed."
    exit 1
fi
