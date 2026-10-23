#!/bin/sh
# ==============================================================================
# Description: Development container with a host-orchestrated WireGuard tunnel.
# Features: Claude Code, Codex, OpenCode, persistent config, VPN, and browser desktop.
# The container owns the network namespace (pasta or slirp4netns) but never has
# NET_ADMIN. A short-lived helper container joins that namespace, configures
# wg0, and exits. Published ports are handled by the selected network backend.
# ==============================================================================

# --- 0. Version ---
CLAUDE_VERSION="2.1.296"
CODEX_VERSION="0.162.1"
OC_VERSION="1.18.21"

# --- 1. Container Runtime ---
if command -v podman >/dev/null 2>&1; then
    RUNTIME_NAME=podman
    RUNTIME="podman --cgroup-manager=cgroupfs"
else
    echo "[!] This design requires rootless Podman with pasta or slirp4netns."
    exit 1
fi
echo "[>] Runtime: $RUNTIME_NAME (pasta/slirp4netns + ephemeral VPN helper)"

ensure_runtime_env() {
    _uid=$(id -u)
    if [ "$_uid" -eq 0 ]; then
        echo '[!] Run this script as your normal user, not root/sudo.'
        exit 1
    fi
    _runtime_dir=${XDG_RUNTIME_DIR:-}
    if [ -n "$_runtime_dir" ] && [ -d "$_runtime_dir" ] &&
            [ "$(stat -c %u "$_runtime_dir" 2>/dev/null || :)" = "$_uid" ]; then
        export XDG_RUNTIME_DIR=$_runtime_dir
        return 0
    fi
    _preferred="/run/user/$_uid"
    if [ -d "$_preferred" ] && [ "$(stat -c %u "$_preferred" 2>/dev/null || :)" = "$_uid" ]; then
        export XDG_RUNTIME_DIR=$_preferred
        if [ -n "$_runtime_dir" ]; then
            echo "[>] Ignoring unusable XDG_RUNTIME_DIR=$_runtime_dir; using $_preferred"
        fi
        return 0
    fi
    _fallback="/tmp/dc-runtime-$_uid"
    if ! mkdir -p "$_fallback" 2>/dev/null || ! chmod 700 "$_fallback" 2>/dev/null; then
        echo "[!] Cannot create a private runtime directory at $_fallback."
        exit 1
    fi
    export XDG_RUNTIME_DIR=$_fallback
    if [ -n "$_runtime_dir" ]; then
        echo "[>] Ignoring unusable XDG_RUNTIME_DIR=$_runtime_dir; using $_fallback"
    fi
}
ensure_runtime_env
if ! _rootless=$($RUNTIME info --format '{{.Host.Security.Rootless}}' 2>/dev/null); then
    echo '[!] Cannot query Podman. Check that rootless Podman is working.'
    exit 1
fi
[ "$_rootless" = true ] || {
    echo '[!] This design requires rootless Podman. Run as a normal user, not root/sudo.'
    exit 1
}

normalize_dns_servers() {
    _nds_in=$(printf '%s' "$1" | tr -d '[:space:]')
    _nds_out=
    for _nds_ns in $(printf '%s' "$_nds_in" | tr ',' ' '); do
        case "$_nds_ns" in
            ""|*[!0-9.]*|*..*|.*|*.) continue ;;
        esac
        _nds_out="${_nds_out:+$_nds_out,}$_nds_ns"
    done
    [ -n "$_nds_out" ] || _nds_out=1.1.1.1
    printf '%s' "$_nds_out"
}

write_control_scripts() {
    umask 077
    mkdir -p "$HOME/.dc" "$CONTROL_DIR" || return 1
    chmod 700 "$HOME/.dc" "$CONTROL_DIR" 2>/dev/null || true
    if [ ! -f "$CONTROL_DIR/container-image" ] && [ -f "$CONTROL_DIR/workload-image" ]; then
        mv "$CONTROL_DIR/workload-image" "$CONTROL_DIR/container-image" || return 1
    fi
    rm -f "$CONTROL_DIR/workload-image" || true
cat <<'DC_CREATE' > "$CREATE_PATH"
#!/bin/sh
set -eu

ensure_runtime_env() {
    _uid=$(id -u)
    if [ "$_uid" -eq 0 ]; then
        echo '[!] Run this script as your normal user, not root/sudo.'
        exit 1
    fi
    _runtime_dir=${XDG_RUNTIME_DIR:-}
    if [ -n "$_runtime_dir" ] && [ -d "$_runtime_dir" ] &&
            [ "$(stat -c %u "$_runtime_dir" 2>/dev/null || :)" = "$_uid" ]; then
        export XDG_RUNTIME_DIR=$_runtime_dir
        return 0
    fi
    _preferred="/run/user/$_uid"
    if [ -d "$_preferred" ] && [ "$(stat -c %u "$_preferred" 2>/dev/null || :)" = "$_uid" ]; then
        export XDG_RUNTIME_DIR=$_preferred
        if [ -n "$_runtime_dir" ]; then
            echo "[>] Ignoring unusable XDG_RUNTIME_DIR=$_runtime_dir; using $_preferred"
        fi
        return 0
    fi
    _fallback="/tmp/dc-runtime-$_uid"
    if ! mkdir -p "$_fallback" 2>/dev/null || ! chmod 700 "$_fallback" 2>/dev/null; then
        echo "[!] Cannot create a private runtime directory at $_fallback."
        exit 1
    fi
    export XDG_RUNTIME_DIR=$_fallback
    if [ -n "$_runtime_dir" ]; then
        echo "[>] Ignoring unusable XDG_RUNTIME_DIR=$_runtime_dir; using $_fallback"
    fi
}
ensure_runtime_env
CONTROL_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SETTINGS=$CONTROL_DIR/settings
[ -f "$SETTINGS" ] || { echo "[!] Missing settings: $SETTINGS"; exit 1; }
CONTAINER=
WORKSPACE=
BROWSER_PORT=
PORT_RANGE=
NETWORK_MODE=
DNS_SERVER=
DNS_SERVERS=
DIRECT_DNS=
LAN_SUBNETS=
HOST_LAN_IP=
WG_SECRET=
HOSTNAME=
while IFS='=' read -r key value; do
    case "$key" in
        container) CONTAINER=$value ;;
        workspace) WORKSPACE=$value ;;
        browser_port) BROWSER_PORT=$value ;;
        port_range) PORT_RANGE=$value ;;
        network_mode) NETWORK_MODE=$value ;;
        dns_server) DNS_SERVER=$value ;;
        dns_servers) DNS_SERVERS=$value ;;
        direct_dns) DIRECT_DNS=$value ;;
        lan_subnets) LAN_SUBNETS=$value ;;
        host_lan_ip) HOST_LAN_IP=$value ;;
        wg_secret) WG_SECRET=$value ;;
        hostname) HOSTNAME=$value ;;
        ''|'#'*) ;;
    esac
