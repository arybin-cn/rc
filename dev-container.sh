#!/bin/sh
# ==============================================================================
# Description: Paired development and WireGuard network containers.
# Features: Claude Code, Codex, OpenCode, persistent config, VPN, and browser desktop.
# ==============================================================================

# --- 0. Version and WireGuard Configuration ---
CC_VERSION="2.1.296"
CODEX_VERSION="0.162.1"
OC_VERSION="1.18.21"

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

# --- 1. Container Runtime (Prefer Podman) ---
if command -v podman >/dev/null 2>&1; then
    RUNTIME_NAME=podman
    RUNTIME="podman --cgroup-manager=cgroupfs"
elif command -v docker >/dev/null 2>&1; then
    RUNTIME_NAME=docker
    RUNTIME=docker
else
    echo "[!] Install Podman or Docker before running this script."
    exit 1
fi
# Keep Podman's backend selection while Docker uses its isolated bridge network.
echo "[>] Runtime: $RUNTIME_NAME (paired network container)"

# --- 1b. Port Range Configuration ---
# Accepts START-END with 1 <= START <= END <= 65535
is_valid_port() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
    esac
    [ "${#1}" -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

DEFAULT_BROWSER_PORT=9988
printf "Browser desktop port [%s]: " "$DEFAULT_BROWSER_PORT"
read -r BROWSER_PORT
BROWSER_PORT=${BROWSER_PORT:-$DEFAULT_BROWSER_PORT}
if ! is_valid_port "$BROWSER_PORT"; then
    echo "[!] Invalid browser desktop port: $BROWSER_PORT (expected 1-65535)"
    exit 1
fi

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
        PORT_START=${PORT_RANGE%-*}
        PORT_END=${PORT_RANGE#*-}
        if [ "$PORT_START" -le "$BROWSER_PORT" ] && [ "$PORT_END" -ge "$BROWSER_PORT" ]; then
            echo "[!] Port range $PORT_RANGE overlaps the browser desktop port $BROWSER_PORT. Choose a different range."
            exit 1
        fi
        echo "[>] Exposing port range $PORT_RANGE (host:container = $PORT_RANGE:$PORT_RANGE)"
    else
        echo "[!] Invalid port range: $PORT_RANGE (expected START-END within 1-65535)"
        exit 1
    fi
else
    echo "[>] Port exposure disabled"
fi

# --- 1c. Direct LAN Access (bypassing the VPN) ---
# Prints the canonical network form of a private IPv4 CIDR, or fails.
# Restricting to RFC 1918 keeps this from being usable to bypass the VPN for public traffic.
normalize_private_cidr() {
    case "$1" in
        */*) ;;
        *) return 1 ;;
    esac
    _addr=${1%/*}
    _len=${1#*/}
    case "$_len" in ""|*[!0-9]*) return 1 ;; esac
    case "$_addr" in ""|*[!0-9.]*|*..*|.*|*.) return 1 ;; esac
    [ "${#_len}" -le 2 ] && [ "$_len" -le 32 ] || return 1
    _oldifs=$IFS; IFS=.
    # shellcheck disable=SC2086
    set -- $_addr
    IFS=$_oldifs
    [ "$#" -eq 4 ] || return 1
    for _octet in "$@"; do
        case "$_octet" in 0?*) return 1 ;; esac
        [ "${#_octet}" -le 3 ] && [ "$_octet" -le 255 ] || return 1
    done
    if [ "$1" -eq 10 ]; then _min=8
    elif [ "$1" -eq 172 ] && [ "$2" -ge 16 ] && [ "$2" -le 31 ]; then _min=12
    elif [ "$1" -eq 192 ] && [ "$2" -eq 168 ]; then _min=16
    else return 1
    fi
    [ "$_len" -ge "$_min" ] || return 1
    _ip=$(( ($1 << 24) | ($2 << 16) | ($3 << 8) | $4 ))
    _net=$(( _ip & ((0xFFFFFFFF << (32 - _len)) & 0xFFFFFFFF) ))
    echo "$(( (_net >> 24) & 255 )).$(( (_net >> 16) & 255 )).$(( (_net >> 8) & 255 )).$(( _net & 255 ))/$_len"
}

# Subnet of the host's default-route interface, if it can be determined
detect_lan_subnet() {
    command -v ip >/dev/null 2>&1 || return 0
    _dev=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
    [ -n "$_dev" ] || return 0
    ip -4 route show dev "$_dev" proto kernel scope link 2>/dev/null | awk 'NR == 1 {print $1}'
}

detect_host_lan_ip() {
    command -v ip >/dev/null 2>&1 || return 0
    _dev=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
    [ -n "$_dev" ] || return 0
    for _addr in $(ip -4 -o addr show dev "$_dev" scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}'); do
        if normalize_private_cidr "$_addr/32" >/dev/null 2>&1; then
            echo "$_addr"
            return 0
        fi
    done
}

HOST_LAN_IP=$(detect_host_lan_ip)
DEFAULT_LAN_SUBNETS=$(normalize_private_cidr "$(detect_lan_subnet)" 2>/dev/null) || DEFAULT_LAN_SUBNETS="0"
printf "Private LAN subnets reachable without VPN, comma-separated [%s] (0 = none): " "$DEFAULT_LAN_SUBNETS"
read -r LAN_INPUT
LAN_INPUT=${LAN_INPUT:-$DEFAULT_LAN_SUBNETS}
LAN_SUBNETS=""
if [ "$LAN_INPUT" != "0" ]; then
    for LAN_CIDR in $(echo "$LAN_INPUT" | tr ',' ' '); do
        if ! LAN_NORMALIZED=$(normalize_private_cidr "$LAN_CIDR"); then
            echo "[!] Invalid LAN subnet: $LAN_CIDR (expected a private IPv4 CIDR such as 192.168.1.0/24)"
            exit 1
        fi
        LAN_SUBNETS="${LAN_SUBNETS:+$LAN_SUBNETS,}$LAN_NORMALIZED"
    done
fi
if [ -n "$LAN_SUBNETS" ]; then
    echo "[>] Direct LAN access: $LAN_SUBNETS"
else
    echo "[>] Direct LAN access disabled"
fi

# --- 2. Development and Network Images ---
LOCAL_TAG="dev-container:agents"
NETWORK_TAG="dev-container:network"
OLD_IMG_ID=$($RUNTIME images -q "$LOCAL_TAG" 2>/dev/null)
BUILD_NONCE="$CC_VERSION-$CODEX_VERSION-$OC_VERSION"

