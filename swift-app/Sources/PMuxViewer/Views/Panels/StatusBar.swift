/// StatusBar — Bottom bar with segmented metrics and vertical dividers.

import SwiftUI

struct StatusBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 0) {
            if let session = appState.activeSession {
                // Status
                HStack(spacing: 6) {
                    StatusDot(state: dotState(session), size: PMuxSpacing.statusDotSmall)
                    Text(session.isConnected ? "Connected" : session.isConnecting ? "Connecting..." : "Disconnected")
                        .font(PMuxFonts.caption)
                        .foregroundColor(PMuxColors.Text.secondary)
                }
                .padding(.horizontal, 12)

                if session.isConnected {
                    PMuxDivider(vertical: true, height: 14)

                    // Latency
                    HStack(spacing: 4) {
                        Image(systemName: "network")
                            .font(.system(size: 9))
                            .foregroundColor(PMuxColors.Text.tertiary)
                        Text("\(Int(session.latency))ms")
                            .font(PMuxFonts.metric)
                            .foregroundColor(session.health.color)
                    }
                    .padding(.horizontal, 12)

                    PMuxDivider(vertical: true, height: 14)

                    // Bitrate
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 9))
                            .foregroundColor(PMuxColors.Text.tertiary)
                        Text(String(format: "%.1f Mbps", session.bitrate))
                            .font(PMuxFonts.metric)
                            .foregroundColor(PMuxColors.Text.accent)
                    }
                    .padding(.horizontal, 12)

                    PMuxDivider(vertical: true, height: 14)

                    // Codec
                    Text(codecLabel(session.quality))
                        .font(PMuxFonts.metric)
                        .foregroundColor(PMuxColors.Text.tertiary)
                        .padding(.horizontal, 12)
                }
            } else {
                Text("No session")
                    .font(PMuxFonts.caption)
                    .foregroundColor(PMuxColors.Text.tertiary)
                    .padding(.horizontal, 12)
            }

            Spacer()

            // Mode
            Text(appState.viewMode == .grid ? "Grid" : "Single")
                .font(PMuxFonts.caption)
                .foregroundColor(PMuxColors.Text.tertiary)
                .padding(.horizontal, 12)
        }
        .frame(height: PMuxSpacing.statusBarHeight)
        .background(PMuxColors.BG.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PMuxColors.Border.subtle)
                .frame(height: 1)
        }
    }

    private func dotState(_ session: SessionModel) -> StatusDot.StatusDotState {
        if session.isConnecting { return .connecting }
        if !session.isConnected { return .offline }
        return session.health.dotState
    }

    private func codecLabel(_ q: ParsecClient.Quality) -> String {
        let codec = q.h265 ? "H.265" : "H.264"
        let color = q.color444 ? "4:4:4" : "4:2:0"
        let decoder = q.decoderIndex == 1 ? "HW" : "SW"
        return "\(codec) \(color) \(decoder)"
    }
}
