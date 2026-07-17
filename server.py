"""hotmilk: tabbed web terminals + Pi coding agent with hotmilk, for building/debugging openhost apps.

Routes:
    GET  /                         -> tabbed terminal UI
    GET  /health                   -> health check
    GET  /diag                     -> diagnostic: pi PATH, hotmilk settings, secrets status
    GET  /terminal/ws              -> WebSocket PTY (one session per connection)
"""

from __future__ import annotations

import asyncio
import fcntl
import json
import os
import pty
import shutil
import signal
import struct
import subprocess
import termios
from pathlib import Path

import httpx
from quart import Quart, jsonify, send_from_directory, websocket

APP_DIR = Path(__file__).parent
HOME = Path(os.environ.get("HOME", "/root"))
MY_PROJECT_DIR = HOME / "my_project"

ROUTER_URL = os.environ.get("OPENHOST_ROUTER_URL", "")
APP_TOKEN = os.environ.get("OPENHOST_APP_TOKEN", "")
SECRETS_SHORTNAME = "secrets"

app = Quart(__name__, template_folder=str(APP_DIR / "templates"), static_folder=str(APP_DIR / "static"))

# Cached secrets, fetched lazily on first PTY launch.
# None = not fetched yet; "" = tried, not available.
_secrets_cache: dict[str, str] | None = None
_secrets_lock = asyncio.Lock()

SECRET_KEYS = ["OPENROUTER_API_KEY", "ANTHROPIC_API_KEY"]


async def _fetch_secrets(keys: list[str]) -> dict[str, str]:
    """Ask the secrets-v2 app for the given keys. Returns {} if unavailable."""
    if not ROUTER_URL or not APP_TOKEN:
        return {}
    url = f"{ROUTER_URL}/api/services/v2/call/{SECRETS_SHORTNAME}/get"
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            resp = await client.post(
                url,
                json={"keys": keys},
                headers={"Authorization": f"Bearer {APP_TOKEN}"},
            )
        if resp.status_code != 200:
            return {}
        return {k: v for k, v in (resp.json().get("secrets") or {}).items() if v}
    except Exception:
        return {}


async def _get_all_secrets() -> dict[str, str]:
    """Return cached secrets, fetching once if needed."""
    global _secrets_cache
    if _secrets_cache is not None:
        return _secrets_cache
    async with _secrets_lock:
        if _secrets_cache is not None:
            return _secrets_cache
        _secrets_cache = await _fetch_secrets(SECRET_KEYS)
        return _secrets_cache


def _find_pi() -> str | None:
    """Locate the `pi` binary. Returns path or None."""
    pi = shutil.which("pi")
    if pi:
        return pi
    # Check common locations
    for d in ["/usr/local/bin", "/usr/bin", "/root/.npm-global/bin"]:
        p = Path(d) / "pi"
        if p.exists():
            return str(p)
    return None


def _check_hotmilk_settings() -> dict:
    """Check if hotmilk settings are in place."""
    hotmilk_json = HOME / ".pi" / "agent" / "hotmilk.json"
    pi_settings = HOME / ".pi" / "agent" / "settings.json"
    result: dict = {"hotmilk_json": str(hotmilk_json)}
    if hotmilk_json.exists():
        result["hotmilk_json_exists"] = True
        result["hotmilk_json_size"] = hotmilk_json.stat().st_size
        try:
            cfg = json.loads(hotmilk_json.read_text())
            result["extensions_enabled"] = {
                k: v
                for k, v in cfg.get("extensions", {}).items()
                if v is True
            }
            result["extensions_count"] = len(result["extensions_enabled"])
        except Exception as e:
            result["hotmilk_json_error"] = str(e)
    else:
        result["hotmilk_json_exists"] = False
    result["pi_settings"] = str(pi_settings)
    result["pi_settings_exists"] = pi_settings.exists()
    return result


# ── Routes ──────────────────────────────────────────────────────────────────


@app.get("/health")
async def health() -> tuple[dict, int]:
    return {"status": "ok"}, 200


