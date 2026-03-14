"""Authentication — piggybacks on the installed Parsec app's session."""

from __future__ import annotations

import getpass
import json
import re
import sqlite3
import subprocess
from pathlib import Path

from .api import ParsecAPI, ParsecAPIError, AuthResult
from .config import CONFIG_DIR, ensure_config_dir

PARSEC_CACHE_DB = Path.home() / "Library/Caches/tv.parsec.www/Cache.db"
SESSION_FILE = CONFIG_DIR / "session.json"


def extract_parsec_session() -> str | None:
    """Extract the session_id from Parsec's WebKit cache.

    Parsec stores its API requests as binary plists in the WebKit
    cache DB. The Authorization header contains the Bearer token.
    """
    if not PARSEC_CACHE_DB.exists():
        return None

    try:
        with sqlite3.connect(f"file:{PARSEC_CACHE_DB}?mode=ro", uri=True) as conn:
            row = conn.execute(
                "SELECT request_object FROM cfurl_cache_blob_data b "
                "JOIN cfurl_cache_response r ON b.entry_ID = r.entry_ID "
                "WHERE r.request_key LIKE '%kessel-api.parsec.app/me'"
            ).fetchone()

        if not row or not row[0]:
            return None

        # Convert bplist to XML via plutil
        result = subprocess.run(
            ["plutil", "-convert", "xml1", "-o", "-", "-"],
            input=row[0],
            capture_output=True,
        )
        if result.returncode != 0:
            return None

        xml_text = result.stdout.decode("utf-8", errors="replace")

        # Extract Bearer token from the plist XML
        match = re.search(r"Bearer\s+([a-f0-9]{40,})", xml_text)
        if match:
            return match.group(1)

    except (sqlite3.Error, OSError):
        pass

    return None


def save_session(session_id: str) -> None:
    ensure_config_dir()
    SESSION_FILE.write_text(json.dumps({"session_id": session_id}))
    SESSION_FILE.chmod(0o600)


def load_session() -> str | None:
    if SESSION_FILE.exists():
        data = json.loads(SESSION_FILE.read_text())
        return data.get("session_id")
    return None


def clear_session() -> None:
    if SESSION_FILE.exists():
        SESSION_FILE.unlink()


def authenticate_interactive(api: ParsecAPI) -> str:
    """Interactive login with IP-verification handling."""
    email = input("Parsec email: ")
    password = getpass.getpass("Parsec password: ")

    try:
        result = api.login(email, password)
    except ParsecAPIError as e:
        msg = str(e)
        if e.tfa_required:
            tfa_code = input("2FA code: ")
            result = api.login(email, password, tfa=tfa_code)
        elif "verify" in msg.lower() and "ip" in msg.lower():
            print(f"\n{msg}")
            input("\nCheck your email, click the verification link, then press Enter to retry...")
            result = api.login(email, password)
        else:
            raise

    save_session(result.session_id)
    return result.session_id


def ensure_session(api: ParsecAPI) -> str:
    """Try to get a valid session, in order of preference:
    1. Our cached session (if still valid)
    2. Parsec app's own session (from WebKit cache)
    3. Interactive login (fallback)
    """
    # 1. Check our own cache
    session_id = load_session()
    if session_id and api.is_session_valid(session_id):
        return session_id

    # 2. Steal from Parsec's WebKit cache
    session_id = extract_parsec_session()
    if session_id and api.is_session_valid(session_id):
        save_session(session_id)
        return session_id

    # 3. Fall back to interactive login
    clear_session()
    return authenticate_interactive(api)
