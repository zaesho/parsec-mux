/// PMuxComponents — Reusable themed UI components.

import SwiftUI

// MARK: - Status Dot

struct StatusDot: View {
    let state: StatusDotState
    let size: CGFloat

    enum StatusDotState {
        case ok, degraded, bad, lost, connecting, offline

        var color: Color {
            switch self {
            case .ok:         return PMuxColors.Status.ok
            case .degraded:   return PMuxColors.Status.degraded
            case .bad:        return PMuxColors.Status.bad
            case .lost:       return PMuxColors.Status.lost
            case .connecting: return PMuxColors.Status.degraded
            case .offline:    return PMuxColors.Status.offline
            }
        }
    }

    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: size, height: size)
            .scaleEffect(state == .connecting && isPulsing ? 1.3 : 1.0)
            .opacity(state == .connecting && isPulsing ? 0.6 : 1.0)
            .animation(
                state == .connecting
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
            .onAppear {
                if state == .connecting { isPulsing = true }
            }
            .onChange(of: state == .connecting) { _, isConnecting in
                isPulsing = isConnecting
            }
    }
}

// MARK: - Pill Badge

struct PMuxPill: View {
    let text: String
    var bg: Color = PMuxColors.BG.elevated
    var fg: Color = PMuxColors.Text.tertiary

    var body: some View {
        SwiftUI.Text(text)
            .font(PMuxFonts.pill)
            .foregroundColor(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: PMuxSpacing.pillRadius, style: .continuous)
                    .fill(bg)
            )
    }
}

// MARK: - Divider

struct PMuxDivider: View {
    var vertical: Bool = false
    var height: CGFloat = 14

    var body: some View {
        if vertical {
            Rectangle()
                .fill(PMuxColors.Border.subtle)
                .frame(width: 1, height: height)
        } else {
            Rectangle()
                .fill(PMuxColors.Border.subtle)
                .frame(height: 1)
        }
    }
}

// MARK: - Button Style

enum PMuxButtonVariant {
    case secondary, accent
}

struct PMuxButtonStyle: ButtonStyle {
    let variant: PMuxButtonVariant

    func makeBody(configuration: Configuration) -> some View {
        PMuxButtonBody(variant: variant, configuration: configuration)
    }
}

private struct PMuxButtonBody: View {
    let variant: PMuxButtonVariant
    let configuration: ButtonStyle.Configuration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(PMuxFonts.bodyBold)
            .foregroundColor(variant == .accent ? .white : PMuxColors.Text.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: PMuxSpacing.cardRadius, style: .continuous)
                    .fill(bgColor(pressed: configuration.isPressed))
            )
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private func bgColor(pressed: Bool) -> Color {
        if pressed { return variant == .accent ? PMuxColors.accent.opacity(0.8) : PMuxColors.BG.elevated }
        if isHovered { return variant == .accent ? PMuxColors.accentHover : PMuxColors.BG.elevated }
        return variant == .accent ? PMuxColors.accent : PMuxColors.BG.surface
    }
}

// MARK: - Segmented Control

struct PMuxSegmentedControl: View {
    let items: [String]
    @Binding var selectedIndex: Int

    @Namespace private var selectionNS

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, _ in
                SwiftUI.Text(items[i])
                    .font(PMuxFonts.captionBold)
                    .foregroundColor(i == selectedIndex ? .white : PMuxColors.Text.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if i == selectedIndex {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(PMuxColors.accent)
                                .matchedGeometryEffect(id: "seg", in: selectionNS)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedIndex = i
                        }
                    }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(PMuxColors.BG.surface)
        )
        .frame(height: 30)
    }
}
