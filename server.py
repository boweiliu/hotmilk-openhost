"""hotmilk: tabbed web terminals + Pi coding agent with hotmilk, for building/debugging openhost apps.

Routes:
    GET  /                         -> tabbed terminal UI
    GET  /health                   -> health check
    GET  /terminal/ws              -> WebSocket PTY (one session per connection)
"""

from __future__ import annotations

import asyncio
import fcntl
import json
import os
import pty
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

# Cached OPENROUTER_API_KEY value, fetched lazily from the secrets app on first
# PTY launch. `None` means "not yet fetched"; "" means "tried, not available".
_openrouter_key: str | None = None
_openrouter_lock = asyncio.Lock()


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


async def _fetch_openrouter_key() -> str:
    """Ask the secrets-v2 app for OPENROUTER_API_KEY. Returns "" if unavailable."""
    return (await _fetch_secrets(["OPENROUTER_API_KEY"])).get("OPENROUTER_API_KEY", "")


async def _get_openrouter_key() -> str:
    """Return the cached key, fetching once if we haven't yet."""
    global _openrouter_key
    if _openrouter_key is not None:
        return _openrouter_key
    async with _openrouter_lock:
        if _openrouter_key is not None:
            return _openrouter_key
        key = await _fetch_openrouter_key()
        _openrouter_key = key
        return key


def _set_winsize(fd: int, rows: int, cols: int) -> None:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


@app.get("/health")
async def health() -> tuple[dict, int]:
    return {"status": "ok"}, 200


@app.get("/")
async def index() -> object:
    return await send_from_directory(str(APP_DIR / "templates"), "index.html")


@app.websocket("/terminal/ws")
async def terminal_ws() -> None:
    # Pre-populate OPENROUTER_API_KEY from the secrets app if available.
    extra_env: dict[str, str] = {}
    key = await _get_openrouter_key()
    if key:
        extra_env["OPENROUTER_API_KEY"] = key

    command = ["bash", "-l"]
    cwd = str(MY_PROJECT_DIR) if MY_PROJECT_DIR.exists() else str(HOME)
    await _bridge_pty(command=command, cwd=cwd, extra_env=extra_env)


async def _bridge_pty(*, command: list[str], cwd: str | None, extra_env: dict[str, str] | None = None) -> None:
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