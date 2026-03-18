# parsec-mux

A multi-session Parsec remote desktop client with a Termius-inspired dark UI. Browse all your Parsec hosts, manage favorites, and connect to up to 9 sessions simultaneously with GPU-accelerated Metal rendering, audio mixing, and clipboard passthrough.

The project has three parts: a Python CLI for authentication and host management, a legacy C viewer (SDL2), and **pmux** — a native SwiftUI + Metal macOS app that replaces the C viewer with a modern interface.

## pmux (SwiftUI viewer)

The primary viewer. A hybrid SwiftUI + Metal app with:

- **Live host browser** — fetches all available hosts from the Parsec Kessel API
- **Favorites management** — star hosts, assign F-key slots (F1–F9), persist to favorites.json
- **Multi-session rendering** — one MTKView per session, GPU NV12→RGB conversion
- **Grid mode** — 2x2 layout with per-pane Metal rendering and local mouse coordinates
- **Audio mixer** — per-session volume control with AfV (audio follows video), grid mix, manual, and all modes
- **Clipboard passthrough** — bidirectional text clipboard between local and remote
- **Health monitoring** — live latency, bitrate, codec info in status bar and debug overlay
- **Dark themed UI** — custom color system (#13141f base), no stock macOS controls
- **Keyboard shortcuts** — F-keys for slots, Cmd+Shift combos for all actions

### Architecture

```
SwiftUI App (@main) + NSApplicationDelegateAdaptor
  ├── AppState (@Observable) — single source of truth
  ├── SessionManager — dynamic client pool, connections, input, audio, clipboard
  ├── MetalContext — shared device, pipelines, shaders
  └── ContentView
       ├── Sidebar (custom dark, two sections: Favorites + Available)
       ├── Tab Bar (connected sessions)
       ├── Render Area
       │    ├── Single: ParsecRenderView(session)
       │    └── Grid: VStack/HStack { ParsecRenderView × 4 }
       ├── Status Bar (segmented metrics)
       └── Overlays (debug, quality picker, settings, audio mixer)

ParsecRenderView (NSViewRepresentable)
  └── RenderContainerView (NSView)
       ├── SingleStreamMTKView — polls ONE stream, renders ONE quad
       └── ParsecInputView — keyboard/mouse capture
```

### Build

Requires macOS 14+ and Xcode Command Line Tools.

```bash
cd swift-app
swift build -c release
bash build.sh          # produces build/pmux.app
open build/pmux.app
```

The Parsec SDK dylibs (ARM64 + x86_64) are bundled in `Sources/CParsecBridge/include/`.

### File structure

```
swift-app/Sources/PMuxViewer/
  App/
    PMuxApp.swift            SwiftUI @main + NSApplicationDelegateAdaptor
    AppState.swift           @Observable state (sessions, hosts, settings)
    SessionManager.swift     Connections, input, audio, clipboard, health
    MetalContext.swift        Shared Metal device + pipelines + shaders
  Audio/
    AudioMixer.swift         AVAudioEngine multi-session mixer
    AudioRingBuffer.swift    Lock-free SPSC ring buffer (int16→float32)
  Model/
    ParsecAPIClient.swift    Kessel REST API (host discovery)
    FavoritesManager.swift   CRUD for ~/.parsec-mux/favorites.json
    ParsecClient.swift       Swift wrapper around C bridge
    SessionAuth.swift        Session token extraction
    StreamFrame.swift        Per-stream NV12/RGBA frame data
  Theme/
    PMuxTheme.swift          Colors, fonts, spacing constants
    PMuxComponents.swift     StatusDot, Pill, Divider, SegmentedControl
  Views/
    ContentView.swift        Root layout (sidebar + tabs + render + status)
    Sidebar/
      SessionSidebar.swift   Two-section host browser with search
      SessionSidebarRow.swift  Favorite host card with hover/star/slot
      HostBrowserRow.swift   Available host row with connect/star
    Tabs/
      SessionTabBar.swift    Connected session tab strip
      SessionTab.swift       Individual tab with accent indicator
    Renderer/
      ParsecRenderView.swift   NSViewRepresentable bridge
      SingleStreamMTKView.swift  MTKView for one stream
      ParsecInputView.swift  Keyboard/mouse/combo capture
    Panels/
      StatusBar.swift        Bottom metrics bar
      DebugOverlay.swift     Two-column debug info
      QualityPicker.swift    Resolution/codec/color/decoder modal
      SettingsPane.swift     App settings modal
      AudioMixerPanel.swift  Per-session volume + mix mode control
```

### Keyboard shortcuts

```
F1–F8              Switch to session by slot
Cmd+Shift+G        Toggle grid mode
Cmd+Shift+S        Toggle sidebar
Cmd+Shift+D        Toggle debug overlay
Cmd+Shift+Q        Quality settings
Cmd+Shift+8/9      Previous / next session
Cmd+Shift+R        Reconnect
Cmd+Shift+`        Disconnect
Cmd+Shift+F        Force single mode
Cmd+Shift+Arrows   Navigate grid
```

## Python CLI

Handles authentication and host management. Still works standalone or alongside the SwiftUI viewer.

```bash
cd parsec-mux
python3 -m venv .venv && source .venv/bin/activate
pip install -e .

pmux              launch the viewer (or first-time setup)
pmux setup        open TUI to manage favorites
pmux list         show all available hosts
pmux add          add hosts interactively
pmux remove NAME  remove a host from favorites
pmux auth         re-authenticate with Parsec
```

## How sessions work

Each favorite has a slot (1–9) and is stored in `~/.parsec-mux/favorites.json`. The SwiftUI viewer reads this directly and also fetches live host status from the Parsec Kessel API.

Sessions use a dynamic client pool — ParsecClient instances are allocated on demand (up to 9, ports 13000–13008). Favorites auto-connect on launch with staggered timing. Non-favorite hosts can be connected ad-hoc from the sidebar.

In grid mode, each pane has its own MTKView with local mouse coordinates — no quadrant remapping needed. `setDimensions` matches each pane's pixel size automatically.

## Audio

The Parsec SDK delivers stereo 16-bit PCM at 48kHz per session. pmux uses AVAudioEngine with one AVAudioSourceNode per session, connected through per-session mixer nodes for individual volume control.

Mix modes:
- **AfV** — audio follows the active session
- **Grid** — all grid-visible sessions mixed
- **Manual** — per-session volume sliders
- **All** — every connected session at full volume

Audio is polled at 100Hz and flows through a lock-free ring buffer to the audio render thread.

## Known limitations

- Image and file clipboard not supported (SDK only handles text via user data id 7)
- USB device passthrough not available (requires separate software like VirtualHere)
- Audio may have compatibility issues under Rosetta 2
- Grid mode limited to 4 sessions (2x2 layout)
- `getBuffer`/`freeBuffer` for cursor images may crash under Rosetta 2 (clipboard works on native ARM64)
