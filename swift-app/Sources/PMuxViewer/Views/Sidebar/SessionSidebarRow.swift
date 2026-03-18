/// SessionSidebarRow — Favorite host card with star toggle, slot assignment, hover effects.

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
            StatusDot(state: dotState, size: PMuxSpacing.statusDotLarge)

            VStack(alignment: .leading, spacing: 3) {
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

            // Star + action buttons
            if isHovered || session.isConnecting {
                HStack(spacing: 4) {
                    if session.isFavorite {
                        Button { onToggleFavorite?() } label: {
                            Image(systemName: "star.fill")
                                .font(.system(size: 11))
                                .foregroundColor(PMuxColors.accent)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from Favorites")
                    }

                    if session.isConnecting {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16, height: 16)
                    } else {
                        Button {
                            session.isConnected ? onDisconnect?() : onConnect?()
                        } label: {
                            Image(systemName: session.isConnected ? "xmark" : "bolt.fill")
                                .font(.system(size: 10))
                                .foregroundColor(PMuxColors.Text.secondary)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(PMuxColors.BG.elevated))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity)
            } else if session.isFavorite {
                // Show subtle star when not hovered
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundColor(PMuxColors.accent.opacity(0.4))
            }
        }
        .padding(.horizontal, PMuxSpacing.cardPadding)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: PMuxSpacing.cardRadius, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(alignment: .leading) {
            if isActive {
                RoundedRectangle(cornerRadius: 2)
                    .fill(PMuxColors.accent)
                    .frame(width: 3)
                    .padding(.vertical, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: isActive)
        .contextMenu {
            if session.isConnected {
                Button("Disconnect") { onDisconnect?() }
            } else {
                Button("Connect") { onConnect?() }
            }

            Divider()

            // Slot assignment submenu
            Menu("Assign Slot") {
                ForEach(1..<10) { slot in
                    Button("F\(slot)") { onAssignSlot?(slot) }
                }
            }

            Divider()

            if session.isFavorite {
                Button("Remove from Favorites") { onToggleFavorite?() }
            }
        }
    }

    private var cardBackground: Color {
        if isActive { return PMuxColors.accent.opacity(0.15) }
        if isHovered { return PMuxColors.BG.elevated }
        return Color.clear
    }

    private var dotState: StatusDot.StatusDotState {
        if session.isConnecting { return .connecting }
        if !session.isConnected { return .offline }
        return session.health.dotState
    }
}
