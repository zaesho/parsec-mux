/// ContentView — Root view with custom HStack layout (no NavigationSplitView).
/// Dark themed with sidebar, tab bar, render area, and status bar.

import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(SessionManager.self) private var sessionManager

    var body: some View {
        ZStack {
            // Main layout
            HStack(spacing: 0) {
                // Sidebar
                if appState.sidebarVisible {
                    SessionSidebar()
                        .frame(width: PMuxSpacing.sidebarWidth)
                        .transition(.move(edge: .leading))

                    Rectangle()
                        .fill(PMuxColors.Border.subtle)
                        .frame(width: 1)
                }

                // Content area
                VStack(spacing: 0) {
                    // Draggable title bar area + tab bar combined
                    SessionTabBar()

                    renderArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

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

            // Audio mixer (bottom-right)
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
        let gap = PMuxSpacing.gridGap

        VStack(spacing: gap) {
            // Top row
            HStack(spacing: gap) {
                if indices.count > 0 { gridCell(indices[0]) }
                if indices.count > 1 { gridCell(indices[1]) }
            }
            // Bottom row
            HStack(spacing: gap) {
                if indices.count > 2 { gridCell(indices[2]) }
                if indices.count > 3 { gridCell(indices[3]) }
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
                inputDelegate: sessionManager,
                onInputViewReady: { inputView in
                    if isActive {
                        sessionManager.activeInputView = inputView
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(isActive ? PMuxColors.accent : Color.clear, lineWidth: 2)
            )
            .opacity(isActive ? 1.0 : 0.85)
            .onTapGesture {
                sessionManager.switchToSession(index: idx)
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
            Text("Press F1–F8 to connect")
                .font(PMuxFonts.caption)
                .foregroundColor(PMuxColors.Text.tertiary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PMuxColors.BG.base)
    }
}
