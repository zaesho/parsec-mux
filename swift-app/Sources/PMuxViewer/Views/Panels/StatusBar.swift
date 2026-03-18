/// StatusBar — Bottom bar with segmented metrics.

import SwiftUI

struct StatusBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 0) {
            if let session = appState.activeSession {
                // Status
                HStack(spacing: 5) {
                    Image(systemName: statusIcon(session))
                        .font(.system(size: 9))
                        .foregroundColor(statusColor(session))
                    Text(statusLabel(session))
                        .font(PMuxFonts.caption)
                        .foregroundColor(PMuxColors.Text.secondary)
                }
                .padding(.horizontal, 12)

                if session.isConnected {
                    PMuxDivider(vertical: true, height: 14)

                    HStack(spacing: 4) {
                        Image(systemName: "wifi")
                            .font(.system(size: 8))
                            .foregroundColor(PMuxColors.Text.tertiary)
                        Text("\(Int(session.latency))ms")
                            .font(PMuxFonts.metric)
                            .foregroundColor(session.health.color)
                    }
                    .padding(.horizontal, 10)

                    PMuxDivider(vertical: true, height: 14)

                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8))
                            .foregroundColor(PMuxColors.Text.tertiary)
                        Text(String(format: "%.1f Mbps", session.bitrate))
                            .font(PMuxFonts.metric)
                            .foregroundColor(PMuxColors.Text.accent)
                    }
                    .padding(.horizontal, 10)

                    PMuxDivider(vertical: true, height: 14)

                    HStack(spacing: 4) {
                        Image(systemName: "film")
                            .font(.system(size: 8))
                            .foregroundColor(PMuxColors.Text.tertiary)
                        Text(codecLabel(session.quality))
                            .font(PMuxFonts.metric)
                            .foregroundColor(PMuxColors.Text.tertiary)
                    }
                    .padding(.horizontal, 10)
                }
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "display")
                        .font(.system(size: 9))
                        .foregroundColor(PMuxColors.Text.tertiary)
                    Text("No session")
                        .font(PMuxFonts.caption)
                        .foregroundColor(PMuxColors.Text.tertiary)
                }
                .padding(.horizontal, 12)
            }

            Spacer()

            HStack(spacing: 5) {
                Image(systemName: appState.viewMode == .grid ? "square.grid.2x2" : "rectangle")
                    .font(.system(size: 9))
                    .foregroundColor(PMuxColors.Text.tertiary)
                Text(appState.viewMode == .grid ? "Grid" : "Single")
                    .font(PMuxFonts.caption)
                    .foregroundColor(PMuxColors.Text.tertiary)
            }
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

    private func statusIcon(_ session: SessionModel) -> String {
        if session.isConnecting { return "arrow.triangle.2.circlepath" }
        if !session.isConnected { return "bolt.slash" }
        switch session.health {
        case .ok:       return "checkmark.circle.fill"
        case .degraded: return "exclamationmark.circle"
        case .bad:      return "exclamationmark.triangle"
        case .lost:     return "xmark.circle"
        }
    }

    private func statusColor(_ session: SessionModel) -> Color {
        if session.isConnecting { return PMuxColors.Status.degraded }
        if !session.isConnected { return PMuxColors.Status.offline }
        return session.health.color
    }

    private func statusLabel(_ session: SessionModel) -> String {
        if session.isConnecting { return "Connecting..." }
        if !session.isConnected { return "Disconnected" }
        return session.nickname
    }

    private func codecLabel(_ q: ParsecClient.Quality) -> String {
        let codec = q.h265 ? "H.265" : "H.264"
        let color = q.color444 ? "4:4:4" : "4:2:0"
        let decoder = q.decoderIndex == 1 ? "HW" : "SW"
        return "\(codec) \(color) \(decoder)"
    }
}