done < "$SETTINGS"
[ -n "$CONTAINER" ] || { echo '[!] Missing container in settings.'; exit 1; }
[ -n "$WORKSPACE" ] || { echo '[!] Missing workspace in settings.'; exit 1; }
[ -n "$BROWSER_PORT" ] || { echo '[!] Missing browser_port in settings.'; exit 1; }
[ -n "$WG_SECRET" ] || { echo '[!] Missing wg_secret in settings.'; exit 1; }
[ -n "$HOSTNAME" ] || HOSTNAME="$(hostname)-$CONTAINER"
DNS_SERVER=${DNS_SERVER:-1.1.1.1}
DNS_SERVERS=${DNS_SERVERS:-$DNS_SERVER}
DIRECT_DNS=${DIRECT_DNS:-1.1.1.1}
[ -n "$NETWORK_MODE" ] || NETWORK_MODE=pasta
[ -f "$CONTROL_DIR/claude.json" ] || { echo '[!] Missing claude.json in control directory.'; exit 1; }
if [ -f "$CONTROL_DIR/container-image" ]; then
    CONTAINER_IMAGE=$(cat "$CONTROL_DIR/container-image")
elif [ -f "$CONTROL_DIR/workload-image" ]; then
    CONTAINER_IMAGE=$(cat "$CONTROL_DIR/workload-image")
else
    echo '[!] Missing container-image pin.'; exit 1
fi
[ -n "$CONTAINER_IMAGE" ] || { echo '[!] Empty container-image pin.'; exit 1; }
VPN_IMAGE=
[ -f "$CONTROL_DIR/vpn-image" ] && VPN_IMAGE=$(cat "$CONTROL_DIR/vpn-image")
runtime() { podman --cgroup-manager=cgroupfs "$@"; }
if ! runtime image inspect "$CONTAINER_IMAGE" >/dev/null 2>&1; then
    echo "[!] Container image $CONTAINER_IMAGE not found; re-run dc.sh."
    exit 1
fi
if runtime container inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "[!] Container '$CONTAINER' already exists."
    exit 1
fi
set -- run -d --name "$CONTAINER" --hostname "$HOSTNAME" \
    --network="$NETWORK_MODE" --user root --init \
    --cap-drop=NET_ADMIN --cap-drop=NET_RAW --cap-drop=SYS_ADMIN --cap-drop=SYS_PTRACE \
    --security-opt=no-new-privileges --shm-size=4g \
    --tmpfs /run/secrets:rw,nosuid,nodev,mode=755 \
    --sysctl=net.ipv4.conf.all.src_valid_mark=1 \
    --sysctl=net.ipv6.conf.all.disable_ipv6=1 \
    --sysctl=net.ipv6.conf.default.disable_ipv6=1 \
    --label=dc.schema=v1 --label="dc.name=$CONTAINER" \
    --label=dc.role=container --label="dc.network=$NETWORK_MODE" \
    --label="dc.browser-port=$BROWSER_PORT" \
    --label="dc.port-range=$PORT_RANGE" \
    --label="dc.dns-server=$DNS_SERVER" \
    --label="dc.dns-servers=$DNS_SERVERS" \
    --label="dc.direct-dns=$DIRECT_DNS" \
    --label="dc.lan-subnets=$LAN_SUBNETS" \
    --label="dc.host-lan-ip=$HOST_LAN_IP" \
    --label="dc.wg-secret=$WG_SECRET" \
    --label="dc.vpn-image=$VPN_IMAGE" \
    -e IS_SANDBOX=1 -e CLAUDE_CONFIG_DIR=/root/.claude -e CODEX_HOME=/root/.codex \
    -e XDG_CONFIG_HOME=/root/.config \
    -e "DC_BROWSER_PORT=$BROWSER_PORT" -e "DC_HOST_LAN_IP=$HOST_LAN_IP" \
    -e "DC_DNS_SERVER=$DNS_SERVER" -e "DC_DNS_SERVERS=$DNS_SERVERS" \
    -p "0.0.0.0:$BROWSER_PORT:$BROWSER_PORT/tcp"
if [ -n "$PORT_RANGE" ]; then set -- "$@" -p "$PORT_RANGE:$PORT_RANGE/tcp"; fi
set -- "$@" -v "$WORKSPACE:/workspace:z" -v "$CONTROL_DIR/claude.json:/root/.claude.json:rw,z" "$CONTAINER_IMAGE"
for attempt in 1 2 3 4 5; do
    if runtime "$@" >/dev/null 2>&1; then exit 0; fi
    if runtime container inspect "$CONTAINER" >/dev/null 2>&1; then
        runtime rm -f "$CONTAINER" >/dev/null 2>&1 || true
    fi
    [ "$attempt" -eq 5 ] || sleep 2
done
echo '[!] Failed to create the container.'
exit 1
DC_CREATE
chmod 700 "$CREATE_PATH" || exit 1
cat <<'DC_ENTER' > "$LAUNCHER_PATH"
#!/bin/sh
set -eu

ensure_runtime_env() {
    _uid=$(id -u)
    if [ "$_uid" -eq 0 ]; then
        echo '[!] Run this script as your normal user, not root/sudo.'
        exit 1
    fi
    _runtime_dir=${XDG_RUNTIME_DIR:-}
    if [ -n "$_runtime_dir" ] && [ -d "$_runtime_dir" ] &&
            [ "$(stat -c %u "$_runtime_dir" 2>/dev/null || :)" = "$_uid" ]; then
        export XDG_RUNTIME_DIR=$_runtime_dir
        return 0
    fi
    _preferred="/run/user/$_uid"
    if [ -d "$_preferred" ] && [ "$(stat -c %u "$_preferred" 2>/dev/null || :)" = "$_uid" ]; then
        export XDG_RUNTIME_DIR=$_preferred
        if [ -n "$_runtime_dir" ]; then
            echo "[>] Ignoring unusable XDG_RUNTIME_DIR=$_runtime_dir; using $_preferred"
        fi
        return 0
    fi
    _fallback="/tmp/dc-runtime-$_uid"
    if ! mkdir -p "$_fallback" 2>/dev/null || ! chmod 700 "$_fallback" 2>/dev/null; then
        echo "[!] Cannot create a private runtime directory at $_fallback."
        exit 1
    fi
    export XDG_RUNTIME_DIR=$_fallback
    if [ -n "$_runtime_dir" ]; then
        echo "[>] Ignoring unusable XDG_RUNTIME_DIR=$_runtime_dir; using $_fallback"
    fi
}
ensure_runtime_env
CONTROL_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SETTINGS=$CONTROL_DIR/settings
[ -f "$SETTINGS" ] || { echo "[!] Missing settings: $SETTINGS"; exit 1; }
CONTAINER=
WORKSPACE=
BROWSER_PORT=
PORT_RANGE=
NETWORK_MODE=
DNS_SERVER=
DNS_SERVERS=
DIRECT_DNS=
LAN_SUBNETS=
HOST_LAN_IP=
WG_SECRET=
WG_CONFIG=
HOSTNAME=
normalize_dns_servers() {
    _nds_in=$(printf '%s' "$1" | tr -d '[:space:]')
    _nds_out=
    for _nds_ns in $(printf '%s' "$_nds_in" | tr ',' ' '); do
        case "$_nds_ns" in
            ""|*[!0-9.]*|*..*|.*|*.) continue ;;
        esac
        _nds_out="${_nds_out:+$_nds_out,}$_nds_ns"
    done
    [ -n "$_nds_out" ] || _nds_out=1.1.1.1
    printf '%s' "$_nds_out"
}
load_settings() {
    while IFS='=' read -r key value; do
        case "$key" in
            container) CONTAINER=$value ;;
            workspace) WORKSPACE=$value ;;
            browser_port) BROWSER_PORT=$value ;;
            port_range) PORT_RANGE=$value ;;
            network_mode) NETWORK_MODE=$value ;;
            dns_server) DNS_SERVER=$value ;;
            dns_servers) DNS_SERVERS=$value ;;
            direct_dns) DIRECT_DNS=$value ;;
            lan_subnets) LAN_SUBNETS=$value ;;
            host_lan_ip) HOST_LAN_IP=$value ;;
            wg_secret) WG_SECRET=$value ;;
            wg_config) WG_CONFIG=$value ;;
            hostname) HOSTNAME=$value ;;
            ''|'#'*) ;;
        esac
    done < "$SETTINGS"
}
load_settings
[ -n "$CONTAINER" ] || { echo '[!] Missing container in settings.'; exit 1; }
if [ -z "$DNS_SERVERS" ] && [ -n "$WG_CONFIG" ] && [ -f "$WG_CONFIG" ]; then
    DNS_SERVERS=$(awk -F= '/^[[:space:]]*DNS[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$WG_CONFIG")
fi
DNS_SERVERS=$(normalize_dns_servers "${DNS_SERVERS:-$DNS_SERVER}")
DNS_SERVER=${DNS_SERVERS%%,*}
DIRECT_DNS=${DIRECT_DNS:-1.1.1.1}
VPN_IMAGE=
[ -f "$CONTROL_DIR/vpn-image" ] && VPN_IMAGE=$(cat "$CONTROL_DIR/vpn-image")
runtime() { podman --cgroup-manager=cgroupfs "$@"; }
requested=vpn
initialize=false
case "${DC_INITIALIZE:-}" in 1|true|TRUE|yes|YES|Yes) initialize=true ;; esac
status=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-vpn|--direct) requested=direct ;;
        --status) status=true ;;
        *) echo "Usage: $0 [--direct|--no-vpn|--status]" >&2; exit 2 ;;
    esac
    shift
