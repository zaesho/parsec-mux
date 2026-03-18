/// HostBrowserRow — Row for non-favorite hosts from the Parsec API.
/// Shows online/offline status, star button, connect button.

import SwiftUI

struct HostBrowserRow: View {
    let host: ParsecHost
    let onStar: () -> Void
    let onConnect: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Online/offline dot
            StatusDot(
                state: host.online ? .ok : .offline,
                size: PMuxSpacing.statusDotLarge
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(host.name)
                    .font(PMuxFonts.body)
                    .foregroundColor(host.online ? PMuxColors.Text.primary : PMuxColors.Text.tertiary)
                    .lineLimit(1)

                if !host.userName.isEmpty {
                    Text(host.userName)
                        .font(PMuxFonts.metricSmall)
                        .foregroundColor(PMuxColors.Text.tertiary)
                }
            }

            Spacer()

            if isHovered || !host.online {
                HStack(spacing: 6) {
                    // Star button
                    Button { onStar() } label: {
                        Image(systemName: "star")
                            .font(.system(size: 11))
                            .foregroundColor(PMuxColors.Text.tertiary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Add to Favorites")

                    // Connect button (only if online)
                    if host.online {
                        Button { onConnect() } label: {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10))
                                .foregroundColor(PMuxColors.accent)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(PMuxColors.accent.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                        .help("Connect")
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, PMuxSpacing.cardPadding)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: PMuxSpacing.cardRadius, style: .continuous)
                .fill(isHovered ? PMuxColors.BG.elevated : Color.clear)
        )
        .opacity(host.online ? 1.0 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture {
            if host.online { onConnect() }
        }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .contextMenu {
            if host.online {
                Button("Connect") { onConnect() }
            }
            Button("Add to Favorites") { onStar() }
        }
    }
}
