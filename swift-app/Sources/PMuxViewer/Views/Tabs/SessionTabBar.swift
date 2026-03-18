/// SessionTabBar — Always-visible themed tab strip for connected sessions.
/// Includes sidebar toggle button when sidebar is collapsed.

import SwiftUI

struct SessionTabBar: View {
    @Environment(AppState.self) private var appState
    @Environment(SessionManager.self) private var sessionManager

    var showSidebarToggle: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar expand button when collapsed
            if showSidebarToggle {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.sidebarVisible = true
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12))
                        .foregroundColor(PMuxColors.Text.tertiary)
                        .frame(width: 36, height: PMuxSpacing.tabBarHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show sidebar (⌘⇧S)")

                Rectangle()
                    .fill(PMuxColors.Border.subtle)
                    .frame(width: 1, height: 20)
            }

            // Session tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(appState.sessions.enumerated()), id: \.element.id) { index, session in
                        if session.isConnected || session.isConnecting {
                            SessionTab(
                                session: session,
                                isActive: index == appState.activeSessionIndex,
                                onSelect: {
                                    sessionManager.switchToSession(index: index)
                                },
                                onClose: {
                                    sessionManager.disconnectSession(index: index)
                                }
                            )
                        }
                    }

                    if appState.connectedSessions.isEmpty {
                        Text("No active sessions")
                            .font(PMuxFonts.caption)
                            .foregroundColor(PMuxColors.Text.tertiary)
                            .padding(.horizontal, 14)
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(height: PMuxSpacing.tabBarHeight)
        .background(PMuxColors.BG.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PMuxColors.Border.subtle)
                .frame(height: 1)
        }
    }
}