done
if [ "$status" = true ]; then
    if ! runtime container inspect "$CONTAINER" >/dev/null 2>&1; then
        printf 'container: %s\nstate: missing\n' "$CONTAINER"
        exit 0
    fi
    state=$(runtime container inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || :)
    printf 'container: %s\nstate: %s\n' "$CONTAINER" "$state"
    [ "$state" = running ] || exit 0
    mode=direct
    if runtime exec "$CONTAINER" ip link show wg0 >/dev/null 2>&1; then mode=vpn; fi
    wg_ip=$(runtime exec "$CONTAINER" sh -c "ip -4 -o addr show dev wg0 2>/dev/null | awk 'NR==1{print \$4}'" 2>/dev/null || :)
    dns=$(runtime exec "$CONTAINER" sh -c "awk '/^[[:space:]]*nameserver[[:space:]]/{printf \"%s%s\", (n++ ? \",\" : \"\"), \$2}' /etc/resolv.conf" 2>/dev/null || :)
    route=$(runtime exec "$CONTAINER" sh -c "ip -4 route get 1.1.1.1 2>/dev/null | head -n 1" 2>/dev/null || :)
    exit_ip=
    for attempt in 1 2 3; do
        exit_ip=$(runtime exec "$CONTAINER" sh -c 'curl -4 -sS --max-time 5 https://ifconfig.me 2>/dev/null' 2>/dev/null || :)
        [ -n "$exit_ip" ] && break
        [ "$attempt" -eq 3 ] || sleep 1
    done
    ports=$BROWSER_PORT
    [ -n "$PORT_RANGE" ] && ports="$ports, $PORT_RANGE"
    printf 'network: %s\n' "${NETWORK_MODE:-unknown}"
    printf 'mode: %s\n' "$mode"
    printf 'wg0: %s\n' "${wg_ip:--}"
    printf 'dns: %s\n' "${dns:--}"
    printf 'route: %s\n' "${route:--}"
    printf 'exit: %s\n' "${exit_ip:-unavailable}"
    printf 'ports: %s\n' "$ports"
    exit 0
fi
lock_dir=$CONTROL_DIR/lock
if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "[!] Another operation is in progress. If interrupted, remove: $lock_dir"
    exit 1
fi
trap 'rmdir "$lock_dir" 2>/dev/null || :' 0
trap 'exit 130' INT
trap 'exit 143' TERM
field() { runtime container inspect -f "$2" "$1"; }
RUNNING=false
STARTED=false
DEV_ID=
load_container_state() {
    _meta=$(field "$CONTAINER" '{{index .Config.Labels "dc.schema"}}|{{index .Config.Labels "dc.name"}}|{{index .Config.Labels "dc.role"}}|{{.State.Running}}|{{.Id}}' 2>/dev/null || :)
    [ -n "$_meta" ] || return 1
    _oldifs=$IFS; IFS='|'; set -- $_meta; IFS=$_oldifs
    _role_ok=false
    case "$3" in workload|container) _role_ok=true ;; esac
    if [ "$1" != v1 ] || [ "$2" != "$CONTAINER" ] || [ "$_role_ok" != true ]; then
        echo "[!] Container '$CONTAINER' is not a matching managed container. Re-run dc.sh."
        exit 1
    fi
    RUNNING=$4
    DEV_ID=$5
}
start_container() {
    for attempt in 1 2 3 4 5; do
        if runtime start "$1" >/dev/null 2>&1; then RUNNING=true; STARTED=true; return 0; fi
        [ "$attempt" -eq 5 ] || sleep 1
    done
    echo "[!] Failed to start container: $1"
    return 1
}
set_dns() {
    _dns_list=$(printf '%s' "$1" | tr -d '[:space:]')
    _dns_valid=
    for _dns_ns in $(printf '%s' "$_dns_list" | tr ',' ' '); do
        case "$_dns_ns" in
            ""|*[!0-9.]*|*..*|.*|*.) echo "[!] Invalid DNS server: $_dns_ns"; return 1 ;;
        esac
        _dns_valid="${_dns_valid:+$_dns_valid,}$_dns_ns"
    done
    [ -n "$_dns_valid" ] || { echo '[!] Empty DNS server list.'; return 1; }
    for _dns_ns in $(printf '%s' "$_dns_valid" | tr ',' ' '); do
        printf 'nameserver %s\n' "$_dns_ns"
    done | runtime exec -i "$CONTAINER" sh -c 'cat > /etc/resolv.conf'
}
run_helper() {
    action=$1
    [ -n "$VPN_IMAGE" ] || { echo '[!] Missing vpn-image pin; re-run dc.sh.'; return 1; }
    if ! runtime image inspect "$VPN_IMAGE" >/dev/null 2>&1; then
        echo "[!] VPN helper image $VPN_IMAGE not found; re-run dc.sh."
        return 1
    fi
    runtime run --rm --name "$CONTAINER-vpn-$$" \
        --network="container:$CONTAINER" --user root --read-only \
        --cap-drop=ALL --cap-add=NET_ADMIN --security-opt=no-new-privileges \
        --tmpfs /run:rw,nosuid,nodev,mode=755 --tmpfs /tmp:rw,nosuid,nodev,mode=1777 \
        --tmpfs /var/tmp:rw,nosuid,nodev,mode=1777 \
        --tmpfs /run/secrets:rw,nosuid,nodev,mode=755 \
        -e "DC_LAN_SUBNETS=$LAN_SUBNETS" \
        -e "DC_WG_CONFIG=/run/dc/wg0" \
        --secret "$WG_SECRET,target=/run/dc/wg0" \
        "$VPN_IMAGE" "$action"
}
egress_ready() {
    _attempts=${1:-6}
    _attempt=1
    while [ "$_attempt" -le "$_attempts" ]; do
        if runtime exec "$CONTAINER" timeout 6 sh -c 'getent hosts example.com >/dev/null 2>&1 && curl -4 -sS --max-time 5 -o /dev/null https://example.com' >/dev/null 2>&1; then
            return 0
        fi
        [ "$_attempt" -eq "$_attempts" ] || sleep 1
        _attempt=$((_attempt + 1))
    done
    return 1
}
if ! load_container_state; then
    echo "[>] Creating container '$CONTAINER' from $CONTROL_DIR."
    "$CONTROL_DIR/create.sh" || exit 1
    load_container_state || exit 1
    STARTED=true
    WAS_RUNNING=false
