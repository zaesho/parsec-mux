"""Parsec Kessel API client."""

from __future__ import annotations

import requests
from dataclasses import dataclass

BASE_URL = "https://kessel-api.parsec.app"
USER_AGENT = "parsec-mux/0.1.0"


@dataclass
class Host:
    peer_id: str
    name: str
    online: bool
    players: int
    max_players: int
    user_name: str
    user_id: int
    build: str


@dataclass
class AuthResult:
    session_id: str
    host_peer_id: str
    user_id: int
    instance_id: str


@dataclass
class UserInfo:
    id: int
    name: str
    email: str
    has_tfa: bool


class ParsecAPIError(Exception):
    def __init__(self, message: str, tfa_required: bool = False):
        super().__init__(message)
        self.tfa_required = tfa_required


class ParsecAPI:
    def __init__(self):
        self._session = requests.Session()
        self._session.headers.update({
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        })

    def login(self, email: str, password: str, tfa: str = "") -> AuthResult:
        resp = self._session.post(f"{BASE_URL}/v1/auth", json={
            "email": email,
            "password": password,
            "tfa": tfa,
        })
        data = resp.json()

        if resp.status_code == 201:
            return AuthResult(
                session_id=data["session_id"],
                host_peer_id=data.get("host_peer_id", ""),
                user_id=data.get("user_id", 0),
                instance_id=data.get("instance_id", ""),
            )

        raise ParsecAPIError(
            data.get("error", "Authentication failed"),
            tfa_required=data.get("tfa_required", False),
        )

    def get_hosts(self, session_id: str) -> list[Host]:
        resp = self._session.get(
            f"{BASE_URL}/v2/hosts",
            params={"mode": "desktop", "public": "false"},
            headers={"Authorization": f"Bearer {session_id}"},
        )

        if resp.status_code != 200:
            raise ParsecAPIError(resp.json().get("error", "Failed to get hosts"))

        hosts = []
        for h in resp.json().get("data", []):
            user = h.get("user", {})
            hosts.append(Host(
                peer_id=h["peer_id"],
                name=h.get("name", "Unknown"),
                online=h.get("online", False),
                players=h.get("players", 0),
                max_players=h.get("max_players", 1),
                user_name=user.get("name", ""),
                user_id=user.get("id", 0),
                build=h.get("build", ""),
            ))
        return hosts

    def get_me(self, session_id: str) -> UserInfo:
        resp = self._session.get(
            f"{BASE_URL}/me",
            headers={"Authorization": f"Bearer {session_id}"},
        )
        if resp.status_code != 200:
            raise ParsecAPIError("Session expired or invalid")

        data = resp.json().get("data", {})
        return UserInfo(
            id=data.get("id", 0),
            name=data.get("name", ""),
            email=data.get("email", ""),
            has_tfa=data.get("has_tfa", False),
        )

    def is_session_valid(self, session_id: str) -> bool:
        try:
            self.get_me(session_id)
            return True
        except (ParsecAPIError, requests.RequestException):
            return False
