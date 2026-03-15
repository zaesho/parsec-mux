"""CLI entry point for parsec-mux.

Default command (no args) launches the viewer directly.
If no favorites are configured, runs interactive quick-setup first.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from .api import ParsecAPI, ParsecAPIError
from .auth import authenticate_interactive, clear_session, ensure_session
from .config import CONFIG_DIR, Config


# ── viewer launcher ──────────────────────────────────────────

VIEWER_DIR = Path(__file__).resolve().parent.parent / "viewer"
VIEWER_BIN = VIEWER_DIR / "pmux-viewer"
SESSIONS_FILE = CONFIG_DIR / "viewer_sessions.tsv"


def launch_viewer(session_id: str, config: Config, slotted: list | None = None, grid: bool = False) -> None:
    """Write config and exec into the native viewer."""
    api = ParsecAPI()

    if slotted is None:
        slotted = sorted(
            [p for p in config.favorites.values() if p.slot],
            key=lambda x: x.slot or 99,
        )

    # Write sessions file: favorites with slots first, then all other
    # online hosts with slot=0 (available for swap via Cmd+Shift+S)
    CONFIG_DIR.mkdir(exist_ok=True)
    slotted_peers = {p.peer_id for p in slotted}

    try:
        hosts = api.get_hosts(session_id)
    except Exception:
        hosts = []

    with open(SESSIONS_FILE, "w") as f:
        # Slotted favorites first (with optional resolution)
        for p in slotted:
            rx = p.settings.get("res_x", 0)
            ry = p.settings.get("res_y", 0)
            if rx or ry:
                f.write(f"{p.slot}\t{p.peer_id}\t{p.nickname}\t{rx}\t{ry}\n")
            else:
                f.write(f"{p.slot}\t{p.peer_id}\t{p.nickname}\n")
        # All other online hosts with slot=0
        for h in hosts:
            if h.peer_id not in slotted_peers and h.online:
                name = config.get_nickname(h.peer_id) or h.name
                f.write(f"0\t{h.peer_id}\t{name}\n")

    if not VIEWER_BIN.exists():
        print(f"Viewer binary not found at {VIEWER_BIN}")
        print("Build it: cd ~/parsec-mux/viewer && make")
        sys.exit(1)

    extra_count = sum(1 for h in hosts if h.peer_id not in slotted_peers and h.online)
    print(f"\nLaunching viewer with {len(slotted)} sessions (+{extra_count} available):")
    for p in slotted:
        print(f"  [Cmd+Shift+{p.slot}] {p.nickname}")
    print("\n  Cmd+Shift+S=swap session  Cmd+Shift+G=grid  Cmd+Q=quit\n")

    os.chdir(VIEWER_DIR)
    os.environ["PARSEC_SESSION_ID"] = session_id
    args_list = [str(VIEWER_BIN)]
    if grid:
        args_list.append("--grid")
    args_list.append(str(SESSIONS_FILE))
    os.execv(str(VIEWER_BIN), args_list)


# ── quick setup (interactive, no TUI needed) ─────────────────

def quick_setup(api: ParsecAPI, session_id: str, config: Config) -> bool:
    """Interactive host picker. Returns True if at least one host was added."""
    try:
        hosts = api.get_hosts(session_id)
    except ParsecAPIError as e:
        print(f"Failed to fetch hosts: {e}")
        return False

    online = [h for h in hosts if h.online and not h.name.endswith(".local")]
    if not online:
        online = [h for h in hosts if h.online]
    if not online:
        print("No online hosts found.")
        return False

    print("Available hosts:\n")
    for i, h in enumerate(online, 1):
        existing = config.get_nickname(h.peer_id)
        tag = f"  (saved as '{existing}')" if existing else ""
        print(f"  {i}. {h.name} ({h.user_name}){tag}")

    print(f"\nWhich hosts to add? (e.g. '1,3,4' or 'all')")
    try:
        choice = input("> ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return False

    if choice == "all":
        selected = list(range(len(online)))
    else:
        try:
            selected = [int(x.strip()) - 1 for x in choice.split(",") if x.strip()]
            selected = [i for i in selected if 0 <= i < len(online)]
        except ValueError:
            print("Invalid input.")
            return False

    if not selected:
        print("No hosts selected.")
        return False

    # Assign slots sequentially, starting from 1
    existing_slots = {p.slot for p in config.favorites.values() if p.slot}
    next_slot = 1

    for idx in selected:
        h = online[idx]
        while next_slot in existing_slots and next_slot <= 9:
            next_slot += 1
        if next_slot > 9:
            print(f"  Skipping {h.name} — no free slots (max 9)")
            continue

        # Use existing nickname if available, otherwise use host name
        nickname = config.get_nickname(h.peer_id) or h.name
        config.add_favorite(h.peer_id, nickname, slot=next_slot)
        print(f"  [Cmd+{next_slot}] {nickname}")
        existing_slots.add(next_slot)
        next_slot += 1

    return bool(selected)


# ── commands ─────────────────────────────────────────────────

def cmd_default(args: argparse.Namespace) -> None:
    """Default: launch viewer, or quick-setup if no favorites."""
    api = ParsecAPI()
    session_id = ensure_session(api)
    config = Config()

    slotted = sorted(
        [p for p in config.favorites.values() if p.slot],
        key=lambda x: x.slot or 99,
    )

    if not slotted:
        print("parsec-mux — first time setup\n")
        if not quick_setup(api, session_id, config):
            sys.exit(1)
        config = Config()
        slotted = sorted(
            [p for p in config.favorites.values() if p.slot],
            key=lambda x: x.slot or 99,
        )

    launch_viewer(session_id, config, slotted)


def cmd_grid(args: argparse.Namespace) -> None:
    """Launch directly into 2x2 grid mode."""
    api = ParsecAPI()
    session_id = ensure_session(api)
    config = Config()

    slotted = sorted(
        [p for p in config.favorites.values() if p.slot],
        key=lambda x: x.slot or 99,
    )

    if not slotted:
        print("No favorites configured. Run 'pmux' first to set up.")
        sys.exit(1)

    launch_viewer(session_id, config, slotted, grid=True)


def cmd_setup(args: argparse.Namespace) -> None:
    """TUI for managing favorites and slots."""
    api = ParsecAPI()
    session_id = ensure_session(api)
    config = Config()

    from .tui import ParsecMuxApp
    app = ParsecMuxApp(api, session_id, config)
    app.run()


def cmd_list(args: argparse.Namespace) -> None:
    api = ParsecAPI()
    session_id = ensure_session(api)
    config = Config()

    hosts = api.get_hosts(session_id)
    if not hosts:
        print("No hosts found.")
        return

    print(f"{'Slot':<5} {'Name':<20} {'Nickname':<15} {'Status':<14} {'Peer ID'}")
    print("-" * 72)
    for h in hosts:
        nickname = config.get_nickname(h.peer_id) or ""
        profile = config.favorites.get(h.peer_id)
        slot = str(profile.slot) if profile and profile.slot else "-"
        status = "● online" if h.online else "○ offline"
        print(f"{slot:<5} {h.name:<20} {nickname:<15} {status:<14} {h.peer_id[:16]}...")


def cmd_add(args: argparse.Namespace) -> None:
    """Add more hosts to favorites interactively."""
    api = ParsecAPI()
    session_id = ensure_session(api)
    config = Config()
    quick_setup(api, session_id, config)


def cmd_remove(args: argparse.Namespace) -> None:
    """Remove a host from favorites."""
    config = Config()
    profile = config.get_by_name(args.name)
    if profile:
        config.remove_favorite(profile.peer_id)
        print(f"Removed '{profile.nickname}'")
    else:
        print(f"No favorite matching '{args.name}'")


def cmd_auth(args: argparse.Namespace) -> None:
    api = ParsecAPI()
    clear_session()
    session_id = authenticate_interactive(api)
    user = api.get_me(session_id)
    print(f"Authenticated as {user.name} ({user.email})")


def cmd_reset(args: argparse.Namespace) -> None:
    """Clear all favorites and start fresh."""
    config = Config()
    config.favorites.clear()
    config.save()
    print("All favorites cleared. Run 'pmux' to set up again.")


# ── main ─────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        prog="pmux",
        description="tmux-style session manager for Parsec",
        epilog="Run with no arguments to launch the viewer.",
    )
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("grid", help="Launch directly in 2x2 grid mode")
    sub.add_parser("setup", help="Open TUI to manage favorites and slots")
    sub.add_parser("list", help="List all available hosts")
    sub.add_parser("add", help="Add hosts to favorites interactively")
    sub.add_parser("auth", help="Re-authenticate with Parsec")
    sub.add_parser("reset", help="Clear all favorites")

    p_rm = sub.add_parser("remove", help="Remove a host from favorites")
    p_rm.add_argument("name", help="Nickname or host name to remove")

    args = parser.parse_args()

    commands = {
        "grid": cmd_grid,
        "setup": cmd_setup,
        "list": cmd_list,
        "add": cmd_add,
        "remove": cmd_remove,
        "auth": cmd_auth,
        "reset": cmd_reset,
    }

    handler = commands.get(args.command)
    if handler:
        handler(args)
    else:
        cmd_default(args)


if __name__ == "__main__":
    main()