else
    WAS_RUNNING=$RUNNING
fi
if [ "$RUNNING" != true ]; then
    start_container "$CONTAINER" || exit 1
fi
probe_container() {
    _probe=$(runtime exec "$CONTAINER" sh -c '
        i=0
        while [ ! -f /run/dc/entrypoint-ready ] && [ "$i" -lt 20 ]; do
            sleep 0.1
            i=$((i + 1))
        done
        [ -f /run/dc/entrypoint-ready ] || exit 1
        if ip link show wg0 >/dev/null 2>&1; then
            if ip link show up dev wg0 >/dev/null 2>&1; then echo vpn-up; else echo vpn-down; fi
        else
            echo direct
        fi
        awk "/^[[:space:]]*nameserver[[:space:]]/{printf \"%s%s\", (n++ ? \",\" : \"\"), \$2}" /etc/resolv.conf
    ' 2>/dev/null || :)
    [ -n "$_probe" ] || { echo '[!] Container entrypoint did not become ready.'; exit 1; }
    current_mode=$(printf '%s\n' "$_probe" | sed -n '1p')
    current_dns=$(printf '%s\n' "$_probe" | sed -n '2p')
    wg0_down=false
    case "$current_mode" in
        vpn-up) current_mode=vpn ;;
        vpn-down) current_mode=vpn; wg0_down=true ;;
    esac
}
compute_mode_changed() {
    mode_changed=false
    [ "$current_mode" = "$requested" ] || mode_changed=true
    if [ "$requested" = vpn ] && [ "$wg0_down" = true ]; then mode_changed=true; fi
}
probe_container
compute_mode_changed
restart_needed=false
if [ "$mode_changed" = true ] && [ "$WAS_RUNNING" = true ] && [ "$initialize" != true ]; then
    if [ -t 0 ]; then
        printf '[>] Current mode: %s; requested: %s.\n' "$current_mode" "$requested"
        printf 'Restart container to switch mode? [y/N]: '
        read -r _answer || _answer=
        case "$_answer" in
            y|Y|yes|YES|Yes) restart_needed=true ;;
            *) echo '[>] No changes; not entering.'; exit 0 ;;
        esac
    else
        echo '[>] Mode switch requires confirmation; not entering.'
        echo '[>] Run dc interactively to confirm.'
        exit 0
    fi
fi
if [ "$restart_needed" = true ]; then
    echo "[>] Restarting container '$CONTAINER'."
    runtime stop -t 2 "$CONTAINER" >/dev/null 2>&1 || true
    start_container "$CONTAINER" || exit 1
    probe_container
    compute_mode_changed
fi
if [ "$requested" = vpn ]; then
    desired_dns=$DNS_SERVERS
else
    desired_dns=$DIRECT_DNS
fi
if [ "$mode_changed" = true ]; then
    if [ "$requested" = vpn ]; then
        if [ ! -d /sys/module/wireguard ] && ! grep -q '^wireguard ' /proc/modules 2>/dev/null; then
            echo '[!] The WireGuard kernel module is not loaded on the host.'
            echo '[!] Load it on the host before using VPN mode.'
            exit 1
        fi
        run_helper up || { echo '[!] Failed to enable VPN mode.'; exit 1; }
    else
        run_helper down || { echo '[!] Failed to enable direct mode.'; exit 1; }
    fi
fi
if [ "$current_dns" != "$desired_dns" ]; then
    set_dns "$desired_dns" || exit 1
fi
if [ "$mode_changed" = true ]; then
    if ! egress_ready 3; then
        echo '[!] Container egress check failed.'
        runtime exec "$CONTAINER" ip -4 addr show 2>/dev/null || :
        runtime exec "$CONTAINER" ip -4 route show 2>/dev/null || :
        exit 1
    fi
else
    if [ "$initialize" = true ] || [ "$STARTED" = true ]; then
        if ! egress_ready 1; then
            echo '[>] Network check failed; re-applying the current mode.'
            if [ "$requested" = vpn ]; then
                run_helper up || { echo '[!] Failed to re-apply VPN mode.'; exit 1; }
            else
                run_helper down || { echo '[!] Failed to re-apply direct mode.'; exit 1; }
            fi
            set_dns "$desired_dns" || exit 1
            if ! egress_ready 3; then
                echo '[!] Container egress check failed.'
                runtime exec "$CONTAINER" ip -4 addr show 2>/dev/null || :
                runtime exec "$CONTAINER" ip -4 route show 2>/dev/null || :
                exit 1
            fi
        fi
    fi
fi

rmdir "$lock_dir"
trap - 0 INT TERM
if [ "$initialize" != true ]; then
    if [ -t 0 ]; then
        runtime exec -it "$DEV_ID" /bin/bash -i
    else
        echo "[>] Initialized container '$CONTAINER' (no TTY; not entering)."
    fi
fi
DC_ENTER
chmod 700 "$LAUNCHER_PATH" || exit 1
}

# --- 2. Container Naming & Hostname ---
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
LEGACY_GATEWAY_NAME="$CONTAINER_NAME-gw"
WG_SECRET="$CONTAINER_NAME-vpn"
CONTAINER_HOSTNAME="$(hostname)-$CONTAINER_NAME"
CONTROL_DIR="$HOME/.dc/$CONTAINER_NAME"
SETTINGS_PATH="$CONTROL_DIR/settings"
CREATE_PATH="$CONTROL_DIR/create.sh"
LAUNCHER_PATH="$CONTROL_DIR/enter.sh"
write_control_scripts || exit 1

# Reuse the previous control settings or the existing container's labels as
# defaults. The control directory is outside the workspace and is host-owned.
OLD_BROWSER_PORT=
OLD_PORT_RANGE=
OLD_PORT_RANGE_SET=false
OLD_WORKSPACE=
OLD_DIRECT_DNS=
OLD_LAN_SUBNETS=
OLD_LAN_SET=false
OLD_HOST_LAN_IP=
OLD_WG_SECRET=
OLD_WG_CONFIG=
if [ -f "$SETTINGS_PATH" ]; then
    while IFS='=' read -r _key _value; do
        case "$_key" in
            browser_port) OLD_BROWSER_PORT=$_value ;;
            port_range) OLD_PORT_RANGE=$_value; OLD_PORT_RANGE_SET=true ;;
            workspace) OLD_WORKSPACE=$_value ;;
            direct_dns) OLD_DIRECT_DNS=$_value ;;
            lan_subnets) OLD_LAN_SUBNETS=$_value; OLD_LAN_SET=true ;;
            host_lan_ip) OLD_HOST_LAN_IP=$_value ;;
            wg_secret) OLD_WG_SECRET=$_value ;;
            wg_config) OLD_WG_CONFIG=$_value ;;
            ''|'#'*) ;;
        esac
    done < "$SETTINGS_PATH"
