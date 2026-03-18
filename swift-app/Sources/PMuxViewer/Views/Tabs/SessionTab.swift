/// SessionTab — Individual tab with accent indicator and hover states.

import SwiftUI

struct SessionTab: View {
    let session: SessionModel
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: statusIcon)
                    .font(.system(size: 8))
                    .foregroundColor(statusColor)

                Text(session.nickname)
                    .font(isActive ? PMuxFonts.tabActive : PMuxFonts.tabInactive)
                    .foregroundColor(isActive ? PMuxColors.Text.primary : PMuxColors.Text.secondary)
                    .lineLimit(1)

                if isHovered || isActive {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(PMuxColors.Text.tertiary)
                            .frame(width: 14, height: 14)
                            .background(
                                Circle().fill(isHovered ? PMuxColors.BG.elevated : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tabBackground)
            )

            // Active accent bar
            Capsule()
                .fill(isActive ? PMuxColors.accent : Color.clear)
                .frame(height: 2)
                .frame(width: 24)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }

    private var tabBackground: Color {
        if isActive { return PMuxColors.accentMuted }
        if isHovered { return PMuxColors.BG.elevated }
        return Color.clear
    }

    private var statusIcon: String {
        if session.isConnecting { return "arrow.triangle.2.circlepath" }
        switch session.health {
        case .ok:       return "circle.fill"
        case .degraded: return "exclamationmark.circle.fill"
        case .bad:      return "exclamationmark.triangle.fill"
        case .lost:     return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        if session.isConnecting { return PMuxColors.Status.degraded }
        return session.health.color
    }
}