@app.get("/diag")
async def diag() -> tuple[dict, int]:
    """Diagnostic endpoint: check pi, hotmilk, and secrets."""
    pi_path = _find_pi()
    pi_version = ""
    if pi_path:
        try:
            r = subprocess.run([pi_path, "--version"], capture_output=True, text=True, timeout=5)
            pi_version = r.stdout.strip() or r.stderr.strip()
        except Exception as e:
            pi_version = f"error: {e}"

    secrets = await _get_all_secrets()
    return {
        "pi": {
            "found": pi_path is not None,
            "path": pi_path,
            "version": pi_version,
        },
        "hotmilk": _check_hotmilk_settings(),
        "secrets": {
            "router_available": bool(ROUTER_URL),
            "keys_configured": [k for k in SECRET_KEYS if secrets.get(k)],
            "keys_missing": [k for k in SECRET_KEYS if not secrets.get(k)],
        },
        "home": str(HOME),
        "my_project": str(MY_PROJECT_DIR),
    }, 200


@app.get("/")
async def index() -> object:
    return await send_from_directory(str(APP_DIR / "templates"), "index.html")


@app.websocket("/terminal/ws")
async def terminal_ws() -> None:
    # Pre-populate API keys from the secrets app if available.
    secrets = await _get_all_secrets()
    extra_env: dict[str, str] = {k: v for k, v in secrets.items() if v}

    command = ["bash", "-l"]
    cwd = str(MY_PROJECT_DIR) if MY_PROJECT_DIR.exists() else str(HOME)
    await _bridge_pty(command=command, cwd=cwd, extra_env=extra_env, stdin_seed="pi\n")


async def _bridge_pty(
    *,
    command: list[str],
    cwd: str | None,
    extra_env: dict[str, str] | None = None,
    stdin_seed: str = "",
) -> None:
    master_fd, slave_fd = pty.openpty()
    _set_winsize(master_fd, 24, 80)

    env = {**os.environ, "TERM": "xterm-256color", **(extra_env or {})}
    proc = subprocess.Popen(  # noqa: S603
        command,
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        cwd=cwd,
        env=env,
        preexec_fn=os.setsid,
    )
    os.close(slave_fd)

    if stdin_seed:
        # Give bash a moment to set up its TTY before we feed input.
        async def _seed() -> None:
            await asyncio.sleep(0.5)
            try:
                os.write(master_fd, stdin_seed.encode())
            except OSError:
                pass

        asyncio.create_task(_seed())

    loop = asyncio.get_event_loop()

    async def pty_to_ws() -> None:
        try:
            while True:
                data = await loop.run_in_executor(None, os.read, master_fd, 4096)
                if not data:
                    break
                await websocket.send(data)
        except Exception:
            pass

    async def ws_to_pty() -> None:
        try:
            while True:
                msg = await websocket.receive()
                if isinstance(msg, (bytes, bytearray)) and len(msg) > 0:
                    kind = msg[0]
                    payload = bytes(msg[1:])
                    if kind == 0x00:
                        os.write(master_fd, payload)
                    elif kind == 0x01:
                        ctrl = json.loads(payload)
                        if ctrl.get("type") == "resize":
                            _set_winsize(master_fd, int(ctrl["rows"]), int(ctrl["cols"]))
                elif isinstance(msg, str):
                    os.write(master_fd, msg.encode())
        except Exception:
            pass

    def cleanup() -> None:
        try:
            os.kill(proc.pid, signal.SIGHUP)
        except OSError:
            pass
        try:
            os.close(master_fd)
        except OSError:
            pass
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            try:
                os.kill(proc.pid, signal.SIGKILL)
            except OSError:
                pass

    tasks = [asyncio.create_task(pty_to_ws()), asyncio.create_task(ws_to_pty())]
    try:
        _, pending_tasks = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for t in pending_tasks:
            t.cancel()
    finally:
        cleanup()


def _set_winsize(fd: int, rows: int, cols: int) -> None:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


async def _serve() -> None:
    import hypercorn.asyncio
    import hypercorn.config

    cfg = hypercorn.config.Config()
    cfg.bind = ["0.0.0.0:5000"]
    cfg.accesslog = "-"
    await hypercorn.asyncio.serve(app, cfg)


def main() -> None:
    asyncio.run(_serve())


if __name__ == "__main__":
    main()