fi
if $RUNTIME container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    _label() { $RUNTIME container inspect -f "{{index .Config.Labels \"dc.$1\"}}" "$CONTAINER_NAME" 2>/dev/null || :; }
    _clean() { case "$1" in ''|'<no value>') : ;; *) printf '%s' "$1" ;; esac; }
    if [ -z "$OLD_BROWSER_PORT" ]; then OLD_BROWSER_PORT=$(_clean "$(_label browser-port)"); fi
    if [ "$OLD_PORT_RANGE_SET" != true ]; then
        _value=$(_label port-range)
        case "$_value" in '<no value>') ;; *) OLD_PORT_RANGE=$_value; OLD_PORT_RANGE_SET=true ;; esac
    fi
    if [ -z "$OLD_WORKSPACE" ]; then
        OLD_WORKSPACE=$($RUNTIME container inspect -f '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || :)
    fi
    if [ -z "$OLD_DIRECT_DNS" ]; then OLD_DIRECT_DNS=$(_clean "$(_label direct-dns)"); fi
    if [ "$OLD_LAN_SET" != true ]; then
        _value=$(_label lan-subnets)
        case "$_value" in '<no value>') ;; *) OLD_LAN_SUBNETS=$_value; OLD_LAN_SET=true ;; esac
    fi
    if [ -z "$OLD_HOST_LAN_IP" ]; then OLD_HOST_LAN_IP=$(_clean "$(_label host-lan-ip)"); fi
    if [ -z "$OLD_WG_SECRET" ]; then OLD_WG_SECRET=$(_clean "$(_label wg-secret)"); fi
fi

DEFAULT_BROWSER_PORT=${OLD_BROWSER_PORT:-9988}
if [ "$OLD_PORT_RANGE_SET" = true ]; then
    DEFAULT_PORT_RANGE=$OLD_PORT_RANGE
else
    DEFAULT_PORT_RANGE=9000-9100
fi
DEFAULT_WORKSPACE=${OLD_WORKSPACE:-$HOME/Projects}
DEFAULT_WG_CONFIG=${OLD_WG_CONFIG:-}
DEFAULT_DIRECT_DNS=${OLD_DIRECT_DNS:-1.1.1.1}
DEFAULT_WG_SECRET=${OLD_WG_SECRET:-$WG_SECRET}
WG_SECRET=$DEFAULT_WG_SECRET

if [ -n "$DEFAULT_WG_CONFIG" ]; then
    printf "WireGuard configuration file path [%s]: " "$DEFAULT_WG_CONFIG"
else
    printf "WireGuard configuration file path: "
fi
read -r WG_CONFIG
WG_CONFIG=${WG_CONFIG:-$DEFAULT_WG_CONFIG}
case "$WG_CONFIG" in
    "~"|"~/"*) WG_CONFIG="$HOME${WG_CONFIG#\~}" ;;
esac

if [ ! -f "$WG_CONFIG" ]; then
    echo "[!] Error: WireGuard configuration file not found: $WG_CONFIG"
    exit 1
fi

WG_CONFIG_DIR=$(dirname "$WG_CONFIG")
WG_CONFIG="$(cd "$WG_CONFIG_DIR" && pwd)/$(basename "$WG_CONFIG")"

