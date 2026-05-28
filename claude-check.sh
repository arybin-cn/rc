#!/bin/bash
# Claude API Health Check Script
# Usage: claude-check [endpoint]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Read config from settings
if [ -n "$1" ]; then
    ENDPOINT="$1"
    API_KEY=$(grep -o '"ANTHROPIC_AUTH_TOKEN": "[^"]*"' ~/.claude/settings.json 2>/dev/null | cut -d'"' -f4)
    MODEL=$(grep -o '"ANTHROPIC_MODEL": "[^"]*"' ~/.claude/settings.json 2>/dev/null | cut -d'"' -f4 | sed 's/\[.*\]//')
else
    ENDPOINT=$(grep -o '"ANTHROPIC_BASE_URL": "[^"]*"' ~/.claude/settings.json 2>/dev/null | cut -d'"' -f4)
    API_KEY=$(grep -o '"ANTHROPIC_AUTH_TOKEN": "[^"]*"' ~/.claude/settings.json 2>/dev/null | cut -d'"' -f4)
    MODEL=$(grep -o '"ANTHROPIC_MODEL": "[^"]*"' ~/.claude/settings.json 2>/dev/null | cut -d'"' -f4 | sed 's/\[.*\]//')
fi

if [ -z "$ENDPOINT" ]; then
    echo -e "${RED}Error: No endpoint found. Usage: claude-check <url>${NC}"
    exit 1
fi

# Extract host from URL
HOST=$(echo "$ENDPOINT" | sed -E 's|https?://([^/]+).*|\1|')

echo "=========================================="
echo "  Claude API Health Check"
echo "=========================================="
echo "Endpoint: $ENDPOINT"
echo "Model: $MODEL"
echo ""

# 1. DNS Check
echo -n "[1/3] DNS Resolution... "
if IP=$(getent hosts "$HOST" 2>/dev/null | awk '{print $1}' | head -1); then
    if [ -n "$IP" ]; then
        echo -e "${GREEN}OK${NC} ($IP)"
    else
        echo -e "${RED}FAILED${NC} - Cannot resolve host"
        exit 1
    fi
else
    echo -e "${RED}FAILED${NC} - DNS lookup failed"
    exit 1
fi

# 2. HTTPS Connection
echo -n "[2/3] HTTPS Connection... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$ENDPOINT" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "000" ]; then
    echo -e "${RED}FAILED${NC} - Connection timeout"
    exit 1
elif [ "$HTTP_CODE" = "404" ] || [ "$HTTP_CODE" = "405" ]; then
    echo -e "${GREEN}OK${NC} (HTTP $HTTP_CODE - endpoint reachable)"
elif [ "$HTTP_CODE" = "200" ]; then
    echo -e "${GREEN}OK${NC} (HTTP $HTTP_CODE)"
else
    echo -e "${YELLOW}WARN${NC} (HTTP $HTTP_CODE)"
fi

# 3. API Call Test
echo -n "[3/3] API Call Test... "
if [ -z "$API_KEY" ]; then
    echo -e "${YELLOW}SKIP${NC} (no API key found)"
else
    RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 \
        "$ENDPOINT/v1/messages" \
        -H "x-api-key: $API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "{\"model\":\"$MODEL\",\"max_tokens\":10,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
        2>/dev/null)

    if echo "$RESPONSE" | grep -q '"type":"message"'; then
        echo -e "${GREEN}OK${NC} - API responding"
    elif echo "$RESPONSE" | grep -q '"error"'; then
        ERROR_MSG=$(echo "$RESPONSE" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
        echo -e "${RED}ERROR${NC} - $ERROR_MSG"
    else
        echo -e "${RED}FAILED${NC} - Unexpected response"
    fi
fi

echo ""
echo "=========================================="
