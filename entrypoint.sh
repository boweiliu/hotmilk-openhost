#!/usr/bin/env bash
set -euo pipefail

# If the openhost runtime has provisioned a persistent data dir for us, move
# HOME there so pi config, npm global packages, shell history, etc. survive
# container redeploys.
if [ -n "${OPENHOST_APP_DATA_DIR:-}" ]; then
    export HOME="$OPENHOST_APP_DATA_DIR/home"
    mkdir -p "$HOME"
    cd "$HOME"
fi

# Ensure npm global bin is on PATH
export PATH="$HOME/.npm-global/bin:$PATH"

# Install hotmilk globally if not already present
if [ ! -d "$HOME/.npm-global/lib/node_modules/hotmilk" ]; then
    echo "[entrypoint] installing hotmilk ..."
    mkdir -p "$HOME/.npm-global"
    npm config set prefix "$HOME/.npm-global"
    npm install -g hotmilk@latest || echo "[entrypoint] WARN: hotmilk install failed; you can install manually later."
fi

# Pre-populate OPENROUTER_API_KEY from the secrets app if available.
# The server also does this per-PTY, but seeding it here ensures it's
# in the environment before the server process starts (useful for any
# subprocesses that inherit the env).
if [ -n "${OPENHOST_ROUTER_URL:-}" ] && [ -n "${OPENHOST_APP_TOKEN:-}" ]; then
    echo "[entrypoint] fetching OPENROUTER_API_KEY from secrets app ..."
    KEY_RESP="$(python3 -c "
import httpx, os, json
url = f'{os.environ[\"OPENHOST_ROUTER_URL\"]}/api/services/v2/call/secrets/get'
try:
    resp = httpx.post(url, json={'keys': ['OPENROUTER_API_KEY']},
                      headers={'Authorization': f'Bearer {os.environ[\"OPENHOST_APP_TOKEN\"]}'},
                      timeout=5)
    if resp.status_code == 200:
        data = resp.json()
        key = (data.get('secrets') or {}).get('OPENROUTER_API_KEY', '')
        print(key)
except Exception:
    pass
" 2>/dev/null || true)"
    if [ -n "$KEY_RESP" ]; then
        export OPENROUTER_API_KEY="$KEY_RESP"
        echo "[entrypoint] OPENROUTER_API_KEY loaded from secrets"
    fi
fi

# Create a convenience my_project dir
mkdir -p "$HOME/my_project"

exec python3 /app/server.py