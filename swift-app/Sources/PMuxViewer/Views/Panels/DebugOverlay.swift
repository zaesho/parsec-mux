/// DebugOverlay — Two-column themed debug info overlay.

import SwiftUI

struct DebugOverlay: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.showDebug, let session = appState.activeSession, session.isConnected {
            VStack(alignment: .leading, spacing: 4) {
                metricRow(label: "Latency", value: "\(Int(session.latency))ms")
                metricRow(label: "Bitrate", value: String(format: "%.1f Mbps", session.bitrate))
                metricRow(label: "Encode", value: String(format: "%.1fms", session.encodeLatency))
                metricRow(label: "Decode", value: String(format: "%.1fms", session.decodeLatency))
                metricRow(label: "Queued", value: "\(session.queuedFrames)")
                metricRow(label: "Codec", value: session.quality.h265 ? "H.265" : "H.264")
                metricRow(label: "Color", value: session.quality.color444 ? "4:4:4" : "4:2:0")
                metricRow(label: "Decoder", value: session.quality.decoderIndex == 1 ? "HW" : "SW")
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: PMuxSpacing.cardRadius, style: .continuous)
                    .fill(PMuxColors.BG.raised.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PMuxSpacing.cardRadius, style: .continuous)
                    .stroke(PMuxColors.Border.subtle, lineWidth: 1)
            )
            .padding(12)
        }
    }

    private func metricRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(PMuxFonts.metric)
                .foregroundColor(PMuxColors.Text.accent)
                .frame(width: 60, alignment: .trailing)
            Text(value)
                .font(PMuxFonts.metric)
                .foregroundColor(PMuxColors.Text.primary)
        }
    }
}
