/// SessionTab — Individual tab with accent bottom bar, hover states, hover close button.

import SwiftUI

struct SessionTab: View {
    let session: SessionModel
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var isCloseHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StatusDot(state: dotState, size: PMuxSpacing.statusDotSmall)

                Text(session.nickname)
                    .font(isActive ? PMuxFonts.tabActive : PMuxFonts.tabInactive)
                    .foregroundColor(isActive ? PMuxColors.Text.primary : PMuxColors.Text.secondary)
                    .lineLimit(1)

                if isHovered || isActive {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(PMuxColors.Text.tertiary)
                            .frame(width: 16, height: 16)
                            .background(
                                Circle()
                                    .fill(isCloseHovered ? PMuxColors.BG.elevated : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { isCloseHovered = $0 }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tabBackground)
            )

            // Active accent bottom bar
            Rectangle()
                .fill(isActive ? PMuxColors.accent : Color.clear)
                .frame(height: 2)
                .cornerRadius(1)
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private var tabBackground: Color {
        if isActive { return PMuxColors.accent.opacity(0.12) }
        if isHovered { return PMuxColors.BG.elevated }
        return Color.clear
    }

    private var dotState: StatusDot.StatusDotState {
        if session.isConnecting { return .connecting }
        return session.health.dotState
    }
}
