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

# Ensure npm global bin and system bin are on PATH
export PATH="$HOME/.npm-global/bin:/usr/local/bin:$PATH"

# ── Verify pi is available ──────────────────────────────────────────────────
PI_BIN="$(command -v pi 2>/dev/null || true)"
if [ -z "$PI_BIN" ]; then
    # Try common locations
    for d in /usr/local/bin /usr/bin "$HOME/.npm-global/bin"; do
        if [ -x "$d/pi" ]; then
            PI_BIN="$d/pi"
            break
        fi
    done
fi
if [ -n "$PI_BIN" ]; then
    echo "[entrypoint] pi found at $PI_BIN"
else
    echo "[entrypoint] WARN: pi not found on PATH — you may need to install it manually."
fi

# ── Install hotmilk globally if not already present ─────────────────────────
if [ ! -d "$HOME/.npm-global/lib/node_modules/hotmilk" ]; then
    echo "[entrypoint] installing hotmilk ..."
    mkdir -p "$HOME/.npm-global"
    npm config set prefix "$HOME/.npm-global"
    npm install -g hotmilk@latest || echo "[entrypoint] WARN: hotmilk install failed; you can install manually later."
    echo "[entrypoint] hotmilk installed"
else
    echo "[entrypoint] hotmilk already installed"
fi

# ── Fetch API keys from openhost secrets ────────────────────────────────────
_fetch_secret() {
    local key="$1"
    if [ -z "${OPENHOST_ROUTER_URL:-}" ] || [ -z "${OPENHOST_APP_TOKEN:-}" ]; then
        return 1
    fi
    python3 -c "
import httpx, os, json
url = f'{os.environ[\"OPENHOST_ROUTER_URL\"]}/api/services/v2/call/secrets/get'
try:
    resp = httpx.post(url, json={'keys': ['$key']},
                      headers={'Authorization': f'Bearer {os.environ[\"OPENHOST_APP_TOKEN\"]}'},
                      timeout=5)
    if resp.status_code == 200:
        data = resp.json()
        val = (data.get('secrets') or {}).get('$key', '')
        if val:
            print(val)
except Exception:
    pass
" 2>/dev/null
}

for key in OPENROUTER_API_KEY ANTHROPIC_API_KEY; do
    val="$(_fetch_secret "$key" || true)"
    if [ -n "$val" ]; then
        export "$key=$val"
        echo "[entrypoint] $key loaded from secrets"
    fi
done

# ── Create convenience dir ──────────────────────────────────────────────────
mkdir -p "$HOME/my_project"

exec python3 /app/server.py