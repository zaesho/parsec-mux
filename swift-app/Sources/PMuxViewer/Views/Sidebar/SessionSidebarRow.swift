/// SessionSidebarRow — Favorite host card with context menu for per-host settings.

import SwiftUI

struct SessionSidebarRow: View {
    let session: SessionModel
    let isActive: Bool
    let onSelect: () -> Void
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onAssignSlot: ((Int) -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 10))
                .foregroundColor(statusColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.nickname)
                    .font(isActive ? PMuxFonts.bodyBold : PMuxFonts.body)
                    .foregroundColor(isActive ? PMuxColors.Text.primary : PMuxColors.Text.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if session.slot > 0 {
                        PMuxPill(text: "F\(session.slot)")
                    }
                    if session.isConnected && session.latency > 0 {
                        Text("\(Int(session.latency))ms")
                            .font(PMuxFonts.metricSmall)
                            .foregroundColor(session.health.color)
                    }
                }
            }

            Spacer()

            if isHovered {
                HStack(spacing: 4) {
                    if session.isFavorite {
                        Button { onToggleFavorite?() } label: {
                            Image(systemName: "star.slash.fill")
                                .font(.system(size: 10))
                                .foregroundColor(PMuxColors.Status.degraded)
                        }
                        .buttonStyle(.plain)
                    }

                    if session.isConnecting {
                        ProgressView()
                            .scaleEffect(0.4)
                            .frame(width: 14, height: 14)
                    } else {
                        Button {
                            session.isConnected ? onDisconnect?() : onConnect?()
                        } label: {
                            Image(systemName: session.isConnected ? "bolt.slash.fill" : "bolt.fill")
                                .font(.system(size: 10))
                                .foregroundColor(session.isConnected ? PMuxColors.Status.lost : PMuxColors.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, PMuxSpacing.cardPadding)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: PMuxSpacing.cardRadius, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(alignment: .leading) {
            if isActive {
                Capsule()
                    .fill(PMuxColors.accent)
                    .frame(width: 3, height: 18)
                    .padding(.leading, 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
        .draggable(session.id as String)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isActive)
        .contextMenu { contextMenuContent }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        // Connection
        if session.isConnected {
            Button { onDisconnect?() } label: {
                Label("Disconnect", systemImage: "bolt.slash")
            }
        } else {
            Button { onConnect?() } label: {
                Label("Connect", systemImage: "bolt.fill")
            }
        }

        Divider()

        // Quality: Codec
        Menu {
            Button { session.quality.h265 = false; reconnectIfNeeded() } label: {
                HStack {
                    Text("H.264")
                    if !session.quality.h265 { Image(systemName: "checkmark") }
                }
            }
            Button { session.quality.h265 = true; reconnectIfNeeded() } label: {
                HStack {
                    Text("H.265")
                    if session.quality.h265 { Image(systemName: "checkmark") }
                }
            }
        } label: {
            Label("Codec: \(session.quality.h265 ? "H.265" : "H.264")", systemImage: "film")
        }

        // Quality: Color
        Menu {
            Button { session.quality.color444 = false; reconnectIfNeeded() } label: {
                HStack {
                    Text("4:2:0")
                    if !session.quality.color444 { Image(systemName: "checkmark") }
                }
            }
            Button { session.quality.color444 = true; reconnectIfNeeded() } label: {
                HStack {
                    Text("4:4:4")
                    if session.quality.color444 { Image(systemName: "checkmark") }
                }
            }
        } label: {
            Label("Color: \(session.quality.color444 ? "4:4:4" : "4:2:0")", systemImage: "paintpalette")
        }

        // Quality: Decoder
        Menu {
            Button { session.quality.decoderIndex = 0; reconnectIfNeeded() } label: {
                HStack {
                    Text("Software")
                    if session.quality.decoderIndex == 0 { Image(systemName: "checkmark") }
                }
            }
            Button { session.quality.decoderIndex = 1; reconnectIfNeeded() } label: {
                HStack {
                    Text("Hardware")
                    if session.quality.decoderIndex == 1 { Image(systemName: "checkmark") }
                }
            }
        } label: {
            Label("Decoder: \(session.quality.decoderIndex == 1 ? "HW" : "SW")", systemImage: "cpu")
        }

        // Quality: Resolution
        Menu {
            ForEach(resPresets.indices, id: \.self) { i in
                let preset = resPresets[i]
                Button {
                    session.quality.resX = preset.w
                    session.quality.resY = preset.h
                    reconnectIfNeeded()
                } label: {
                    HStack {
                        Text(preset.label)
                        if session.quality.resX == preset.w && session.quality.resY == preset.h {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            let current = resPresets.first { $0.w == session.quality.resX && $0.h == session.quality.resY }
            Label("Resolution: \(current?.label ?? "Native")", systemImage: "rectangle.arrowtriangle.2.outward")
        }

        Divider()

        // Slot assignment
        Menu {
            ForEach(1..<10, id: \.self) { slot in
                Button {
                    onAssignSlot?(slot)
                } label: {
                    HStack {
                        Text("F\(slot)")
                        if session.slot == slot { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            Label("Slot: F\(session.slot)", systemImage: "keyboard")
        }

        Divider()

        if session.isFavorite {
            Button(role: .destructive) { onToggleFavorite?() } label: {
                Label("Remove from Favorites", systemImage: "star.slash")
            }
        }
    }

    // MARK: - Helpers

    private func reconnectIfNeeded() {
        // Quality changes require reconnect to take effect
        if session.isConnected {
            onDisconnect?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                onConnect?()
            }
        }
    }

    private var cardBackground: Color {
        if isActive { return PMuxColors.accentMuted }
        if isHovered { return PMuxColors.BG.elevated }
        return Color.clear
    }

    private var statusIcon: String {
        if session.isConnecting { return "arrow.triangle.2.circlepath" }
        if !session.isConnected { return "circle" }
        switch session.health {
        case .ok:       return "checkmark.circle.fill"
        case .degraded: return "exclamationmark.circle.fill"
        case .bad:      return "exclamationmark.triangle.fill"
        case .lost:     return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        if session.isConnecting { return PMuxColors.Status.degraded }
        if !session.isConnected { return PMuxColors.Status.offline }
        return session.health.color
    }
}
