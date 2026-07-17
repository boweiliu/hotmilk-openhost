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

# Create a convenience my_project dir
mkdir -p "$HOME/my_project"

exec python3 /app/server.py