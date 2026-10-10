#!/bin/sh
# ==============================================================================
# Description: Persistent container deployment for Claude Code with WireGuard.
# Features: Runtime detection, persistent config, VPN startup, port range mapping, and shell alias.
# ==============================================================================

# --- 0. Version and WireGuard Configuration ---
CC_CHANNEL="stable"

printf "WireGuard configuration file path: "
read -r WG_CONFIG
case "$WG_CONFIG" in
    "~"|"~/"*) WG_CONFIG="$HOME${WG_CONFIG#\~}" ;;
esac

if [ ! -f "$WG_CONFIG" ]; then
    echo "[!] Error: WireGuard configuration file not found: $WG_CONFIG"
    exit 1
fi

WG_CONFIG_DIR=$(dirname "$WG_CONFIG")
WG_CONFIG="$(cd "$WG_CONFIG_DIR" && pwd)/$(basename "$WG_CONFIG")"

# --- 1. Runtime Auto-Detection (Prioritizing Podman) ---
if command -v podman >/dev/null 2>&1; then
    RUNTIME="podman --cgroup-manager=cgroupfs"
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

case "$RUNTIME" in
    *podman*)
        # Podman 5 defaults to pasta and may ship without slirp4netns
        if command -v slirp4netns >/dev/null 2>&1 || [ -x /usr/libexec/podman/slirp4netns ]; then
            NETWORK_MODE="slirp4netns"
        else
            NETWORK_MODE="pasta"
        fi
        ;;
    *docker*) NETWORK_MODE="bridge" ;;
    *)
        echo "[!] Error: Cannot guarantee isolated networking for runtime [$RUNTIME]."
        exit 1
        ;;
esac

echo "[>] Runtime: Using [$RUNTIME] for deployment (network: $NETWORK_MODE)"

# --- 1b. Port Range Configuration ---
# Accepts START-END with 1 <= START <= END <= 65535
is_valid_port_range() {
    case "$1" in
        [0-9]*-[0-9]*) ;;
        *) return 1 ;;
    esac
    case "$1" in
        *[!0-9-]*|*-*-*) return 1 ;;
    esac
    _start=${1%-*}
    _end=${1#*-}
    [ "${#_start}" -le 5 ] && [ "${#_end}" -le 5 ] &&
        [ "$_start" -ge 1 ] && [ "$_end" -le 65535 ] && [ "$_start" -le "$_end" ]
}

DEFAULT_PORT_RANGE="9000-9100"
printf "Host port range to expose [%s] (0 = none): " "$DEFAULT_PORT_RANGE"
read -r PORT_RANGE
PORT_RANGE=${PORT_RANGE:-$DEFAULT_PORT_RANGE}
if [ "$PORT_RANGE" != "0" ]; then
    if is_valid_port_range "$PORT_RANGE"; then
        echo "[>] Exposing port range $PORT_RANGE (host:container = $PORT_RANGE:$PORT_RANGE)"
    else
        echo "[!] Invalid port range: $PORT_RANGE (expected START-END within 1-65535)"
        exit 1
    fi
else
    echo "[>] Port exposure disabled"
fi

# --- 2. Image Preparation (Official Claude Code npm package + WireGuard) ---
LOCAL_TAG="claude-code:$CC_CHANNEL"
OLD_IMG_ID=$($RUNTIME images -q "$LOCAL_TAG" 2>/dev/null)

# Resolve the channel to a concrete version so the npm layer is only rebuilt on release
CC_VERSION=$(curl -fsSL --max-time 10 "https://registry.npmjs.org/@anthropic-ai/claude-code/$CC_CHANNEL" 2>/dev/null |
    sed -n 's/.*"version":"\([^"]*\)".*/\1/p')

TMP_BUILD=$(mktemp -d)
if [ $? -ne 0 ]; then
    echo "[!] Error: Failed to create temporary build directory."
    exit 1
fi
trap 'rm -rf "$TMP_BUILD"' 0
trap 'exit 1' HUP INT TERM

