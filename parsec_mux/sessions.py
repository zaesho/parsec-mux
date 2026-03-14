"""Parsec session/process manager for macOS.

Uses the parsec:// URL scheme to send connection requests to the
already-running Parsec app — no kill/relaunch cycle needed.
"""

from __future__ import annotations

import json
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from .config import CONFIG_DIR

STATE_FILE = CONFIG_DIR / "state.json"


@dataclass
class ConnectionInfo:
    peer_id: str
    host_name: str
    connected_at: float

    @property
    def uptime(self) -> str:
        elapsed = int(time.time() - self.connected_at)
        hours, remainder = divmod(elapsed, 3600)
        minutes, seconds = divmod(remainder, 60)
        if hours > 0:
            return f"{hours}h {minutes}m"
        return f"{minutes}m {seconds}s"


class SessionManager:
    def __init__(self):
        self.active: ConnectionInfo | None = None
        self._restore_state()

    def connect(self, peer_id: str, host_name: str, settings: dict | None = None) -> ConnectionInfo:
        # Build parsec:// URL with settings
        url = f"parsec://peer_id={peer_id}"
        if settings:
            extras = ":".join(f"{k}={v}" for k, v in settings.items())
            url += ":" + extras

        # Send to the running Parsec app via macOS URL dispatch.
        # If Parsec isn't running, this also launches it.
        subprocess.run(["open", url], capture_output=True, timeout=5)

        self.active = ConnectionInfo(
            peer_id=peer_id,
            host_name=host_name,
            connected_at=time.time(),
        )
        self._save_state()
        return self.active

    def disconnect(self) -> bool:
        was_connected = self.active is not None
        if was_connected:
            # Click the Parsec "Disconnect" menu item via Accessibility.
            # Falls back to bringing Parsec to front so user can disconnect manually.
            subprocess.run(
                ["osascript", "-e",
                 'tell application "System Events"\n'
                 '  if exists process "parsecd" then\n'
                 '    tell process "parsecd"\n'
                 '      try\n'
                 '        click menu item "Disconnect" of menu 1 of menu bar item 1 of menu bar 2\n'
                 '      end try\n'
                 '    end tell\n'
                 '  end if\n'
                 'end tell'],
                capture_output=True,
                timeout=5,
            )
        self.active = None
        self._save_state()
        return was_connected

    def switch(self, peer_id: str, host_name: str, settings: dict | None = None) -> ConnectionInfo:
        # Just open the new URL — Parsec drops the old connection
        # automatically when a new one is initiated.
        return self.connect(peer_id, host_name, settings)

    @property
    def status(self) -> str:
        if self.active and self._is_parsec_running():
            return f"Connected to {self.active.host_name} ({self.active.uptime})"
        if self.active and not self._is_parsec_running():
            self.active = None
            self._save_state()
        return "Disconnected"

    def _is_parsec_running(self) -> bool:
        result = subprocess.run(["pgrep", "-x", "parsecd"], capture_output=True)
        return result.returncode == 0

    def _save_state(self) -> None:
        if self.active:
            STATE_FILE.write_text(json.dumps({
                "peer_id": self.active.peer_id,
                "host_name": self.active.host_name,
                "connected_at": self.active.connected_at,
            }))
        elif STATE_FILE.exists():
            STATE_FILE.unlink()

    def _restore_state(self) -> None:
        if not STATE_FILE.exists():
            return
        try:
            data = json.loads(STATE_FILE.read_text())
            if self._is_parsec_running():
                self.active = ConnectionInfo(
                    peer_id=data["peer_id"],
                    host_name=data["host_name"],
                    connected_at=data["connected_at"],
                )
            else:
                STATE_FILE.unlink()
        except (json.JSONDecodeError, KeyError):
            STATE_FILE.unlink()
