# parsec-mux

A session manager and custom viewer for Parsec, inspired by tmux. Instead of clicking through the Parsec GUI to switch between remote machines, parsec-mux lets you manage multiple sessions from the command line and switch between them with keyboard shortcuts.

The project has two parts: a Python CLI that handles authentication and session configuration, and a C viewer that connects directly to Parsec hosts using the SDK.

## How it works

parsec-mux reads your existing Parsec login from the app's WebKit cache, so you don't need to sign in separately. It talks to the Parsec Kessel API to discover your hosts, then launches a native viewer built on the Parsec C SDK and SDL2.

The viewer creates a separate SDK instance for each configured session, each bound to its own UDP port. In single mode it connects to one host at a time. In grid mode it connects up to four hosts simultaneously using staggered connections to avoid NAT hole-punch collisions.

## Dependencies

- Python 3.10+
- Parsec (must be installed and logged in)
- SDL2 framework (included in viewer/ or install via brew)
- Parsec SDK v6.0 headers and dylib (included in viewer/sdk/, x86_64)
- macOS (uses Rosetta 2 for the x86_64 SDK on Apple Silicon)

## Setup

```
cd parsec-mux
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

You also need the SDL2 framework in the viewer directory. Download it from the SDL2 GitHub releases page (the macOS .dmg), copy SDL2.framework into viewer/.

For the Parsec SDK, you need libparsec.dylib in viewer/sdk/. The headers (parsec.h, parsec-dso.h) are already included. The dylib is not checked into git because of its size. You can find it in the parsec-sdk mirrors on GitHub (tantum101/Parsec, branch master, sdk/macos/libparsec.dylib).

Build the viewer:

```
cd viewer
make
```

Then add the CLI to your path. The install script creates a wrapper at ~/.local/bin/pmux that points to the venv:

```
# already done if you followed the setup, but manually:
ln -sf /path/to/parsec-mux/.venv/bin/parsec-mux ~/.local/bin/pmux
```

## Usage

Run pmux with no arguments to launch the viewer. On first run it will ask you to pick which hosts to add.

```
pmux              launch the viewer (or first-time setup)
pmux setup        open the TUI to manage favorites and slots
pmux list         show all available hosts and their status
pmux add          add more hosts interactively
pmux remove NAME  remove a host from favorites
pmux reset        clear all favorites
pmux auth         re-authenticate with Parsec
```

## Viewer keybindings

All keybindings use the Command key.

```
Cmd+1 through Cmd+7    switch to session by slot number
Cmd+8                  previous session
Cmd+9                  next session
Cmd+`                  disconnect current session
Cmd+R                  reconnect current session
Cmd+G                  toggle grid mode (1x1 / 2x2)
Cmd+F                  fullscreen the focused quadrant (exit grid)
Cmd+Q                  quit
```

In grid mode, click on a quadrant to focus it. Keyboard and mouse input go to the focused session. Audio also follows focus.

## How sessions work

Each session is a favorite with a slot number (1-9). Favorites are stored in ~/.parsec-mux/favorites.json. The viewer reads a generated TSV file with slot, peer_id, and nickname per line.

In single mode, switching sessions disconnects the current one and connects the new one. The SDK instance stays initialized so reconnection is fast (STUN info is cached).

In grid mode, up to four sessions connect simultaneously. Each SDK instance binds to a different port (13000, 14000, 15000, 16000) to prevent NAT conflicts. Connections are staggered with a 2 second delay between each to avoid hole-punch collisions when hosts share the same public IP.

## Connection health

The viewer monitors connection quality and shows it in the title bar. Latency under 60ms is normal, 60-150ms is degraded, above 150ms is bad. If the network fails repeatedly the session is marked as lost and the viewer will try to reconnect automatically with exponential backoff.

## Project structure

```
parsec_mux/          Python package
  __main__.py        CLI entry point
  api.py             Parsec Kessel API client
  auth.py            session extraction from Parsec's WebKit cache
  config.py          favorites and settings management
  sessions.py        legacy process-based session manager (used by TUI)
  tui.py             Textual TUI for setup

viewer/              C viewer
  viewer.c           main viewer source (~890 lines)
  sdk/               Parsec SDK headers (parsec.h, parsec-dso.h)
  Makefile           builds pmux-viewer as x86_64
```

## Known limitations

- The Parsec SDK is x86_64 only. On Apple Silicon the viewer runs under Rosetta 2. Video decoding and rendering are still hardware accelerated.
- Mouse input may not work correctly depending on the HiDPI scaling configuration. The viewer scales coordinates by the display scale factor but this has not been tested on all setups.
- Grid mode can only show 4 sessions. The 2x2 layout is hardcoded.
- The parsec:// URL scheme approach for controlling the Parsec app did not work reliably for session switching, which is why the custom viewer was built.