if [ -n "$CC_VERSION" ]; then
    BUILD_NONCE="$CC_VERSION"
else
    echo "[!] Warning: Could not resolve Claude Code @$CC_CHANNEL version; forcing a fresh install."
    CC_VERSION="$CC_CHANNEL"
    BUILD_NONCE=${TMP_BUILD##*/}
fi
echo "[>] Building Claude Code Image (Claude Code @$CC_VERSION)"

if ! cp "$WG_CONFIG" "$TMP_BUILD/wg0.conf" || ! chmod 600 "$TMP_BUILD/wg0.conf"; then
    echo "[!] Error: Failed to prepare WireGuard configuration for image build."
    exit 1
fi

TMP_DF="$TMP_BUILD/Dockerfile"

cat <<EOF > "$TMP_DF"
FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \\
    bash ca-certificates curl iproute2 iptables libcap2-bin openresolv procps util-linux wireguard-tools && \\
    rm -rf /var/lib/apt/lists/*
ARG BUILD_NONCE
RUN echo "\$BUILD_NONCE" >/dev/null && npm install -g @anthropic-ai/claude-code@$CC_VERSION && \\
    npm cache clean --force
COPY wg0.conf /etc/wireguard/wg0.conf
RUN chmod 600 /etc/wireguard/wg0.conf
RUN printf '%s\\n' '#!/bin/bash' 'set -e' \\
    'lock_egress() {' \\
    '    iptables -F OUTPUT' \\
    '    iptables -P OUTPUT DROP' \\
    '    iptables -A OUTPUT -o lo -p udp --dport 53 -j REJECT' \\
    '    iptables -A OUTPUT -o lo -p tcp --dport 53 -j REJECT' \\
    '    iptables -A OUTPUT -o lo -j ACCEPT' \\
    '    iptables -A OUTPUT -o wg0 -j ACCEPT' \\
    '    if [ -n "\$CC_PORT_RANGE" ]; then' \\
    '        iptables -A OUTPUT -p tcp --sport "\${CC_PORT_RANGE/-/:}" -m conntrack --ctstate ESTABLISHED -j ACCEPT' \\
    '    fi' \\
    '    ip6tables -F OUTPUT' \\
    '    ip6tables -P OUTPUT DROP' \\
    '    ip6tables -A OUTPUT -o lo -p udp --dport 53 -j REJECT' \\
    '    ip6tables -A OUTPUT -o lo -p tcp --dport 53 -j REJECT' \\
    '    ip6tables -A OUTPUT -o lo -j ACCEPT' \\
    '    ip6tables -A OUTPUT -o wg0 -j ACCEPT' \\
    '    if [ -n "\$CC_PORT_RANGE" ]; then' \\
    '        ip6tables -A OUTPUT -p tcp --sport "\${CC_PORT_RANGE/-/:}" -m conntrack --ctstate ESTABLISHED -j ACCEPT' \\
    '    fi' \\
    '    found_endpoint=0' \\
    '    while IFS= read -r line; do' \\
    '        if [[ \$line =~ ^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*(.*)\$ ]]; then' \\
    '            endpoint=\${BASH_REMATCH[1]//[[:space:]]/}' \\
    '            host=\${endpoint%:*}' \\
    '            port=\${endpoint##*:}' \\
    '            host=\${host#\\[}' \\
    '            host=\${host%\\]}' \\
    '            if [ -z "\$host" ] || [ -z "\$port" ] || [[ \$port == *[!0-9]* ]]; then' \\
    '                echo "[!] Invalid WireGuard Endpoint; use an IP address and UDP port."' \\
    '                return 1' \\
    '            elif [[ \$host == *:* ]]; then' \\
    '                ip6tables -A OUTPUT -p udp -d "\$host" --dport "\$port" -j ACCEPT' \\
    '            elif [[ \$host == *[!0-9.]* ]]; then' \\
    '                echo "[!] WireGuard Endpoint must use a literal IP address."' \\
    '                return 1' \\
    '            else' \\
    '                iptables -A OUTPUT -p udp -d "\$host" --dport "\$port" -j ACCEPT' \\
    '            fi' \\
    '            found_endpoint=1' \\
    '        fi' \\
    '    done < /etc/wireguard/wg0.conf' \\
    '    [ "\$found_endpoint" -eq 1 ]' \\
    '}' \\
    'lock_egress' 'wg-quick up /etc/wireguard/wg0.conf' 'lock_egress' \\
    'exec capsh --drop=cap_net_admin,cap_net_raw -- -i' \\
    > /usr/local/bin/cc-entrypoint && chmod +x /usr/local/bin/cc-entrypoint && \\
    echo 'alias claude="claude --dangerously-skip-permissions"' >> /root/.bashrc
ENV COLORTERM=truecolor
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/cc-entrypoint"]
EOF

$RUNTIME build --build-arg "BUILD_NONCE=$BUILD_NONCE" -t "$LOCAL_TAG" -f "$TMP_DF" "$TMP_BUILD"
BUILD_STATUS=$?
rm -rf "$TMP_BUILD"
trap - 0 HUP INT TERM
if [ "$BUILD_STATUS" -ne 0 ]; then
    echo "[!] Error: Container image build failed."
    exit 1
fi

IMG_ID=$($RUNTIME images -q "$LOCAL_TAG" 2>/dev/null)

if [ -z "$IMG_ID" ]; then
    echo "[!] Error: Image ID could not be resolved."
    exit 1
fi

# --- 3. Workspace & Config Configuration ---
echo "[>] Configuring Claude Code Deployment"

DEFAULT_WORKSPACE="$HOME/Projects"
printf "Local workspace folder [%s]: " "$DEFAULT_WORKSPACE"
read -r WORKSPACE_FOLDER
WORKSPACE_FOLDER=${WORKSPACE_FOLDER:-$DEFAULT_WORKSPACE}

# Path Expansion: Handle ~ and $HOME prefixes without evaluating the input
case "$WORKSPACE_FOLDER" in
    "~"|"~/"*) WORKSPACE_FOLDER="$HOME${WORKSPACE_FOLDER#\~}" ;;
    '$HOME'|'$HOME/'*) WORKSPACE_FOLDER="$HOME${WORKSPACE_FOLDER#\$HOME}" ;;
esac

# Bind mounts need an absolute path; a relative one would become a named volume
if ! mkdir -p "$WORKSPACE_FOLDER" 2>/dev/null || ! WORKSPACE_FOLDER=$(cd "$WORKSPACE_FOLDER" && pwd); then
    echo "[!] Error: Cannot use workspace folder: $WORKSPACE_FOLDER"
    exit 1
fi

CONFIG_DIR="$WORKSPACE_FOLDER/.config/claude"
SETTINGS_FILE="$CONFIG_DIR/settings.json"
LEGACY_CONFIG_DIR="$WORKSPACE_FOLDER/.claude"

if [ ! -d "$CONFIG_DIR" ] && [ -f "$LEGACY_CONFIG_DIR/.credentials.json" ]; then
    echo "[>] Migrating config from $LEGACY_CONFIG_DIR to $CONFIG_DIR"
    mkdir -p "$(dirname "$CONFIG_DIR")" && cp -a "$LEGACY_CONFIG_DIR" "$CONFIG_DIR"
    if [ $? -ne 0 ]; then
        echo "[!] Error: Failed to migrate configuration directory."
        exit 1
    fi
    echo "[>] Old directory kept; remove $LEGACY_CONFIG_DIR manually once verified"
fi

mkdir -p "$CONFIG_DIR" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "[!] Error: Failed to create configuration directory at $CONFIG_DIR. Check permissions."
    exit 1
fi

if [ -f "$SETTINGS_FILE" ]; then
    echo "[>] Existing configuration found at $SETTINGS_FILE"
fi

# --- 4. Container Naming & Hostname ---
DEFAULT_CONTAINER_NAME="cc"
printf "Container name [%s]: " "$DEFAULT_CONTAINER_NAME"
read -r CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}
case "$CONTAINER_NAME" in
    [!a-zA-Z0-9]*|*[!a-zA-Z0-9_.-]*)
        echo "[!] Invalid container name: $CONTAINER_NAME (use letters, digits, '_', '.', '-')"
        exit 1
        ;;
esac
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
    if $RUNTIME ps -a --format '{{.Names}}' | grep -Fxq \"$CONTAINER_NAME\"; then
        if [ \"\$($RUNTIME inspect -f '{{.State.Running}}' $CONTAINER_NAME 2>/dev/null)\" != \"true\" ]; then
            echo \"[>] Starting container: $CONTAINER_NAME\"
            if ! $RUNTIME start $CONTAINER_NAME >/dev/null; then
                echo \"[!] Error: Failed to start container: $CONTAINER_NAME\"
                return 1
            fi
        fi
        $RUNTIME exec -it $CONTAINER_NAME capsh --drop=cap_net_admin,cap_net_raw -- -i
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

# --- 6. Launch Initial Container ---
if $RUNTIME ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    printf "Container '%s' exists; files outside mounted folders will be lost. Recreate? [Y/n]: " "$CONTAINER_NAME"
    read -r CONFIRM_RECREATE
    case "${CONFIRM_RECREATE:-y}" in
        y|Y) ;;
        *)
            echo "[>] Keeping existing container. Use '$FUNC_NAME' to enter it."
            exit 0
            ;;
    esac
    if [ ! -f "$CONFIG_DIR/.claude.json" ] && \
        $RUNTIME cp "$CONTAINER_NAME:/root/.claude.json" "$CONFIG_DIR/.claude.json" 2>/dev/null; then
        echo "[>] Saved .claude.json from previous container"
    fi
    if ! $RUNTIME rm -f "$CONTAINER_NAME" >/dev/null; then
        echo "[!] Error: Failed to remove existing container: $CONTAINER_NAME"
        exit 1
    fi
fi

# The previous image embeds the old WireGuard key; drop it once no container uses it
if [ -n "$OLD_IMG_ID" ] && [ "$OLD_IMG_ID" != "$IMG_ID" ]; then
    $RUNTIME rmi "$OLD_IMG_ID" >/dev/null 2>&1 && echo "[>] Removed previous image $OLD_IMG_ID"
fi

echo "[>] Launching Claude Code Container"

PORT_ARGS=""
if [ "$PORT_RANGE" != "0" ]; then
    PORT_ARGS="-p $PORT_RANGE:$PORT_RANGE -e CC_PORT_RANGE=$PORT_RANGE"
fi

$RUNTIME run -it \
  --name "$CONTAINER_NAME" \
  --hostname "$CONTAINER_HOSTNAME" \
  --network="$NETWORK_MODE" \
  --user root \
  --pull never \
  --cap-add=SYS_PTRACE \
  --cap-add=NET_ADMIN \
  --device=/dev/net/tun \
  --sysctl=net.ipv4.conf.all.src_valid_mark=1 \
  --shm-size=4g \
  -e IS_SANDBOX=1 \
  -e CLAUDE_CONFIG_DIR=/root/.claude \
  $PORT_ARGS \
  -v "$WORKSPACE_FOLDER:/workspace:z" \
  -v "$CONFIG_DIR:/root/.claude:z" \
  "$IMG_ID"
RUN_STATUS=$?

# 125 is the runtime's own failure; other codes come from the container (entrypoint or last shell command)
if [ "$RUN_STATUS" -eq 0 ]; then
    echo "[>] Session Finished"
elif [ "$RUN_STATUS" -eq 125 ]; then
    echo "[!] Error: Container execution failed."
    exit 1
else
    echo "[!] Container exited with code $RUN_STATUS"
    exit "$RUN_STATUS"
fi
