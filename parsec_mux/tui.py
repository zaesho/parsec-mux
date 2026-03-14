"""Textual TUI for parsec-mux."""

from __future__ import annotations

import time

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Container
from textual.screen import ModalScreen
from textual.widgets import DataTable, Footer, Header, Input, Label, Static
from textual import work

from .api import Host, ParsecAPI, ParsecAPIError
from .config import Config
from .sessions import SessionManager


class StatusBar(Static):
    DEFAULT_CSS = """
    StatusBar {
        dock: bottom;
        height: 1;
        padding: 0 2;
        background: $error-darken-3;
        color: $text;
    }
    StatusBar.connected {
        background: $success-darken-2;
    }
    """

    def set_connected(self, name: str, uptime: str) -> None:
        self.update(f" ● Connected: {name} ({uptime})")
        self.add_class("connected")

    def set_disconnected(self) -> None:
        self.update(" ○ Disconnected")
        self.remove_class("connected")


class NicknameDialog(ModalScreen[tuple[str, int | None] | None]):
    DEFAULT_CSS = """
    NicknameDialog {
        align: center middle;
    }
    #dialog-box {
        width: 55;
        height: auto;
        max-height: 14;
        border: thick $accent;
        background: $surface;
        padding: 1 2;
    }
    #dialog-box Label {
        margin-bottom: 1;
    }
    #dialog-box .hint {
        color: $text-muted;
        margin-top: 1;
    }
    """
    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    def __init__(self, host_name: str) -> None:
        super().__init__()
        self.host_name = host_name

    def compose(self) -> ComposeResult:
        with Container(id="dialog-box"):
            yield Label(f"Set nickname for: [bold]{self.host_name}[/bold]")
            yield Input(placeholder="Nickname", id="nick")
            yield Input(placeholder="Quick-switch slot (1-9, optional)", id="slot")
            yield Label("Enter = save | Escape = cancel", classes="hint")

    def on_input_submitted(self, event: Input.Submitted) -> None:
        nickname = self.query_one("#nick", Input).value.strip()
        slot_str = self.query_one("#slot", Input).value.strip()
        slot = int(slot_str) if slot_str.isdigit() and 1 <= int(slot_str) <= 9 else None
        if nickname:
            self.dismiss((nickname, slot))

    def action_cancel(self) -> None:
        self.dismiss(None)


