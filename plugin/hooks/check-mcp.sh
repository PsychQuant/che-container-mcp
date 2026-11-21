#!/bin/bash
# SessionStart status line for che-container-mcp. Read-only: it never downloads (the wrapper does
# that on first spawn) and never starts the container service.
BINARY="$HOME/bin/CheContainerMCP"
REPO="PsychQuant/che-container-mcp"
CONTAINER_CLI="/usr/local/bin/container"

if [[ -x "$BINARY" ]]; then
    INSTALLED=$("$BINARY" --version </dev/null 2>/dev/null | awk '{print $NF}')
    LATEST=$(curl -sI --max-time 3 "https://github.com/$REPO/releases/latest" 2>/dev/null \
        | grep -i '^location:' | sed -E 's|.*/v?([0-9]+\.[0-9]+\.[0-9]+).*|\1|' | tr -d '\r\n')
    if [[ -n "$INSTALLED" && -n "$LATEST" && "$INSTALLED" != "$LATEST" ]]; then
        echo "⬆️  che-container-mcp v$INSTALLED → v$LATEST available (the wrapper updates to the version the plugin pins)"
    else
        echo "✓ che-container-mcp v${INSTALLED:-?} installed"
    fi
else
    echo "ℹ️  che-container-mcp not installed yet — the MCP wrapper downloads it from $REPO on first use"
fi

if [[ -x "$CONTAINER_CLI" ]]; then
    # perl alarm, not timeout(1): macOS has no timeout without GNU coreutils.
    STATUS=$(perl -e 'alarm 3; exec @ARGV' "$CONTAINER_CLI" system status --format json 2>/dev/null \
        | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("status",""))
except Exception: print("")' 2>/dev/null)
    case "$STATUS" in
        running) echo "✓ container service running ($("$CONTAINER_CLI" --version 2>/dev/null | awk '{print $4}'))" ;;
        "")      echo "⚠️  container service not reachable — container_status with start: true starts it" ;;
        *)       echo "⚠️  container service: $STATUS — container_status with start: true starts it" ;;
    esac
else
    echo "⚠️  Apple container CLI not found at $CONTAINER_CLI — install it from https://github.com/apple/container/releases"
fi
exit 0