# All DNS servers from the WireGuard config, used by the container in VPN mode.
DNS_SERVERS=$(awk -F= '/^[[:space:]]*DNS[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$WG_CONFIG")
DNS_SERVERS=$(normalize_dns_servers "$DNS_SERVERS")
DNS_SERVER=${DNS_SERVERS%%,*}

DIRECT_DNS=${DEFAULT_DIRECT_DNS:-1.1.1.1}


# --- 3. Port Range Configuration ---
# Accepts START-END with 1 <= START <= END <= 65535
is_valid_port() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
    esac
    [ "${#1}" -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

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

printf "Host port range to expose [%s] (0 = none): " "${DEFAULT_PORT_RANGE:-0}"
read -r PORT_RANGE
PORT_RANGE=${PORT_RANGE:-${DEFAULT_PORT_RANGE:-0}}
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

# --- 4. Direct LAN Access (bypassing the VPN) ---
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

if [ -n "${OLD_HOST_LAN_IP:-}" ]; then
    HOST_LAN_IP=$OLD_HOST_LAN_IP
else
    HOST_LAN_IP=$(detect_host_lan_ip)
fi
if [ "${OLD_LAN_SET:-false}" = true ]; then
    DEFAULT_LAN_SUBNETS=$OLD_LAN_SUBNETS
    [ -n "$DEFAULT_LAN_SUBNETS" ] || DEFAULT_LAN_SUBNETS=0
else
    DEFAULT_LAN_SUBNETS=$(normalize_private_cidr "$(detect_lan_subnet)" 2>/dev/null) || DEFAULT_LAN_SUBNETS="0"
fi
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

# --- 5. Development and Network Images ---
LOCAL_TAG="localhost/dc:container-v1"
VPN_TAG="localhost/dc:vpn-v1"
BUILD_NONCE="$CLAUDE_VERSION-$CODEX_VERSION-$OC_VERSION"

TMP_BUILD=$(mktemp -d)
if [ $? -ne 0 ]; then
    echo "[!] Error: Failed to create temporary build directory."
    exit 1
fi
cleanup_build() {
    rm -rf "$TMP_BUILD"
}
trap cleanup_build 0
trap 'exit 1' HUP INT TERM

echo "[>] Building development image (Claude Code @$CLAUDE_VERSION, Codex @$CODEX_VERSION, OpenCode @$OC_VERSION)"

cat <<'BROWSER_SCRIPT' > "$TMP_BUILD/bb"
#!/bin/bash
set -euo pipefail

STATE_DIR=/run/dc/browser
PID_FILE=$STATE_DIR/supervisor.pid
LOG_FILE=$STATE_DIR/supervisor.log
PROFILE_DIR=/tmp/dc-browser
PASSWORD_FILE=$STATE_DIR/vnc-password
VNC_PASSWORD_FILE=$STATE_DIR/vnc.pass
PORT=${DC_BROWSER_PORT:-9988}

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
        pgrep -u browser -x x11vnc >/dev/null 2>&1 &&
        pgrep -u browser -x chromium >/dev/null 2>&1
}

show_access() {
    _path="/vnc.html?autoconnect=1&resize=scale&password=$(cat "$PASSWORD_FILE")"
    if [ -n "${DC_HOST_LAN_IP:-}" ]; then
        echo "[>] LAN URL: http://$DC_HOST_LAN_IP:$PORT$_path"
    else
        echo "[!] Host LAN IPv4 was not detected; use a LAN address assigned to the host."
    fi
    echo "[>] Local URL: http://localhost:$PORT$_path"
}

start_browser() {
    mkdir -p "$STATE_DIR" "$PROFILE_DIR" /home/browser/.cache/fontconfig /home/browser/.config
    chown browser:browser "$STATE_DIR" "$PROFILE_DIR" /home/browser/.cache /home/browser/.cache/fontconfig /home/browser/.config
    if desktop_is_healthy; then
        show_access
        return 0
    fi
    if is_running || pgrep -u browser >/dev/null 2>&1; then
        stop_browser
    fi
    rm -f "$PID_FILE"
    PASSWORD=$(openssl rand -base64 6 | tr '+/' '-_')
    printf '%s\n' "$PASSWORD" > "$PASSWORD_FILE"
    x11vnc -storepasswd "$PASSWORD" "$VNC_PASSWORD_FILE" >/dev/null 2>&1
    chown browser:browser "$PASSWORD_FILE" "$VNC_PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE" "$VNC_PASSWORD_FILE"
    : > "$LOG_FILE"
    chown browser:browser "$LOG_FILE"
    setpriv --reuid=browser --regid=browser --init-groups \
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
    if pgrep -u browser >/dev/null 2>&1; then
        pkill -TERM -u browser 2>/dev/null || true
        sleep 1
        pkill -KILL -u browser 2>/dev/null || true
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
        pkill -TERM -u browser -x chromium 2>/dev/null || true
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

    export HOME=/home/browser
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

cat <<'CONTAINER_ENTRY' > "$TMP_BUILD/dc-container"
#!/bin/bash
set -euo pipefail

# DNS is rewritten by the host launcher after the VPN helper runs. This default
# only makes the container usable if it is inspected before the launcher runs.
if [ -n "${DC_DNS_SERVERS:-}" ]; then
    : > /etc/resolv.conf
    for _dns_ns in ${DC_DNS_SERVERS//,/ }; do
        printf 'nameserver %s\n' "$_dns_ns" >> /etc/resolv.conf
    done
else
    printf 'nameserver %s\n' "${DC_DNS_SERVER:-1.1.1.1}" > /etc/resolv.conf
fi

mkdir -p /workspace/.config /workspace/.config/claude /workspace/.config/codex \
    /workspace/.config/opencode /workspace/.config/ssh /workspace/.local /run/dc
chmod 700 /workspace/.config/ssh 2>/dev/null || true

link() {
    target=$1
    source=$2
    if [ -L "$target" ]; then
        rm -f "$target"
    elif [ -e "$target" ]; then
        rm -rf "$target"
    fi
    ln -s "$source" "$target"
}

# Agent state lives under the workspace, except /root/.claude.json which is
# bind-mounted from the host control directory.
link /root/.config /workspace/.config
link /root/.claude /workspace/.config/claude
link /root/.codex /workspace/.config/codex
link /root/.ssh /workspace/.config/ssh
link /root/.local /workspace/.local

touch /run/dc/entrypoint-ready
exec /bin/sleep infinity
CONTAINER_ENTRY
chmod 755 "$TMP_BUILD/dc-container"

TMP_DF="$TMP_BUILD/Dockerfile"

cat <<EOF > "$TMP_DF"
FROM node:22-bookworm-slim
LABEL dc.schema="v1" dc.role="container" \\
      dc.claude-version="$CLAUDE_VERSION" dc.codex-version="$CODEX_VERSION" dc.opencode-version="$OC_VERSION"
# NET_RAW/NET_ADMIN are dropped at runtime, so binaries carrying those file capabilities
# cannot be executed. Hiding setcap makes package scripts fall back to plain binaries.
RUN dpkg-divert --local --rename --divert /sbin/setcap.real --add /sbin/setcap && \\
    apt-get update && apt-get install -y --no-install-recommends \\
    bash bubblewrap ca-certificates chromium curl fzf git iproute2 iputils-ping novnc openbox procps ripgrep util-linux websockify x11vnc xvfb && \\
    rm -rf /var/lib/apt/lists/*
# Keep WebRTC on Chromium's default route without exposing local interface addresses.
RUN mkdir -p /etc/chromium/policies/managed && \\
    printf '%s\\n' '{"WebRtcIPHandling":"default_public_interface_only"}' \\
    > /etc/chromium/policies/managed/webrtc.json && \\
    chmod 644 /etc/chromium/policies/managed/webrtc.json
ARG BUILD_NONCE
RUN echo "\$BUILD_NONCE" >/dev/null && npm install -g \\
    @anthropic-ai/claude-code@$CLAUDE_VERSION \\
    @openai/codex@$CODEX_VERSION \\
    opencode-ai@$OC_VERSION && \\
    npm cache clean --force
RUN useradd --system --create-home --home-dir /home/browser --shell /usr/sbin/nologin browser
COPY bb /usr/local/bin/bb
COPY dc-container /usr/local/bin/dc-container
RUN chmod 755 /usr/local/bin/bb /usr/local/bin/dc-container
RUN echo 'alias claude="claude --dangerously-skip-permissions"' >> /root/.bashrc && \\
    echo 'alias codex="codex --dangerously-bypass-approvals-and-sandbox"' >> /root/.bashrc && \\
    echo 'alias oc="opencode"' >> /root/.bashrc
ENV COLORTERM=truecolor
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/dc-container"]
EOF

$RUNTIME build --build-arg "BUILD_NONCE=$BUILD_NONCE" -t "$LOCAL_TAG" -f "$TMP_DF" "$TMP_BUILD"
BUILD_STATUS=$?
if [ "$BUILD_STATUS" -ne 0 ]; then
    echo "[!] Error: Container image build failed."
    exit 1
fi

IMG_ID=$($RUNTIME images --no-trunc -q "$LOCAL_TAG" 2>/dev/null)

if [ -z "$IMG_ID" ]; then
    echo "[!] Error: Image ID could not be resolved."
    exit 1
fi

# Prefer pasta; fall back to slirp4netns when the runtime does not support it.
NETWORK_MODE=pasta
if ! $RUNTIME run --rm --network=pasta --entrypoint /bin/true "$IMG_ID" >/dev/null 2>&1; then
    if $RUNTIME run --rm --network=slirp4netns --entrypoint /bin/true "$IMG_ID" >/dev/null 2>&1; then
        NETWORK_MODE=slirp4netns
        echo '[>] pasta is unavailable; using slirp4netns.'
    else
        echo '[!] Neither pasta nor slirp4netns is available in this Podman.'
        exit 1
    fi
fi
echo "[>] Network mode: $NETWORK_MODE"

# The VPN helper has no development tools and no workspace mounts. It joins the
# container's network namespace, configures wg0, and exits.
cat <<'VPN_ENTRY' > "$TMP_BUILD/dc-vpn"
#!/bin/bash
# dc-vpn-up-v1
set -euo pipefail
DC_LAN_SUBNETS=${DC_LAN_SUBNETS:-}
WG_CONFIG=${DC_WG_CONFIG:-/run/dc/wg0}
action=${1:?Usage: dc-vpn up|down|status}

wan_gw=
wan_dev=
for word in $(ip -4 route show default); do
    case "$word" in
        via) wan_gw_next=1 ;;
        dev) wan_dev_next=1 ;;
        *)
            if [ "${wan_gw_next:-0}" = 1 ]; then wan_gw=$word; wan_gw_next=0; fi
            if [ "${wan_dev_next:-0}" = 1 ]; then wan_dev=$word; wan_dev_next=0; fi
            ;;
    esac
done

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
    done
    for destination in 'fe80::/10' 'ff02::/16'; do
        for kind in neighbor-solicitation neighbor-advertisement; do
            ip6tables -w -A OUTPUT -p ipv6-icmp --icmpv6-type "$kind" -d "$destination" -j ACCEPT
        done
    done
    for cidr in ${DC_LAN_SUBNETS//,/ }; do
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
            "$tool" -w -A OUTPUT -m mark --mark 0xdc01 -p udp -d "$host" --dport "$port" -j ACCEPT
            found=1
        fi
    done < "$WG_CONFIG"
    [ "$found" -eq 1 ]
}

route_lan() {
    [ -n "$DC_LAN_SUBNETS" ] || return 0
    [ -n "$wan_gw" ] && [ -n "$wan_dev" ] || return 0
    local cidr
    for cidr in ${DC_LAN_SUBNETS//,/ }; do
        if [ -z "$(ip -4 route show table main exact "$cidr")" ]; then
            ip route add "$cidr" via "$wan_gw" dev "$wan_dev"
        fi
    done
}

remove_lan_routes() {
    [ -n "$DC_LAN_SUBNETS" ] || return 0
    [ -n "$wan_gw" ] && [ -n "$wan_dev" ] || return 0
    local cidr
    for cidr in ${DC_LAN_SUBNETS//,/ }; do
        ip route del "$cidr" via "$wan_gw" dev "$wan_dev" 2>/dev/null || true
    done
}

write_config() {
    mkdir -p /run/dc/wireguard
    chmod 700 /run/dc/wireguard
    sed -e '/^[[:space:]]*FwMark[[:space:]]*=/Id' \
        -e '/^\[Interface\]$/a FwMark = 0xdc01' \
        -e '/^\[Interface\]$/a MTU = 1420' \
        "$WG_CONFIG" > /run/dc/wireguard/wg0.conf
    chmod 600 /run/dc/wireguard/wg0.conf
    if grep -Eq '^[[:space:]]*(PreUp|PostUp|PreDown|PostDown|SaveConfig)[[:space:]]*=' "$WG_CONFIG"; then
        echo '[!] WireGuard hooks and SaveConfig are not supported.'
        return 1
    fi
}

setup_vpn() {
    lock_egress
    write_config
    if ! PATH=/usr/local/lib/dc:$PATH wg-quick up /run/dc/wireguard/wg0.conf > /run/dc/wireguard/start.log 2>&1; then
        echo '[!] WireGuard initialization failed; check the host configuration.'
        cat /run/dc/wireguard/start.log >&2 || true
        return 1
    fi
    route_lan
    lock_egress
}

teardown_vpn() {
    if ip link show wg0 >/dev/null 2>&1; then
        write_config || true
        PATH=/usr/local/lib/dc:$PATH wg-quick down /run/dc/wireguard/wg0.conf >/dev/null 2>&1 || \
            ip link del wg0 2>/dev/null || true
    fi
    ip rule del table 51820 2>/dev/null || true
    ip -4 route flush table 51820 2>/dev/null || true
    ip link del wg0 2>/dev/null || true
    if ip link show wg0 >/dev/null 2>&1; then
        echo '[!] Failed to remove the WireGuard interface.'
        return 1
    fi
    remove_lan_routes
    for tool in iptables ip6tables; do
        "$tool" -w -P OUTPUT ACCEPT 2>/dev/null || true
        "$tool" -w -P FORWARD ACCEPT 2>/dev/null || true
        "$tool" -w -F OUTPUT 2>/dev/null || true
        "$tool" -w -F FORWARD 2>/dev/null || true
    done
}

case "$action" in
    up)
        if ip link show wg0 >/dev/null 2>&1; then
            teardown_vpn || exit 1
        fi
        setup_vpn
        ;;
    down)
        teardown_vpn
        ;;
    status)
        if ip link show wg0 >/dev/null 2>&1; then echo vpn; else echo direct; fi
        ;;
    *)
        echo "Usage: dc-vpn up|down|status" >&2
        exit 2
        ;;
esac
VPN_ENTRY
chmod 755 "$TMP_BUILD/dc-vpn"

cat <<'VPN_RESOLVCONF' > "$TMP_BUILD/dc-resolvconf"
#!/bin/sh
# The helper has its own mount namespace; wg-quick must not rewrite DNS there.
exit 0
VPN_RESOLVCONF
chmod 755 "$TMP_BUILD/dc-resolvconf"

cat <<EOF > "$TMP_BUILD/Vpnfile"
FROM debian:bookworm-slim
LABEL dc.schema="v1" dc.role="vpn"
RUN apt-get update && apt-get install -y --no-install-recommends \\
    bash iproute2 iptables nftables util-linux wireguard-tools procps && \\
    rm -rf /var/lib/apt/lists/*
# wg-quick always writes src_valid_mark for full-tunnel configs, but /proc/sys is
# read-only in containers. The container's netns already has the value; accept it.
RUN mkdir -p /usr/local/lib/dc && printf '%s\\n' '#!/bin/bash' \\
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
    > /usr/local/lib/dc/sysctl && chmod +x /usr/local/lib/dc/sysctl
COPY dc-vpn /usr/local/bin/dc-vpn
COPY dc-resolvconf /usr/local/lib/dc/resolvconf
RUN chmod 755 /usr/local/bin/dc-vpn /usr/local/lib/dc/resolvconf
ENTRYPOINT ["/usr/local/bin/dc-vpn"]
EOF
if ! $RUNTIME build -t "$VPN_TAG" -f "$TMP_BUILD/Vpnfile" "$TMP_BUILD"; then
    echo "[!] VPN helper image build failed."
    exit 1
fi
VPN_IMG_ID=$($RUNTIME images --no-trunc -q "$VPN_TAG" 2>/dev/null)
if [ -z "$VPN_IMG_ID" ]; then
    echo "[!] VPN helper image ID could not be resolved."
    exit 1
fi

# --- 6. Workspace & Agent Configuration ---
echo "[>] Configuring Development Container"

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
CLAUDE_JSON_FILE="$CONFIG_ROOT/claude.json"
SETTINGS_FILE="$CLAUDE_CONFIG_DIR/settings.json"

if ! mkdir -p "$CONFIG_ROOT" "$CLAUDE_CONFIG_DIR" "$CODEX_HOME_DIR" "$SSH_CONFIG_DIR" "$OPENCODE_CONFIG_DIR" "$LOCAL_DIR" 2>/dev/null; then
    echo "[!] Error: Failed to create agent configuration directories. Check permissions."
    exit 1
fi
if [ ! -f "$CONTROL_DIR/claude.json" ]; then
    if [ ! -f "$CLAUDE_JSON_FILE" ]; then
        printf '{}\n' > "$CLAUDE_JSON_FILE" || exit 1
    fi
    chmod 600 "$CLAUDE_JSON_FILE" || exit 1
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


# --- 7. Existing Container ---
CONTAINER_EXISTS=false
LEGACY_GW_EXISTS=false
if $RUNTIME container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then CONTAINER_EXISTS=true; fi
# The previous paired-container design used a persistent <name>-gw gateway.
# Remove it if it is still present when recreating.
if $RUNTIME container inspect "$LEGACY_GATEWAY_NAME" >/dev/null 2>&1; then
    LEGACY_GW_EXISTS=true
    if [ "$($RUNTIME container inspect -f '{{index .Config.Labels "dc.name"}}' "$LEGACY_GATEWAY_NAME")" != "$CONTAINER_NAME" ] || \
            [ "$($RUNTIME container inspect -f '{{index .Config.Labels "dc.role"}}' "$LEGACY_GATEWAY_NAME")" != gateway ]; then
        echo "[!] Legacy gateway name is already used by an unrelated container: $LEGACY_GATEWAY_NAME"
        exit 1
    fi
fi
if [ "$CONTAINER_EXISTS" = true ]; then
    _existing_name=$($RUNTIME container inspect -f '{{index .Config.Labels "dc.name"}}' "$CONTAINER_NAME")
    _existing_role=$($RUNTIME container inspect -f '{{index .Config.Labels "dc.role"}}' "$CONTAINER_NAME")
    if [ "$_existing_name" != "$CONTAINER_NAME" ] || { [ "$_existing_role" != workload ] && [ "$_existing_role" != container ]; }; then
        echo "[!] Container name is already used by an unrelated container: $CONTAINER_NAME"
        exit 1
    fi
fi
if [ "$CONTAINER_EXISTS" = true ] || [ "$LEGACY_GW_EXISTS" = true ]; then
    if [ "$CONTAINER_EXISTS" = true ] && [ "$LEGACY_GW_EXISTS" = true ]; then
        printf "Container '%s' exists; files outside mounted folders will be lost. Recreate it and remove legacy gateway '%s'? [y/N]: " "$CONTAINER_NAME" "$LEGACY_GATEWAY_NAME"
    elif [ "$CONTAINER_EXISTS" = true ]; then
        printf "Container '%s' exists; files outside mounted folders will be lost. Recreate it? [y/N]: " "$CONTAINER_NAME"
    else
        printf "Legacy gateway '%s' exists; remove it? [y/N]: " "$LEGACY_GATEWAY_NAME"
    fi
    CONFIRM_RECREATE=
    read -r CONFIRM_RECREATE || :
    case "$CONFIRM_RECREATE" in
        y|Y|yes|YES|Yes) ;;
        *) echo "[>] Keeping the existing container; control scripts refreshed."; exit 0 ;;
    esac
    if [ "$CONTAINER_EXISTS" = true ]; then $RUNTIME rm -f "$CONTAINER_NAME" >/dev/null || exit 1; fi
    if [ "$LEGACY_GW_EXISTS" = true ]; then $RUNTIME rm -f "$LEGACY_GATEWAY_NAME" >/dev/null || exit 1; fi
fi

chmod 700 "$SSH_CONFIG_DIR" || exit 1

# --- 8. Trusted control directory ---
# The container can write the workspace, so host-executed scripts and settings
# must live outside it. All files here are owned by the host user.
umask 077
mkdir -p "$HOME/.dc" "$CONTROL_DIR" || exit 1
chmod 700 "$HOME/.dc" "$CONTROL_DIR" 2>/dev/null || true
PORT_RANGE_LABEL=$PORT_RANGE
[ "$PORT_RANGE" = 0 ] && PORT_RANGE_LABEL=

if [ ! -f "$CONTROL_DIR/claude.json" ]; then
    if [ -f "$CLAUDE_JSON_FILE" ]; then
        cp "$CLAUDE_JSON_FILE" "$CONTROL_DIR/claude.json" || exit 1
    else
        printf '{}\n' > "$CONTROL_DIR/claude.json" || exit 1
    fi
fi
chmod 600 "$CONTROL_DIR/claude.json" || exit 1

settings_tmp="$CONTROL_DIR/settings.tmp"
{
    printf 'container=%s\n' "$CONTAINER_NAME"
    printf 'workspace=%s\n' "$WORKSPACE_FOLDER"
    printf 'browser_port=%s\n' "$BROWSER_PORT"
    printf 'port_range=%s\n' "$PORT_RANGE_LABEL"
    printf 'network_mode=%s\n' "$NETWORK_MODE"
    printf 'dns_server=%s\n' "$DNS_SERVER"
    printf 'dns_servers=%s\n' "$DNS_SERVERS"
    printf 'direct_dns=%s\n' "$DIRECT_DNS"
    printf 'lan_subnets=%s\n' "$LAN_SUBNETS"
    printf 'host_lan_ip=%s\n' "$HOST_LAN_IP"
    printf 'wg_secret=%s\n' "$WG_SECRET"
    printf 'wg_config=%s\n' "$WG_CONFIG"
    printf 'hostname=%s\n' "$CONTAINER_HOSTNAME"
} > "$settings_tmp" || exit 1
chmod 600 "$settings_tmp" || exit 1
mv "$settings_tmp" "$SETTINGS_PATH" || exit 1

printf '%s\n' "$VPN_IMG_ID" > "$CONTROL_DIR/vpn-image" || exit 1
printf '%s\n' "$IMG_ID" > "$CONTROL_DIR/container-image" || exit 1
chmod 600 "$CONTROL_DIR/vpn-image" "$CONTROL_DIR/container-image" || exit 1


# Store the WireGuard configuration in a Podman secret, not a host-path volume.
# Older Podman versions do not support "secret create --replace".
if $RUNTIME secret inspect "$WG_SECRET" >/dev/null 2>&1; then
    if ! $RUNTIME secret rm "$WG_SECRET" >/dev/null; then
        echo "[!] Failed to remove the existing WireGuard secret '$WG_SECRET'."
        echo '[!] Stop any container using it, then rerun dc.sh.'
        exit 1
    fi
fi
if ! $RUNTIME secret create "$WG_SECRET" "$WG_CONFIG" >/dev/null; then
    echo '[!] Failed to create the WireGuard secret.'
    exit 1
fi

# Create the container from the trusted control directory. The same script is
# used by enter.sh if the container is removed later.
"$CREATE_PATH" || exit 1
# The workspace copy is obsolete once the control copy is in use. Remove only
# empty/default state so a real file is never discarded silently.
if [ -f "$CLAUDE_JSON_FILE" ]; then
    case "$(cat "$CLAUDE_JSON_FILE" 2>/dev/null)" in
        ''|'{}') rm -f "$CLAUDE_JSON_FILE" || true ;;
    esac
fi

# --- 9. Host Shell Launcher ---
FUNC_NAME="dc$CONTAINER_SUFFIX"
START_SIG="# <DEV-CONTAINER-MANAGED-START:$FUNC_NAME>"
END_SIG="# <DEV-CONTAINER-MANAGED-END:$FUNC_NAME>"

printf "Update '%s' function in shell config? [Y/n]: " "$FUNC_NAME"
read -r CONFIRM_SHELL
CONFIRM_SHELL=${CONFIRM_SHELL:-y}

if [ "$CONFIRM_SHELL" = "y" ] || [ "$CONFIRM_SHELL" = "Y" ]; then
    LAUNCHER_QUOTED=$(printf "%s" "$LAUNCHER_PATH" | sed "s/'/'\\\\''/g")
    FUNC_BODY="$START_SIG
function $FUNC_NAME() {
    '$LAUNCHER_QUOTED' \"\$@\"
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

# --- 10. Start the Container ---
if [ -t 0 ]; then
    "$LAUNCHER_PATH"
    status=$?
else
    DC_INITIALIZE=1 "$LAUNCHER_PATH"
    status=$?
    [ "$status" -eq 0 ] && echo "[>] Run '$FUNC_NAME' to enter."
fi
exit "$status"