TMP_BUILD=$(mktemp -d)
if [ $? -ne 0 ]; then
    echo "[!] Error: Failed to create temporary build directory."
    exit 1
fi
INSTALL_LOCK=
WG_IMPORT=
IMPORT_CONTAINER=
cleanup_build() {
    if [ -n "$IMPORT_CONTAINER" ]; then $RUNTIME rm -f "$IMPORT_CONTAINER" >/dev/null 2>&1 || :; fi
    if [ -n "$WG_IMPORT" ]; then rm -f "$WG_IMPORT"; fi
    if [ -n "$INSTALL_LOCK" ]; then rmdir "$INSTALL_LOCK" 2>/dev/null || :; fi
    rm -rf "$TMP_BUILD"
}
trap cleanup_build 0
trap 'exit 1' HUP INT TERM

echo "[>] Building development image (Claude Code @$CC_VERSION, Codex @$CODEX_VERSION, OpenCode @$OC_VERSION)"

cat <<'BROWSER_SCRIPT' > "$TMP_BUILD/bb"
#!/bin/bash
set -euo pipefail

STATE_DIR=/run/cc-browser
PID_FILE=$STATE_DIR/supervisor.pid
LOG_FILE=$STATE_DIR/supervisor.log
PROFILE_DIR=/tmp/cc-browser-profile
PASSWORD_FILE=$STATE_DIR/vnc-password
VNC_PASSWORD_FILE=$STATE_DIR/vnc.pass
PORT=${CC_BROWSER_PORT:-9988}

is_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

# Avoid treating a stale PID file as a running supervisor after PID reuse.
is_supervisor_running() {
    _supervisor_pid=$(cat "$PID_FILE" 2>/dev/null) || return 1
    case "$_supervisor_pid" in ""|*[!0-9]*) return 1 ;; esac
    kill -0 "$_supervisor_pid" 2>/dev/null || return 1
    [ -r "/proc/$_supervisor_pid/cmdline" ] &&
        tr '\0' ' ' < "/proc/$_supervisor_pid/cmdline" | grep -Fq "/usr/local/bin/bb supervise"
}

desktop_is_healthy() {
    is_supervisor_running &&
        [ -f "$PASSWORD_FILE" ] &&
        curl -fsS --max-time 1 "http://127.0.0.1:$PORT/vnc.html" >/dev/null 2>&1 &&
        pgrep -u cc-browser -x x11vnc >/dev/null 2>&1 &&
        pgrep -u cc-browser -x chromium >/dev/null 2>&1
}

show_access() {
    _path="/vnc.html?autoconnect=1&resize=scale&password=$(cat "$PASSWORD_FILE")"
    if [ -n "${CC_HOST_LAN_IP:-}" ]; then
        echo "[>] LAN URL: http://$CC_HOST_LAN_IP:$PORT$_path"
    else
        echo "[!] Host LAN IPv4 was not detected; use a LAN address assigned to the host."
    fi
    echo "[>] Local URL: http://localhost:$PORT$_path"
}

start_browser() {
    mkdir -p "$STATE_DIR" "$PROFILE_DIR" /home/cc-browser/.cache/fontconfig /home/cc-browser/.config
    chown cc-browser:cc-browser "$STATE_DIR" "$PROFILE_DIR" /home/cc-browser/.cache /home/cc-browser/.cache/fontconfig /home/cc-browser/.config
    if desktop_is_healthy; then
        show_access
        return 0
    fi
    if is_running || pgrep -u cc-browser >/dev/null 2>&1; then
        stop_browser
    fi
    rm -f "$PID_FILE"
    PASSWORD=$(openssl rand -base64 6 | tr '+/' '-_')
    printf '%s\n' "$PASSWORD" > "$PASSWORD_FILE"
    x11vnc -storepasswd "$PASSWORD" "$VNC_PASSWORD_FILE" >/dev/null 2>&1
    chown cc-browser:cc-browser "$PASSWORD_FILE" "$VNC_PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE" "$VNC_PASSWORD_FILE"
    : > "$LOG_FILE"
    chown cc-browser:cc-browser "$LOG_FILE"
    setpriv --reuid=cc-browser --regid=cc-browser --init-groups \
        /usr/local/bin/bb supervise >> "$LOG_FILE" 2>&1 </dev/null &
    echo "$!" > "$PID_FILE"
    for _ in {1..30}; do
        if ! is_running; then
            echo "[!] Browser desktop failed to start:"
            cat "$LOG_FILE"
            rm -f "$PID_FILE" "$PASSWORD_FILE" "$VNC_PASSWORD_FILE"
            return 1
        fi
        if desktop_is_healthy; then
            show_access
            return 0
        fi
        sleep 1
    done
    echo "[!] Browser desktop did not become ready:"
    cat "$LOG_FILE"
    stop_browser
    return 1
}

stop_browser() {
    was_running=0
    if is_supervisor_running; then
        was_running=1
        kill -TERM "$_supervisor_pid" 2>/dev/null || true
        for _ in {1..10}; do
            is_supervisor_running || break
            sleep 1
        done
        if is_supervisor_running; then
            kill -KILL "$_supervisor_pid" 2>/dev/null || true
        fi
    fi
    if pgrep -u cc-browser >/dev/null 2>&1; then
        pkill -TERM -u cc-browser 2>/dev/null || true
        sleep 1
        pkill -KILL -u cc-browser 2>/dev/null || true
    fi
    rm -f "$PID_FILE" "$PASSWORD_FILE" "$VNC_PASSWORD_FILE"
    if [ "$was_running" -eq 1 ]; then
        echo "[>] Browser desktop stopped"
    else
        echo "[>] Browser desktop is not running"
    fi
}

