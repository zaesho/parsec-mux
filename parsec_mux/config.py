"""Configuration: favorites, nicknames, per-host settings."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

CONFIG_DIR = Path.home() / ".parsec-mux"
FAVORITES_FILE = CONFIG_DIR / "favorites.json"

def ensure_config_dir() -> None:
    """Create config dir once. Importable by other modules."""
    CONFIG_DIR.mkdir(exist_ok=True)


@dataclass
class HostProfile:
    peer_id: str
    nickname: str
    settings: dict = field(default_factory=dict)
    slot: int | None = None


class Config:
    def __init__(self):
        self.favorites: dict[str, HostProfile] = {}
        self._load()

    def _load(self) -> None:
        if not FAVORITES_FILE.exists():
            return
        try:
            data = json.loads(FAVORITES_FILE.read_text())
            for peer_id, entry in data.items():
                self.favorites[peer_id] = HostProfile(
                    peer_id=peer_id,
                    nickname=entry.get("nickname", ""),
                    settings=entry.get("settings", {}),
                    slot=entry.get("slot"),
                )
        except (json.JSONDecodeError, AttributeError):
            pass

    def save(self) -> None:
        CONFIG_DIR.mkdir(exist_ok=True)
        data = {}
        for peer_id, profile in self.favorites.items():
            data[peer_id] = {
                "nickname": profile.nickname,
                "settings": profile.settings,
                "slot": profile.slot,
            }
        FAVORITES_FILE.write_text(json.dumps(data, indent=2))

    def add_favorite(self, peer_id: str, nickname: str,
                     slot: int | None = None, settings: dict | None = None) -> None:
        self.favorites[peer_id] = HostProfile(
            peer_id=peer_id,
            nickname=nickname,
            settings=settings or {},
            slot=slot,
        )
        self.save()

    def remove_favorite(self, peer_id: str) -> None:
        self.favorites.pop(peer_id, None)
        self.save()

    def get_nickname(self, peer_id: str) -> str | None:
        profile = self.favorites.get(peer_id)
        return profile.nickname if profile else None

    def get_settings(self, peer_id: str) -> dict:
        profile = self.favorites.get(peer_id)
        return profile.settings if profile else {}

    def get_by_slot(self, slot: int) -> HostProfile | None:
        for profile in self.favorites.values():
            if profile.slot == slot:
                return profile
        return None

    def get_by_name(self, name: str) -> HostProfile | None:
        name_lower = name.lower()
        for profile in self.favorites.values():
            if profile.nickname.lower() == name_lower:
                return profile
        for profile in self.favorites.values():
            if profile.peer_id.lower().startswith(name_lower):
                return profile
        return None
