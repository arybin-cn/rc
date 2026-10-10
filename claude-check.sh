#!/bin/bash
# Claude API Health Check Script
# Usage: claude-check [endpoint]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SETTINGS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

# Read a string value from settings.json, falling back to the environment variable of the same name
get_setting() {
    local value=""
    if [ -f "$SETTINGS_FILE" ]; then
        value=$(grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$SETTINGS_FILE" 2>/dev/null |
            head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)"$/\1/')
    fi
    printf '%s' "${value:-${!1}}"
}

ENDPOINT="${1:-$(get_setting ANTHROPIC_BASE_URL)}"
ENDPOINT="${ENDPOINT%/}"
AUTH_TOKEN=$(get_setting ANTHROPIC_AUTH_TOKEN)
API_KEY=$(get_setting ANTHROPIC_API_KEY)

# Strip suffixes such as [1m] and resolve aliases, which the API itself does not accept
MODEL=$(get_setting ANTHROPIC_MODEL)
MODEL="${MODEL%%\[*}"
case "$MODEL" in
    ""|default|sonnet) MODEL=$(get_setting ANTHROPIC_DEFAULT_SONNET_MODEL); MODEL="${MODEL:-claude-sonnet-5-5}" ;;
    opus) MODEL=$(get_setting ANTHROPIC_DEFAULT_OPUS_MODEL); MODEL="${MODEL:-claude-opus-5-5}" ;;
    haiku) MODEL=$(get_setting ANTHROPIC_DEFAULT_HAIKU_MODEL); MODEL="${MODEL:-claude-haiku-5-5}" ;;
esac
MODEL="${MODEL%%\[*}"

if [ -z "$ENDPOINT" ]; then
    echo -e "${RED}Error: No endpoint found. Usage: claude-check <url>${NC}"
    exit 1
fi

# Extract host from URL, dropping scheme, userinfo, path and port
HOST=$(echo "$ENDPOINT" | sed -E 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||; s|[/?#].*||; s|^.*@||')
case "$HOST" in
    \[*\]*) HOST="${HOST#\[}"; HOST="${HOST%%\]*}" ;;
    *:*) HOST="${HOST%:*}" ;;
esac

echo "=========================================="
echo "  Claude API Health Check"
echo "=========================================="
echo "Endpoint: $ENDPOINT"
echo "Model: $MODEL"
echo ""

# 1. DNS Check
echo -n "[1/3] DNS Resolution... "
IP=$(getent hosts "$HOST" 2>/dev/null | awk '{print $1}' | head -1)
if [ -n "$IP" ]; then
    echo -e "${GREEN}OK${NC} ($IP)"
else
    echo -e "${RED}FAILED${NC} - Cannot resolve host $HOST"
    exit 1
fi

# 2. HTTPS Connection
echo -n "[2/3] HTTPS Connection... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 15 "$ENDPOINT" 2>/dev/null || true)
case "$HTTP_CODE" in
    ""|000)
        echo -e "${RED}FAILED${NC} - Connection failed or timed out"
        exit 1
        ;;
    5*) echo -e "${YELLOW}WARN${NC} (HTTP $HTTP_CODE)" ;;
    *) echo -e "${GREEN}OK${NC} (HTTP $HTTP_CODE - endpoint reachable)" ;;
esac

# 3. API Call Test
echo -n "[3/3] API Call Test... "
if [ -z "$AUTH_TOKEN" ] && [ -z "$API_KEY" ]; then
    echo -e "${YELLOW}SKIP${NC} (no API key found)"
else
    # Mirror Claude Code: AUTH_TOKEN goes in Authorization, API_KEY in x-api-key.
    # Headers are passed through stdin so the key does not show up in the process list.
    AUTH_CONFIG=""
    if [ -n "$AUTH_TOKEN" ]; then
        AUTH_CONFIG+="header = \"Authorization: Bearer $AUTH_TOKEN\""$'\n'
    fi
    if [ -n "$API_KEY" ]; then
        AUTH_CONFIG+="header = \"x-api-key: $API_KEY\""$'\n'
    fi

    RESPONSE=$(printf '%s' "$AUTH_CONFIG" | curl -s --connect-timeout 10 --max-time 30 -K - \
        "$ENDPOINT/v1/messages" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "{\"model\":\"$MODEL\",\"max_tokens\":10,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
        2>/dev/null || true)

    if echo "$RESPONSE" | grep -Eq '"type"[[:space:]]*:[[:space:]]*"message"'; then
        echo -e "${GREEN}OK${NC} - API responding"
    elif [ -z "$RESPONSE" ]; then
        echo -e "${RED}FAILED${NC} - No response (connection failed or timed out)"
        exit 1
    elif echo "$RESPONSE" | grep -q '"error"'; then
        ERROR_MSG=$(echo "$RESPONSE" | grep -o '"message"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 |
            sed 's/.*:[[:space:]]*"\([^"]*\)"$/\1/')
        echo -e "${RED}ERROR${NC} - ${ERROR_MSG:-$RESPONSE}"
        exit 1
    else
        echo -e "${RED}FAILED${NC} - Unexpected response"
        exit 1
    fi
fi

echo ""
echo "=========================================="