run_supervisor() {
    children=()
    cleanup() {
        trap - EXIT INT TERM
        pkill -TERM -u cc-browser -x chromium 2>/dev/null || true
        for ((i=${#children[@]} - 1; i >= 0; i--)); do
            kill "${children[i]}" 2>/dev/null || true
        done
        for ((i=${#children[@]} - 1; i >= 0; i--)); do
            wait "${children[i]}" 2>/dev/null || true
        done
        rm -f "$PID_FILE" "$PASSWORD_FILE" "$VNC_PASSWORD_FILE"
    }
    trap cleanup EXIT
    trap 'exit 0' INT TERM

    export HOME=/home/cc-browser
    export XDG_CACHE_HOME=$HOME/.cache
    export XDG_CONFIG_HOME=$HOME/.config
    export DISPLAY=:99
    Xvfb "$DISPLAY" -screen 0 1280x800x24 -nolisten tcp &
    children+=("$!")
    for _ in {1..50}; do
        [ -S /tmp/.X11-unix/X99 ] && break
        sleep 0.1
    done
    if [ ! -S /tmp/.X11-unix/X99 ]; then
        echo "[!] Xvfb failed to start"
        exit 1
    fi

    openbox --sm-disable &
    children+=("$!")
    x11vnc -display "$DISPLAY" -rfbport 5900 -localhost -forever -shared -rfbauth "$VNC_PASSWORD_FILE" &
    children+=("$!")
    websockify --web=/usr/share/novnc "0.0.0.0:$PORT" localhost:5900 &
    children+=("$!")
    chromium --user-data-dir="$PROFILE_DIR" --no-first-run --no-default-browser-check about:blank &
    children+=("$!")
    wait -n "${children[@]}"
}

case "${1:-toggle}" in
    toggle)
        if desktop_is_healthy; then
            stop_browser
        else
            start_browser
        fi
        ;;
    supervise)
        run_supervisor
        ;;
    *)
        echo "Usage: bb" >&2
        exit 2
        ;;
esac
BROWSER_SCRIPT
chmod 755 "$TMP_BUILD/bb"

TMP_DF="$TMP_BUILD/Dockerfile"

cat <<EOF > "$TMP_DF"
FROM node:22-bookworm-slim
# NET_RAW/NET_ADMIN are dropped at runtime, so binaries carrying those file capabilities
# cannot be executed. Hiding setcap makes package scripts fall back to plain binaries.
RUN dpkg-divert --local --rename --divert /sbin/setcap.real --add /sbin/setcap && \\
    apt-get update && apt-get install -y --no-install-recommends \\
    bash bubblewrap ca-certificates chromium curl fzf git iproute2 iptables iputils-ping novnc openbox openresolv procps ripgrep util-linux websockify wireguard-tools x11vnc xvfb && \\
    rm -rf /var/lib/apt/lists/*
# Keep WebRTC on Chromium's default route without exposing local interface addresses.
RUN mkdir -p /etc/chromium/policies/managed && \\
    printf '%s\\n' '{"WebRtcIPHandling":"default_public_interface_only"}' \\
    > /etc/chromium/policies/managed/webrtc.json && \\
    chmod 644 /etc/chromium/policies/managed/webrtc.json
ARG BUILD_NONCE
RUN echo "\$BUILD_NONCE" >/dev/null && npm install -g \\
    @anthropic-ai/claude-code@$CC_VERSION \\
    @openai/codex@$CODEX_VERSION \\
    opencode-ai@$OC_VERSION && \\
    npm cache clean --force
RUN useradd --system --create-home --home-dir /home/cc-browser --shell /usr/sbin/nologin cc-browser
COPY bb /usr/local/bin/bb
RUN chmod 755 /usr/local/bin/bb
RUN echo 'alias claude="claude --dangerously-skip-permissions"' >> /root/.bashrc && \\
    echo 'alias cc="claude"' >> /root/.bashrc && \\
    echo 'alias codex="codex --dangerously-bypass-approvals-and-sandbox"' >> /root/.bashrc && \\
    echo 'alias oc="opencode"' >> /root/.bashrc
ENV COLORTERM=truecolor
WORKDIR /workspace
ENTRYPOINT ["/bin/sleep", "infinity"]
EOF

$RUNTIME build --build-arg "BUILD_NONCE=$BUILD_NONCE" -t "$LOCAL_TAG" -f "$TMP_DF" "$TMP_BUILD"
BUILD_STATUS=$?
if [ "$BUILD_STATUS" -ne 0 ]; then
    echo "[!] Error: Container image build failed."
    exit 1
fi

IMG_ID=$($RUNTIME images -q "$LOCAL_TAG" 2>/dev/null)

if [ -z "$IMG_ID" ]; then
    echo "[!] Error: Image ID could not be resolved."
    exit 1
fi

# The network image has no development tools or workspace mounts.
cat <<'CONTAINER_ENTRY' > "$TMP_BUILD/network-entrypoint"
#!/bin/bash
set -euo pipefail
CC_LAN_SUBNETS=${CC_LAN_SUBNETS:-}
mode=${CC_NETWORK_MODE:?}
token=${CC_NETWORK_TOKEN:?}
case "$mode" in
    vpn|direct) ;;
    *) echo '[!] Invalid network mode.'; exit 1 ;;
esac
lock_egress() {
    for tool in iptables ip6tables; do
        "$tool" -w -P OUTPUT DROP
        "$tool" -w -P FORWARD DROP
        "$tool" -w -F OUTPUT
        for protocol in udp tcp; do
            "$tool" -w -A OUTPUT -o lo -p "$protocol" --dport 53 -j REJECT
        done
        "$tool" -w -A OUTPUT -o lo -j ACCEPT
        "$tool" -w -A OUTPUT -o wg0 -j ACCEPT
        "$tool" -w -A OUTPUT -p tcp --sport "$CC_BROWSER_PORT" -m conntrack --ctstate ESTABLISHED -m connmark --mark 0xcc02 -j ACCEPT
        if [ -n "${CC_PORT_RANGE:-}" ]; then
            "$tool" -w -A OUTPUT -p tcp --sport "${CC_PORT_RANGE/-/:}" -m conntrack --ctstate ESTABLISHED -m connmark --mark 0xcc02 -j ACCEPT
        fi
    done
    for destination in 'fe80::/10' 'ff02::/16'; do
        for kind in neighbor-solicitation neighbor-advertisement; do
            ip6tables -w -A OUTPUT -p ipv6-icmp --icmpv6-type "$kind" -d "$destination" -j ACCEPT
        done
    done
    for cidr in ${CC_LAN_SUBNETS//,/ }; do
        iptables -w -A OUTPUT -d "$cidr" -j ACCEPT
    done
    found=0
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%%#*}
        if [[ $line =~ ^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            endpoint=${BASH_REMATCH[1]//[[:space:]]/}
            host=${endpoint%:*}
            port=${endpoint##*:}
            host=${host#\[}
            host=${host%\]}
            if [[ -z $host || ! $port =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
                echo '[!] Invalid WireGuard Endpoint.'; return 1
            elif [[ $host == *:* ]]; then
                tool=ip6tables
            elif [[ $host == *[!0-9.]* ]]; then
                echo '[!] WireGuard Endpoint must use a literal IP address.'; return 1
            else
                tool=iptables
            fi
            "$tool" -w -A OUTPUT -m mark --mark 0xcc01 -p udp -d "$host" --dport "$port" -j ACCEPT
            found=1
        fi
    done < /etc/wireguard/wg0.conf
    [ "$found" -eq 1 ]
}
route_lan() {
    [ -n "$CC_LAN_SUBNETS" ] || return 0
    local gw='' dev='' prev='' word cidr
    for word in $(ip -4 route show table main default); do
        [ "$prev" = via ] && gw=$word
        [ "$prev" = dev ] && dev=$word
        prev=$word
    done
    [ -n "$gw" ] && [ -n "$dev" ] || return 1
    for cidr in ${CC_LAN_SUBNETS//,/ }; do
        if [ -z "$(ip -4 route show table main exact "$cidr")" ]; then
            ip route add "$cidr" via "$gw" dev "$dev"
        fi
    done
}
setup_published_replies() {
    local family tool gw dev prev word ports
    for family in -4 -6; do
        gw='' dev='' prev=''
        for word in $(ip "$family" route show table main default); do
            [ "$prev" = via ] && gw=$word
            [ "$prev" = dev ] && dev=$word
            prev=$word
        done
        if [ -z "$gw" ] || [ -z "$dev" ]; then
            continue
        fi
        tool=iptables
        [ "$family" = -4 ] || tool=ip6tables
        ip "$family" route add table 52226 default via "$gw" dev "$dev"
        ip "$family" rule add priority 100 fwmark 0xcc02 lookup 52226
        for ports in "$CC_BROWSER_PORT" "${CC_PORT_RANGE:-}"; do
            [ -n "$ports" ] || continue
            "$tool" -w -t mangle -A PREROUTING -i "$dev" -p tcp --dport "${ports/-/:}" -j CONNMARK --set-mark 0xcc02
        done
        "$tool" -w -t mangle -A OUTPUT -p tcp -m conntrack --ctstate ESTABLISHED -m connmark --mark 0xcc02 -j CONNMARK --restore-mark
    done
}
if [ "$mode" = vpn ]; then
    lock_egress
    setup_published_replies
    mkdir -p /run/cc-wireguard
    chmod 700 /run/cc-wireguard
    # Use a fixed socket mark so only tunnel UDP matches the physical exception.
    sed -e '/^[[:space:]]*FwMark[[:space:]]*=/Id' \
        -e '/^\[Interface\]$/a FwMark = 0xcc01' \
        -e '/^\[Interface\]$/a MTU = 1420' \
        /etc/wireguard/wg0.conf > /run/cc-wireguard/wg0.conf
    chmod 600 /run/cc-wireguard/wg0.conf
    if grep -Eq '^[[:space:]]*(PreUp|PostUp|PreDown|PostDown|SaveConfig)[[:space:]]*=' /etc/wireguard/wg0.conf; then
        echo '[!] WireGuard hooks and SaveConfig are not supported.'
        exit 1
    fi
    if ! PATH=/usr/local/lib/cc:$PATH wg-quick up /run/cc-wireguard/wg0.conf > /run/cc-wireguard/start.log 2>&1; then
        echo '[!] WireGuard initialization failed; check the host configuration.'
        exit 1
    fi
    route_lan
    lock_egress
fi
printf '%s %s\n' "$mode" "$token" > /run/cc-ready
exec sleep infinity
CONTAINER_ENTRY
cat <<'NETWORK_HEALTH' > "$TMP_BUILD/network-health"
#!/bin/bash
set -euo pipefail
read -r mode token < /run/cc-ready
[ "$mode $token" = "$CC_NETWORK_MODE $CC_NETWORK_TOKEN" ]
if [ "$mode" = vpn ]; then
    [ -n "$(ip link show up dev wg0)" ]
    for tool in iptables ip6tables; do
        [ "$("$tool" -w -S OUTPUT | head -n 1)" = '-P OUTPUT DROP' ]
    done
    # Bringing a link back up does not restore routes removed while it was down.
    routed=false
    while read -r _peer routes; do
        for route in ${routes//,/ }; do
            [ "$route" != '(none)' ] || continue
            family=-4
            [[ $route != *:* ]] || family=-6
            [ -n "$(ip "$family" route show table all exact "$route" dev wg0)" ]
            routed=true
        done
    done < <(wg show wg0 allowed-ips)
    [ "$routed" = true ]
fi
printf '%s %s\n' "$mode" "$token"
NETWORK_HEALTH
cat <<EOF > "$TMP_BUILD/Networkfile"
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \\
    bash iproute2 iptables wireguard-tools openresolv procps && \\
    rm -rf /var/lib/apt/lists/*
# wg-quick always writes src_valid_mark for full-tunnel configs, but /proc/sys is read-only in
# containers. The runtime already sets it via --sysctl, so accept writes whose value is in place.
RUN mkdir -p /usr/local/lib/cc && printf '%s\\n' '#!/bin/bash' \\
    'out=\$(/usr/sbin/sysctl "\$@" 2>&1) && { [[ -n \$out ]] && echo "\$out"; exit 0; }' \\
    'verified=' \\
    'for arg in "\$@"; do' \\
    '    [[ \$arg == *=* ]] || continue' \\
    '    key=\${arg%%=*}' \\
    '    if [[ \$(cat "/proc/sys/\${key//.//}" 2>/dev/null) != "\${arg#*=}" ]]; then' \\
    '        echo "\$out" >&2' \\
    '        exit 1' \\
    '    fi' \\
    '    verified=1' \\
    'done' \\
    '[[ -n \$verified ]] || { echo "\$out" >&2; exit 1; }' \\
    > /usr/local/lib/cc/sysctl && chmod +x /usr/local/lib/cc/sysctl
COPY network-entrypoint /usr/local/bin/cc-network-entrypoint
COPY network-health /usr/local/bin/cc-net-health
RUN mkdir -p /etc/wireguard && chmod 755 /usr/local/bin/cc-network-entrypoint /usr/local/bin/cc-net-health
ENTRYPOINT ["/bin/bash", "/usr/local/bin/cc-network-entrypoint"]
EOF
if ! $RUNTIME build -t "$NETWORK_TAG" -f "$TMP_BUILD/Networkfile" "$TMP_BUILD"; then
    echo "[!] Network image build failed."
    exit 1
fi
NETWORK_IMG_ID=$($RUNTIME images -q "$NETWORK_TAG" 2>/dev/null)
if [ -z "$NETWORK_IMG_ID" ]; then
    echo "[!] Network image ID could not be resolved."
    exit 1
fi

# --- 3. Workspace & Agent Configuration ---
echo "[>] Configuring Development Container"

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
if ! mkdir -p "$WORKSPACE_FOLDER" 2>/dev/null || ! WORKSPACE_FOLDER=$(cd "$WORKSPACE_FOLDER" && pwd -P); then
    echo "[!] Error: Cannot use workspace folder: $WORKSPACE_FOLDER"
    exit 1
fi

CONFIG_ROOT="$WORKSPACE_FOLDER/.config"
CLAUDE_CONFIG_DIR="$CONFIG_ROOT/claude"
CODEX_HOME_DIR="$CONFIG_ROOT/codex"
SSH_CONFIG_DIR="$CONFIG_ROOT/ssh"
CODEX_CONFIG_FILE="$CODEX_HOME_DIR/config.toml"
OPENCODE_CONFIG_DIR="$CONFIG_ROOT/opencode"
OPENCODE_CONFIG_FILE="$OPENCODE_CONFIG_DIR/opencode.jsonc"
LOCAL_DIR="$WORKSPACE_FOLDER/.local"
SETTINGS_FILE="$CLAUDE_CONFIG_DIR/settings.json"
LEGACY_CONFIG_DIR="$WORKSPACE_FOLDER/.claude"

if [ ! -d "$CLAUDE_CONFIG_DIR" ] && [ -f "$LEGACY_CONFIG_DIR/.credentials.json" ]; then
    echo "[>] Migrating config from $LEGACY_CONFIG_DIR to $CLAUDE_CONFIG_DIR"
    mkdir -p "$(dirname "$CLAUDE_CONFIG_DIR")" && cp -a "$LEGACY_CONFIG_DIR" "$CLAUDE_CONFIG_DIR"
    if [ $? -ne 0 ]; then
        echo "[!] Error: Failed to migrate configuration directory."
        exit 1
    fi
    echo "[>] Old directory kept; remove $LEGACY_CONFIG_DIR manually once verified"
fi

if ! mkdir -p "$CONFIG_ROOT" "$CLAUDE_CONFIG_DIR" "$CODEX_HOME_DIR" "$SSH_CONFIG_DIR" "$OPENCODE_CONFIG_DIR" "$LOCAL_DIR" 2>/dev/null; then
    echo "[!] Error: Failed to create agent configuration directories. Check permissions."
    exit 1
fi

if [ -f "$SETTINGS_FILE" ]; then
    echo "[>] Existing Claude Code configuration found at $SETTINGS_FILE"
fi

if [ -f "$CODEX_CONFIG_FILE" ]; then
    echo "[>] Existing Codex configuration found at $CODEX_CONFIG_FILE"
else
    cat <<EOF > "$CODEX_CONFIG_FILE"
# The rootless container is the outer security boundary; nested bubblewrap is unavailable.
approval_policy = "never"
sandbox_mode = "danger-full-access"
EOF
    if [ $? -ne 0 ]; then
        echo "[!] Error: Failed to create Codex configuration at $CODEX_CONFIG_FILE."
        exit 1
    fi
fi

if [ -f "$OPENCODE_CONFIG_FILE" ]; then
    echo "[>] Existing OpenCode configuration found at $OPENCODE_CONFIG_FILE"
else
    cat <<EOF > "$OPENCODE_CONFIG_FILE"
{
  "\$schema": "https://opencode.ai/config.json",
  "permission": "allow",
  "lsp": true,
  "default_agent": "build",
  "autoupdate": false,
  "compaction": {
    "auto": true
  }
}
EOF
    if [ $? -ne 0 ]; then
        echo "[!] Error: Failed to create OpenCode configuration at $OPENCODE_CONFIG_FILE."
        exit 1
    fi
fi

# --- 4. Container Naming & Hostname ---
BASE_CONTAINER_NAME="dc"
printf "Add a suffix to the container name? [y/N]: "
read -r ADD_SUFFIX
CONTAINER_SUFFIX=""
case "${ADD_SUFFIX:-n}" in
    y|Y|yes|YES|Yes)
        printf "Container suffix (lowercase letters and digits): "
        read -r CONTAINER_SUFFIX
        case "$CONTAINER_SUFFIX" in
            ""|*[!a-z0-9]*)
                echo "[!] Invalid suffix: $CONTAINER_SUFFIX (use lowercase letters and digits)"
                exit 1
                ;;
        esac
        ;;
    n|N|no|NO|No|"") ;;
    *)
        echo "[!] Invalid response: $ADD_SUFFIX (answer y or n)"
        exit 1
        ;;
esac

CONTAINER_NAME="$BASE_CONTAINER_NAME$CONTAINER_SUFFIX"
NETWORK_CONTAINER_NAME="$CONTAINER_NAME-net"
CONFIG_VOLUME="$NETWORK_CONTAINER_NAME-config"
CONTAINER_HOSTNAME="$(hostname)-$CONTAINER_NAME"

# Host controls must stay outside every writable container mount.
CONTROL_DIR="$HOME/.dev-container/$CONTAINER_NAME"
if ! (umask 077; mkdir -p "$CONTROL_DIR") || ! CONTROL_DIR=$(cd "$CONTROL_DIR" && pwd -P); then
    echo "[!] Cannot prepare host control directory."
    exit 1
fi
chmod 700 "$CONTROL_DIR" || exit 1
for SOURCE in "$WORKSPACE_FOLDER" "$CONFIG_ROOT" "$CLAUDE_CONFIG_DIR" "$CODEX_HOME_DIR" "$SSH_CONFIG_DIR" "$LOCAL_DIR"; do
    SOURCE=$(cd "$SOURCE" && pwd -P) || exit 1
    SOURCE=${SOURCE%/}
    case "$SOURCE/" in
        "$WORKSPACE_FOLDER/"*) ;;
        *) echo "[!] Writable configuration mounts must stay inside the workspace: $SOURCE"; exit 1 ;;
    esac
    case "$CONTROL_DIR/" in
        "$SOURCE/"*) echo "[!] Writable mount overlaps host controls: $SOURCE"; exit 1 ;;
    esac
    case "$SOURCE/" in
        "$CONTROL_DIR/"*) echo "[!] Writable mount overlaps host controls: $SOURCE"; exit 1 ;;
    esac
done

# --- 5. Existing Pair and Host Configuration ---
INSTALL_LOCK="$CONTROL_DIR/lock"
if ! mkdir "$INSTALL_LOCK" 2>/dev/null; then
    INSTALL_LOCK=
    echo "[!] A pair operation is in progress; check $CONTROL_DIR/lock before reinstalling."
    exit 1
fi
DEV_EXISTS=false
NET_EXISTS=false
if $RUNTIME container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then DEV_EXISTS=true; fi
if $RUNTIME container inspect "$NETWORK_CONTAINER_NAME" >/dev/null 2>&1; then
    NET_EXISTS=true
    if [ "$($RUNTIME container inspect -f '{{index .Config.Labels "dev-container.pair"}}' "$NETWORK_CONTAINER_NAME")" != "$CONTAINER_NAME" ] || \
            [ "$($RUNTIME container inspect -f '{{index .Config.Labels "dev-container.role"}}' "$NETWORK_CONTAINER_NAME")" != network ]; then
        echo "[!] Network container name is already used by an unrelated container: $NETWORK_CONTAINER_NAME"
        exit 1
    fi
fi
if [ "$DEV_EXISTS" = true ] || [ "$NET_EXISTS" = true ]; then
    printf "Pair '%s' exists; files outside mounted folders will be lost. Recreate both containers? [y/N]: " "$CONTAINER_NAME"
    CONFIRM_RECREATE=
    read -r CONFIRM_RECREATE || :
    case "$CONFIRM_RECREATE" in
        y|Y|yes|YES|Yes) ;;
        *) echo "[>] Keeping the existing containers."; exit 0 ;;
    esac
    if [ "$DEV_EXISTS" = true ]; then
        # Copy bytes, not a guest-controlled symlink, into the private data file.
        if [ ! -f "$CONTROL_DIR/claude.json" ] && \
                $RUNTIME exec "$CONTAINER_NAME" /bin/cat /root/.claude.json > "$CONTROL_DIR/claude.json.tmp" 2>/dev/null; then
            mv "$CONTROL_DIR/claude.json.tmp" "$CONTROL_DIR/claude.json" || exit 1
        else
            rm -f "$CONTROL_DIR/claude.json.tmp"
        fi
        $RUNTIME rm -f "$CONTAINER_NAME" >/dev/null || exit 1
    fi
    if [ "$NET_EXISTS" = true ]; then $RUNTIME rm -f "$NETWORK_CONTAINER_NAME" >/dev/null || exit 1; fi
fi

chmod 700 "$SSH_CONFIG_DIR" || exit 1

# Host settings are data files; no user-provided shell text is evaluated.
cat <<'HOST_LAUNCHER' > "$CONTROL_DIR/enter.sh"
#!/bin/sh
set -eu
container=$1
shift
requested=vpn
initialize=false
case "$#:${1:-}:${2:-}" in
    0::) ;;
    1:--no-vpn:|1:--direct:) requested=direct ;;
    1:--initialize-only:) initialize=true ;;
    *) echo "Usage: $container [--no-vpn|--direct]"; exit 2 ;;
esac
control=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
read_setting() { IFS= read -r value < "$control/$1"; printf '%s\n' "$value"; }
[ "$(read_setting name)" = "$container" ] || { echo '[!] Container name does not match its settings.'; exit 1; }
network=$container-net
case "$(read_setting runtime)" in
    podman)
        runtime() { podman --cgroup-manager=cgroupfs "$@"; }
        network_mode=private
        ;;
    docker)
        runtime() { docker "$@"; }
        network_mode=bridge
        ;;
    *) echo '[!] Invalid saved container runtime.'; exit 1 ;;
esac
# Serialize changes, but release the lock before opening an interactive shell.
if ! mkdir "$control/lock" 2>/dev/null; then
    echo "[!] Another operation is in progress. If interrupted, remove the stale directory: $control/lock"
    exit 1
fi
trap 'rmdir "$control/lock" 2>/dev/null || :' 0
trap 'exit 130' INT
trap 'exit 143' TERM
exists() { runtime container inspect "$1" >/dev/null 2>&1; }
field() { runtime container inspect -f "$2" "$1"; }
label() { field "$1" "{{index .Config.Labels \"dev-container.$2\"}}"; }
is_running() { [ "$(field "$1" '{{.State.Running}}')" = true ]; }
validate_role() {
    if [ "$(label "$1" schema)" != pair-v1 ] || [ "$(label "$1" pair)" != "$container" ] || [ "$(label "$1" role)" != "$2" ]; then
        echo "[!] Container '$1' is not a matching managed pair. Run dev-container.sh to migrate it."
        exit 1
    fi
}
validate_mounts() {
    workspace=$(read_setting workspace)
    if [ "$(CDPATH='' cd -- "$workspace" && pwd -P)" != "$workspace" ]; then
        echo '[!] The workspace path changed; rerun dev-container.sh.'
        return 1
    fi
    for key in workspace config claude codex ssh local; do
        source=$(read_setting "$key")
        source=$(CDPATH='' cd -- "$source" && pwd -P) || return 1
        source=${source%/}
        case "$source/" in
            "$workspace/"*) ;;
            *) echo "[!] Writable configuration mounts escaped the workspace: $source"; return 1 ;;
        esac
        case "$control/" in
            "$source/"*) echo "[!] Writable mount overlaps host controls: $source"; return 1 ;;
        esac
        case "$source/" in
            "$control/"*) echo "[!] Writable mount overlaps host controls: $source"; return 1 ;;
        esac
    done
}
network_ready() {
    is_running "$network" &&
        [ "$(runtime exec "$network" /usr/local/bin/cc-net-health 2>/dev/null)" = "$(label "$network" mode) $(label "$network" token)" ]
}
start_container() {
    for attempt in 1 2 3; do
        if runtime start "$1" >/dev/null; then return 0; fi
        [ "$attempt" -eq 3 ] || sleep 1
    done
    echo "[!] Failed to start container: $1"
    return 1
}
create_network() {
    config_volume=$(read_setting config-volume)
    if [ "$(runtime volume inspect -f '{{index .Labels "dev-container.pair"}}' "$config_volume" 2>/dev/null)" != "$container" ]; then
        echo '[!] VPN configuration volume is missing or unrelated; rerun dev-container.sh.'
        return 1
    fi
    token=$(date +%s)-$$
    set -- run -d --name "$network" --hostname "$(read_setting hostname)-net" \
        --network="$network_mode" --user root --read-only \
        --cap-drop=ALL --cap-add=NET_ADMIN --security-opt=no-new-privileges \
        --tmpfs /run:rw,nosuid,nodev,mode=755 --tmpfs /tmp:rw,nosuid,nodev,mode=1777 \
        --tmpfs /var/tmp:rw,nosuid,nodev,mode=1777 \
        --sysctl=net.ipv4.conf.all.src_valid_mark=1 \
        --label=dev-container.schema=pair-v1 --label="dev-container.pair=$container" \
        --label=dev-container.role=network --label="dev-container.mode=$requested" \
        --label="dev-container.token=$token" \
        -e "CC_NETWORK_MODE=$requested" -e "CC_NETWORK_TOKEN=$token" \
        -e "CC_BROWSER_PORT=$(read_setting browser-port)" \
        -e "CC_PORT_RANGE=$(read_setting port-range)" \
        -e "CC_LAN_SUBNETS=$(read_setting lan-subnets)" \
        -p "0.0.0.0:$(read_setting browser-port):$(read_setting browser-port)/tcp" \
        -v "$config_volume:/etc/wireguard:ro,z" \
        -v "$control/resolv.conf:/etc/resolv.conf:rw,z"
    ports=$(read_setting port-range)
    if [ -n "$ports" ]; then set -- "$@" -p "$ports:$ports/tcp"; fi
    # Port helpers in older Podman can outlive a stopped network container briefly.
    created=false
    for attempt in 1 2 3; do
        if runtime "$@" "$(read_setting network-image)" >/dev/null; then created=true; break; fi
        if exists "$network"; then
            validate_role "$network" network
            runtime rm -f "$network" >/dev/null || return 1
        fi
        [ "$attempt" -eq 3 ] || sleep 1
    done
    if [ "$created" != true ]; then echo '[!] Failed to create the network container.'; return 1; fi
    attempt=0
    while [ "$attempt" -lt 60 ]; do
        if ! is_running "$network"; then
            echo '[!] Network initialization failed; the development container was not started.'
            runtime logs --tail 10 "$network"
            return 1
        fi
        if network_ready; then return 0; fi
        attempt=$((attempt + 1))
        sleep 1
    done
    echo '[!] Network initialization timed out; stopping the network container.'
    runtime stop -t 2 "$network" >/dev/null 2>&1 || :
    return 1
}
create_development() {
    validate_mounts || return 1
    net_id=$(field "$network" '{{.Id}}')
    net_started=$(field "$network" '{{.State.StartedAt}}')
    runtime run -d --name "$container" \
        --network="container:$net_id" --user root \
        --cap-drop=NET_ADMIN --cap-drop=NET_RAW --cap-drop=SYS_ADMIN --cap-drop=SYS_PTRACE \
        --security-opt=no-new-privileges --shm-size=4g \
        --label=dev-container.schema=pair-v1 --label="dev-container.pair=$container" \
        --label=dev-container.role=development --label="dev-container.network-id=$net_id" \
        --label="dev-container.network-started=$net_started" \
        -e IS_SANDBOX=1 -e CLAUDE_CONFIG_DIR=/root/.claude -e CODEX_HOME=/root/.codex \
        -e "CC_BROWSER_PORT=$(read_setting browser-port)" -e "CC_HOST_LAN_IP=$(read_setting host-lan-ip)" \
        -v "$control/resolv.conf:/etc/resolv.conf:ro,z" \
        -v "$control/claude.json:/root/.claude.json:rw,z" \
        -v "$(read_setting workspace):/workspace:z" \
        -v "$(read_setting config):/root/.config:z" \
        -v "$(read_setting claude):/root/.claude:z" \
        -v "$(read_setting codex):/root/.codex:z" \
        -v "$(read_setting ssh):/root/.ssh:z" \
        -v "$(read_setting local):/root/.local:z" \
        "$(read_setting image)" >/dev/null
    # Never enter a workload that joined a different or failed network session.
    if ! network_ready || [ "$(field "$network" '{{.State.StartedAt}}')" != "$net_started" ]; then
        runtime stop -t 2 "$container" >/dev/null 2>&1 || :
        echo '[!] Network changed during development container startup.'
        return 1
    fi
}
dev_exists=false
net_exists=false
if exists "$container"; then dev_exists=true; validate_role "$container" development; fi
if exists "$network"; then net_exists=true; validate_role "$network" network; fi
usable=false
if [ "$net_exists" = true ] && [ "$(label "$network" mode)" = "$requested" ] && network_ready; then
    if [ "$dev_exists" = false ]; then
        usable=true
    elif [ "$(label "$container" network-id)" = "$(field "$network" '{{.Id}}')" ] && \
            [ "$(label "$container" network-started)" = "$(field "$network" '{{.State.StartedAt}}')" ]; then
        usable=true
    fi
fi
if [ "$usable" != true ]; then
    if [ "$dev_exists" = true ] || [ "$net_exists" = true ]; then
        printf "Pair '%s' needs recreation for %s or network recovery. Files outside mounted folders will be lost. Recreate both containers? [y/N]: " "$container" "$requested"
        answer=
        read -r answer || :
        case "$answer" in
            y|Y|yes|YES|Yes) ;;
            *) exit 0 ;;
        esac
    fi
    # Remove the workload first so it cannot remain on an orphaned namespace.
    if [ "$dev_exists" = true ]; then runtime rm -f "$container" >/dev/null; fi
    if [ "$net_exists" = true ]; then runtime rm -f "$network" >/dev/null; fi
    create_network
    dev_exists=false
fi
if [ "$dev_exists" != true ]; then
    create_development
elif ! is_running "$container"; then
    start_container "$container"
fi
# Pin the workload ID so a concurrent recreation cannot redirect this session.
dev_id=$(field "$container" '{{.Id}}')
rmdir "$control/lock"
trap - 0 INT TERM
if [ "$initialize" != true ]; then
    runtime exec -it "$dev_id" /bin/bash -i
fi
HOST_LAUNCHER
if ! (
    set -e
    umask 077
    save_setting() { printf '%s\n' "$2" > "$CONTROL_DIR/$1"; }
    save_setting config-volume "$CONFIG_VOLUME"
    save_setting runtime "$RUNTIME_NAME"
    save_setting name "$CONTAINER_NAME"
    save_setting image "$IMG_ID"
    save_setting network-image "$NETWORK_IMG_ID"
    save_setting workspace "$WORKSPACE_FOLDER"
    save_setting config "$CONFIG_ROOT"
    save_setting claude "$CLAUDE_CONFIG_DIR"
    save_setting codex "$CODEX_HOME_DIR"
    save_setting ssh "$SSH_CONFIG_DIR"
    save_setting local "$LOCAL_DIR"
    save_setting hostname "$CONTAINER_HOSTNAME"
    save_setting browser-port "$BROWSER_PORT"
    if [ "$PORT_RANGE" = 0 ]; then save_setting port-range ''; else save_setting port-range "$PORT_RANGE"; fi
    save_setting lan-subnets "$LAN_SUBNETS"
    save_setting host-lan-ip "$HOST_LAN_IP"
    save_setting resolv.conf 'nameserver 1.1.1.1'
    if [ ! -f "$CONTROL_DIR/claude.json" ]; then save_setting claude.json '{}'; fi
    for setting in enter.sh runtime name image network-image workspace config claude codex ssh local hostname browser-port port-range lan-subnets host-lan-ip config-volume claude.json; do
        chmod 600 "$CONTROL_DIR/$setting"
    done
    chmod 644 "$CONTROL_DIR/resolv.conf"
); then
    echo "[!] Failed to install pair settings."
    exit 1
fi

# Import secrets into a runtime-managed volume, never into an image or workload.
if $RUNTIME volume inspect "$CONFIG_VOLUME" >/dev/null 2>&1; then
    if [ "$($RUNTIME volume inspect -f '{{index .Labels "dev-container.pair"}}' "$CONFIG_VOLUME")" != "$CONTAINER_NAME" ] || \
            [ "$($RUNTIME volume inspect -f '{{index .Labels "dev-container.role"}}' "$CONFIG_VOLUME")" != config ]; then
        echo "[!] Refusing to overwrite an unrelated configuration volume: $CONFIG_VOLUME"
        exit 1
    fi
else
    $RUNTIME volume create --label "dev-container.pair=$CONTAINER_NAME" --label dev-container.role=config "$CONFIG_VOLUME" >/dev/null || exit 1
fi
INIT_CONTAINER="$NETWORK_CONTAINER_NAME-init"
if $RUNTIME container inspect "$INIT_CONTAINER" >/dev/null 2>&1; then
    if [ "$($RUNTIME container inspect -f '{{index .Config.Labels "dev-container.pair"}}' "$INIT_CONTAINER")" != "$CONTAINER_NAME" ] || \
            [ "$($RUNTIME container inspect -f '{{index .Config.Labels "dev-container.role"}}' "$INIT_CONTAINER")" != config-init ]; then
        echo "[!] Import container name is already in use: $INIT_CONTAINER"
        exit 1
    fi
    $RUNTIME rm -f "$INIT_CONTAINER" >/dev/null || exit 1
fi
WG_IMPORT=$(mktemp) || exit 1
if ! cp -L "$WG_CONFIG" "$WG_IMPORT" || ! chmod 600 "$WG_IMPORT"; then
    echo "[!] Failed to prepare WireGuard configuration for import."
    exit 1
fi
if ! $RUNTIME create --name "$INIT_CONTAINER" --network=none --read-only --user root \
        --cap-drop=ALL --cap-add=CHOWN --security-opt=no-new-privileges \
        --label "dev-container.pair=$CONTAINER_NAME" --label dev-container.role=config-init \
        -v "$CONFIG_VOLUME:/config:rw,z" --entrypoint /bin/sh "$NETWORK_IMG_ID" \
        -c 'chown 0:0 /config/wg0.conf && chmod 600 /config/wg0.conf' >/dev/null; then
    echo "[!] Failed to create the configuration import container."
    exit 1
fi
IMPORT_CONTAINER="$INIT_CONTAINER"
if ! $RUNTIME cp "$WG_IMPORT" "$INIT_CONTAINER:/config/wg0.conf" || ! $RUNTIME start -a "$INIT_CONTAINER" </dev/null >/dev/null; then
    echo "[!] Failed to import WireGuard configuration."
    exit 1
fi
$RUNTIME rm "$INIT_CONTAINER" >/dev/null || exit 1
IMPORT_CONTAINER=
rm -f "$WG_IMPORT"
WG_IMPORT=
# Remove only the obsolete managed copy left by the single-container version.
if [ -f "$CONTROL_DIR/wg0.conf" ]; then rm -f "$CONTROL_DIR/wg0.conf"; fi

# --- 6. Host Shell Launcher ---
FUNC_NAME="dc$CONTAINER_SUFFIX"
START_SIG="# <DEV-CONTAINER-MANAGED-START:$FUNC_NAME>"
END_SIG="# <DEV-CONTAINER-MANAGED-END:$FUNC_NAME>"

printf "Update '%s' function in shell config? [Y/n]: " "$FUNC_NAME"
read -r CONFIRM_SHELL
CONFIRM_SHELL=${CONFIRM_SHELL:-y}

if [ "$CONFIRM_SHELL" = "y" ] || [ "$CONFIRM_SHELL" = "Y" ]; then
    CONTROL_DIR_QUOTED=$(printf "%s" "$CONTROL_DIR" | sed "s/'/'\\\\''/g")
    FUNC_BODY="$START_SIG
function $FUNC_NAME() {
    /bin/sh '$CONTROL_DIR_QUOTED/enter.sh' '$CONTAINER_NAME' \"\$@\"
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
                    printf '%s\n' "$FUNC_BODY" >> "$RC_FILE"
                    echo "[>] Updated '$FUNC_NAME' in $RC_FILE"
                else
                    echo "[!] Warning: Custom '$FUNC_NAME' exists. Skipping automated update."
                fi
            else
                printf '%s\n' "$FUNC_BODY" >> "$RC_FILE"
                echo "[>] Added '$FUNC_NAME' to $RC_FILE"
            fi
        fi
    done
fi

# --- 7. Start the Pair ---
rmdir "$INSTALL_LOCK" || exit 1
INSTALL_LOCK=
/bin/sh "$CONTROL_DIR/enter.sh" "$CONTAINER_NAME"
exit $?
