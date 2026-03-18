/// SessionTabBar — Always-visible themed tab strip for connected sessions.

import SwiftUI

struct SessionTabBar: View {
    @Environment(AppState.self) private var appState
    @Environment(SessionManager.self) private var sessionManager

    var body: some View {
        HStack(spacing: 0) {
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
        .frame(height: PMuxSpacing.tabBarHeight)
        .background(PMuxColors.BG.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PMuxColors.Border.subtle)
                .frame(height: 1)
        }
    }
}
