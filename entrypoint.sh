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

# Ensure system bin and pi path are on PATH.
# Set NODE_PATH so pi can find globally installed packages regardless
# of which npm prefix they were installed to.
export PATH="/usr/local/bin:$PATH"
export NODE_PATH="$(npm root -g):${NODE_PATH:-}"

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

# ── Install hotmilk ───────────────────────────────────────────────────────
# NODE_PATH (set above) lets pi find packages in any npm prefix. We keep
# the existing user npm prefix for installs, which survives redeploys
# since HOME is on persistent storage.
NPM_GLOBAL="$(npm root -g)"
echo "[entrypoint] npm global prefix: $NPM_GLOBAL"

if [ ! -d "$NPM_GLOBAL/hotmilk" ]; then
    echo "[entrypoint] installing hotmilk to system global ..."
    npm install -g hotmilk@latest || echo "[entrypoint] WARN: hotmilk install failed"
    echo "[entrypoint] hotmilk installed to $NPM_GLOBAL/hotmilk"
else
    echo "[entrypoint] hotmilk already installed at $NPM_GLOBAL/hotmilk"
fi

# Register hotmilk in pi settings so pi loads it on startup.
PI_SETTINGS="$HOME/.pi/agent/settings.json"
mkdir -p "$(dirname "$PI_SETTINGS")"
if [ ! -f "$PI_SETTINGS" ]; then
    echo '{"packages": ["npm:hotmilk"]}' > "$PI_SETTINGS"
    echo "[entrypoint] pi settings created with hotmilk package"
else
    if ! python3 -c "import json; pkgs = json.load(open('$PI_SETTINGS')).get('packages', []); exit(0 if 'npm:hotmilk' in pkgs else 1)" 2>/dev/null; then
        python3 -c "
import json
with open('$PI_SETTINGS') as f:
    cfg = json.load(f)
cfg.setdefault('packages', [])
if 'npm:hotmilk' not in cfg['packages']:
    cfg['packages'].append('npm:hotmilk')
with open('$PI_SETTINGS', 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null
        echo "[entrypoint] hotmilk added to pi settings packages"
    fi
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