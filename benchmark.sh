#!/bin/sh

# --- Container Engine Detection ---
CONTAINER_RUNTIME=""

if command -v podman >/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
elif command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
else
    echo "Error: Podman or Docker not found."
    printf "Please enter your container engine (e.g., docker, podman, k3s): "
    read -r MANUAL_RUNTIME
    if command -v "$MANUAL_RUNTIME" >/dev/null 2>&1; then
        CONTAINER_RUNTIME="$MANUAL_RUNTIME"
    else
        echo "Error: '$MANUAL_RUNTIME' not found. Exiting."
        exit 1
    fi
fi

echo "Using runtime: $CONTAINER_RUNTIME"

# --- Execute Benchmark ---
# Fixed the image version to alpine:3.19 for consistency
$CONTAINER_RUNTIME run --rm -it alpine:3.19 sh -c "
    echo '--- Preparing environment (Installing sysbench & speedtest-go) ---'
    apk add --no-cache sysbench curl > /dev/null 2>&1

    # Detect architecture for speedtest-go
    ARCH=\$(uname -m)
    if [ \"\$ARCH\" = \"x86_64\" ]; then
        BINARY_ARCH=\"x86_64\";
    else
        BINARY_ARCH=\"arm64\";
    fi

    curl -sL \"https://github.com/showwin/speedtest-go/releases/download/v1.7.0/speedtest-go_1.7.0_Linux_\${BINARY_ARCH}.tar.gz\" | tar -xz -C /usr/bin/

    echo -e '\n[1/4] CPU Performance Test'
    sysbench cpu --threads=\$(nproc) run | grep 'events per second'

    echo -e '\n[2/4] Memory Bandwidth Test'
    sysbench memory --threads=\$(nproc) run | grep 'MiB/sec'

    echo -e '\n[3/4] Disk IO Performance Test'
    sysbench fileio --file-test-mode=rndrw prepare > /dev/null
    sysbench fileio --file-test-mode=rndrw --threads=\$(nproc) run | grep 'MiB/s'
    sysbench fileio --file-test-mode=rndrw cleanup > /dev/null

    echo -e '\n[4/4] Network Speed Test'
    speedtest-go --thread 4
"