class ParsecMuxApp(App):
    CSS = """
    #host-table {
        height: 1fr;
        margin: 1 2;
    }
    #info-bar {
        dock: bottom;
        height: 1;
        padding: 0 2;
        color: $text-muted;
    }
    """

    TITLE = "parsec-mux"

    BINDINGS = [
        Binding("c", "connect", "Connect"),
        Binding("enter", "connect", "Connect", show=False),
        Binding("d", "disconnect", "Disconnect"),
        Binding("s", "switch", "Switch"),
        Binding("r", "refresh", "Refresh"),
        Binding("f", "favorite", "Favorite"),
        Binding("x", "unfavorite", "Unfavorite"),
        Binding("1", "slot(1)", "1", show=False),
        Binding("2", "slot(2)", "2", show=False),
        Binding("3", "slot(3)", "3", show=False),
        Binding("4", "slot(4)", "4", show=False),
        Binding("5", "slot(5)", "5", show=False),
        Binding("6", "slot(6)", "6", show=False),
        Binding("7", "slot(7)", "7", show=False),
        Binding("8", "slot(8)", "8", show=False),
        Binding("9", "slot(9)", "9", show=False),
        Binding("q", "quit", "Quit"),
    ]

    def __init__(self, api: ParsecAPI, session_id: str, config: Config) -> None:
        super().__init__()
        self.api = api
        self.session_id = session_id
        self.config = config
        self.session_mgr = SessionManager()
        self.hosts: list[Host] = []

    def compose(self) -> ComposeResult:
        yield Header()
        yield DataTable(id="host-table")
        yield Static("", id="info-bar")
        yield StatusBar()
        yield Footer()

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.add_columns("Slot", "Name", "Nickname", "Status", "Players", "Peer ID")
        table.cursor_type = "row"
        self.refresh_hosts()
        self.set_interval(30, self.refresh_hosts)
        self.set_interval(1, self._tick_status)

    def _tick_status(self) -> None:
        bar = self.query_one(StatusBar)
        # Use the status property (single pgrep check, handles cleanup internally)
        status = self.session_mgr.status
        if self.session_mgr.active:
            bar.set_connected(self.session_mgr.active.host_name, self.session_mgr.active.uptime)
        else:
            bar.set_disconnected()

    @work(thread=True)
    def refresh_hosts(self) -> None:
        try:
            self.hosts = self.api.get_hosts(self.session_id)
            self.app.call_from_thread(self._rebuild_table)
        except ParsecAPIError as e:
            self.app.call_from_thread(
                self.query_one("#info-bar", Static).update,
                f" Error: {e}",
            )

    def _rebuild_table(self) -> None:
        table = self.query_one(DataTable)
        table.clear()

        active_peer = (self.session_mgr.active.peer_id
                       if self.session_mgr.active else None)

        for host in self.hosts:
            nickname = self.config.get_nickname(host.peer_id) or ""
            profile = self.config.favorites.get(host.peer_id)
            slot = str(profile.slot) if profile and profile.slot else "-"

            if active_peer and host.peer_id == active_peer:
                status = "▶ connected"
            elif host.online:
                status = "● online"
            else:
                status = "○ offline"

            players = f"{host.players}/{host.max_players}"
            peer_short = host.peer_id[:12] + "..."

            table.add_row(slot, host.name, nickname, status, players, peer_short, key=host.peer_id)

        self.query_one("#info-bar", Static).update(
            f" {len(self.hosts)} hosts | Last refresh: {time.strftime('%H:%M:%S')}"
        )

    def _selected_host(self) -> Host | None:
        table = self.query_one(DataTable)
        if table.row_count == 0:
            return None
        try:
            row_key, _ = table.coordinate_to_cell_key(table.cursor_coordinate)
            for host in self.hosts:
                if host.peer_id == row_key.value:
                    return host
        except Exception:
            pass
        return None

    # ── actions ──────────────────────────────────────────────

    def action_connect(self) -> None:
        host = self._selected_host()
        if not host:
            self.notify("No host selected", severity="warning")
            return
        if not host.online:
            self.notify(f"{host.name} is offline", severity="warning")
            return

        settings = self.config.get_settings(host.peer_id)
        name = self.config.get_nickname(host.peer_id) or host.name
        self.session_mgr.connect(host.peer_id, name, settings)
        self.notify(f"Connecting to {name}...")
        self._rebuild_table()

    def action_disconnect(self) -> None:
        if self.session_mgr.disconnect():
            self.notify("Disconnected")
            self._rebuild_table()
        else:
            self.notify("Not connected", severity="warning")

    def action_switch(self) -> None:
        host = self._selected_host()
        if not host:
            self.notify("No host selected", severity="warning")
            return
        if not host.online:
            self.notify(f"{host.name} is offline", severity="warning")
            return

        settings = self.config.get_settings(host.peer_id)
        name = self.config.get_nickname(host.peer_id) or host.name
        self.session_mgr.switch(host.peer_id, name, settings)
        self.notify(f"Switched to {name}")
        self._rebuild_table()

    def action_refresh(self) -> None:
        self.refresh_hosts()
        self.notify("Refreshing...")

    def action_favorite(self) -> None:
        host = self._selected_host()
        if not host:
            self.notify("No host selected", severity="warning")
            return

        def on_dismiss(result: tuple[str, int | None] | None) -> None:
            if result:
                nickname, slot = result
                self.config.add_favorite(host.peer_id, nickname, slot)
                self.notify(f"Saved '{nickname}'" + (f" on slot {slot}" if slot else ""))
                self._rebuild_table()

        self.push_screen(NicknameDialog(host.name), on_dismiss)

    def action_unfavorite(self) -> None:
        host = self._selected_host()
        if not host:
            self.notify("No host selected", severity="warning")
            return
        name = self.config.get_nickname(host.peer_id)
        if name:
            self.config.remove_favorite(host.peer_id)
            self.notify(f"Removed '{name}'")
            self._rebuild_table()
        else:
            self.notify("Not a favorite", severity="warning")

    def action_slot(self, slot: int) -> None:
        profile = self.config.get_by_slot(slot)
        if not profile:
            self.notify(f"No host on slot {slot}", severity="warning")
            return

        host = next((h for h in self.hosts if h.peer_id == profile.peer_id), None)
        if host and not host.online:
            self.notify(f"{profile.nickname} is offline", severity="warning")
            return

        self.session_mgr.switch(profile.peer_id, profile.nickname, profile.settings)
        self.notify(f"Slot {slot} → {profile.nickname}")
        self._rebuild_table()

    def action_quit(self) -> None:
        # Leave Parsec running on TUI exit
        self.exit()
