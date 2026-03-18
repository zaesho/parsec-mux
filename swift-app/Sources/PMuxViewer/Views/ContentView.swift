/// ContentView — Root view with adaptive grid and drag-to-add.

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(SessionManager.self) private var sessionManager
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if appState.sidebarVisible {
                    SessionSidebar()
                        .frame(width: PMuxSpacing.sidebarWidth)
                        .transition(.move(edge: .leading))

                    Rectangle()
                        .fill(PMuxColors.Border.subtle)
                        .frame(width: 1)
                }

                VStack(spacing: 0) {
                    SessionTabBar(showSidebarToggle: !appState.sidebarVisible)

                    renderArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            if isDropTargeted {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(PMuxColors.accent, lineWidth: 2)
                                    .background(PMuxColors.accent.opacity(0.05))
                                    .padding(4)
                                    .allowsHitTesting(false)
                            }
                        }
                        .dropDestination(for: String.self) { items, _ in
                            for peerID in items {
                                sessionManager.addHostToGrid(peerID: peerID)
                            }
                            return !items.isEmpty
                        } isTargeted: { targeted in
                            isDropTargeted = targeted
                        }

                    StatusBar()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(PMuxColors.BG.base)
            .animation(.easeInOut(duration: 0.25), value: appState.sidebarVisible)

            // Overlays
            VStack {
                HStack {
                    DebugOverlay()
                    Spacer()
                }
                Spacer()
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    AudioMixerPanel()
                        .padding(12)
                }
            }

            QualityPicker()
            SettingsPane()
        }
        .onAppear {
            if !appState.isBootstrapped {
                sessionManager.bootstrap()
                sessionManager.startConnections()
            }
        }
    }

    // MARK: - Render Area

    @ViewBuilder
    private var renderArea: some View {
        if appState.viewMode == .grid && appState.gridIndices.count > 1 {
            gridView
        } else if appState.gridIndices.count == 1, let idx = appState.gridIndices.first {
            // Single pane in grid mode — show it full
            gridCell(idx)
        } else {
            singleView
        }
    }

    @ViewBuilder
    private var singleView: some View {
        let idx = appState.activeSessionIndex
        if idx >= 0 && idx < appState.sessions.count {
            let session = appState.sessions[idx]
            ParsecRenderView(
                sessionIndex: idx,
                client: session.client,
                metalContext: sessionManager.metalContext,
                isActive: true,
                isRelativeMode: session.isRelativeMode,
                inputDelegate: sessionManager,
                onInputViewReady: { inputView in
                    sessionManager.activeInputView = inputView
                }
            )
        } else {
            placeholderView
        }
    }

    @ViewBuilder
    private var gridView: some View {
        let indices = appState.gridIndices
        let sizing = appState.gridMode.layout(for: indices.count)
        let gap = PMuxSpacing.gridGap

        VStack(spacing: gap) {
            ForEach(0..<sizing.rows, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<sizing.cols, id: \.self) { col in
                        let cellIndex = row * sizing.cols + col
                        if cellIndex < indices.count {
                            gridCell(indices[cellIndex])
                        } else {
                            // Empty slot
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(PMuxColors.BG.surface.opacity(0.2))
                                .overlay(
                                    VStack(spacing: 4) {
                                        Image(systemName: "plus.circle")
                                            .font(.system(size: 18, weight: .ultraLight))
                                        Text("Drag host here")
                                            .font(PMuxFonts.metricSmall)
                                    }
                                    .foregroundColor(PMuxColors.Text.tertiary.opacity(0.3))
                                )
                        }
                    }
                }
            }
        }
        .padding(gap)
    }

    @ViewBuilder
    private func gridCell(_ idx: Int) -> some View {
        if idx >= 0 && idx < appState.sessions.count {
            let session = appState.sessions[idx]
            let isActive = idx == appState.activeSessionIndex

            ParsecRenderView(
                sessionIndex: idx,
                client: session.client,
                metalContext: sessionManager.metalContext,
                isActive: isActive,
                isRelativeMode: session.isRelativeMode,
                inputDelegate: sessionManager,
                onInputViewReady: { inputView in
                    if idx == appState.activeSessionIndex {
                        sessionManager.activeInputView = inputView
                    }
                },
                onPaneClicked: {
                    if idx != appState.activeSessionIndex {
                        sessionManager.switchToSession(index: idx)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(isActive ? PMuxColors.accent : Color.clear, lineWidth: 2)
            )
            .opacity(isActive ? 1.0 : 0.85)
            .contextMenu {
                Button {
                    sessionManager.removeFromGrid(sessionIndex: idx)
                } label: {
                    Label("Remove from Grid", systemImage: "minus.circle")
                }
                Button {
                    sessionManager.disconnectSession(index: idx)
                } label: {
                    Label("Disconnect", systemImage: "bolt.slash")
                }
            }
        } else {
            Rectangle()
                .fill(PMuxColors.BG.base)
        }
    }

    private var placeholderView: some View {
        VStack(spacing: 16) {
            Image(systemName: "display")
                .font(.system(size: 48, weight: .thin))
                .foregroundColor(PMuxColors.Text.tertiary)
            Text("No session selected")
                .font(PMuxFonts.body)
                .foregroundColor(PMuxColors.Text.tertiary)
            Text("Drag a host here or press F1–F8")
                .font(PMuxFonts.caption)
                .foregroundColor(PMuxColors.Text.tertiary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PMuxColors.BG.base)
    }
}
