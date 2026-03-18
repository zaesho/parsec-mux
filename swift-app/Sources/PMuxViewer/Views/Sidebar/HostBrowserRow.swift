/// HostBrowserRow — Row for non-favorite hosts from the Parsec API.

import SwiftUI

struct HostBrowserRow: View {
    let host: ParsecHost
    let onStar: () -> Void
    let onConnect: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: host.online ? "desktopcomputer" : "desktopcomputer")
                .font(.system(size: 11))
                .foregroundColor(host.online ? PMuxColors.Status.ok : PMuxColors.Status.offline)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .font(PMuxFonts.body)
                    .foregroundColor(host.online ? PMuxColors.Text.primary : PMuxColors.Text.tertiary)
                    .lineLimit(1)

                if !host.userName.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "person")
                            .font(.system(size: 8))
                        Text(host.userName)
                            .font(PMuxFonts.metricSmall)
                    }
                    .foregroundColor(PMuxColors.Text.tertiary)
                }
            }

            Spacer()

            if isHovered {
                HStack(spacing: 6) {
                    Button { onStar() } label: {
                        Image(systemName: "star")
                            .font(.system(size: 10))
                            .foregroundColor(PMuxColors.Status.degraded)
                    }
                    .buttonStyle(.plain)
                    .help("Add to Favorites")

                    if host.online {
                        Button { onConnect() } label: {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10))
                                .foregroundColor(PMuxColors.accent)
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
        .opacity(host.online ? 1.0 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture {
            if host.online { onConnect() }
        }
        .onHover { isHovered = $0 }
        .draggable(host.peerID as String)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .contextMenu {
            if host.online {
                Button { onConnect() } label: {
                    Label("Connect", systemImage: "bolt.fill")
                }
            }
            Button { onStar() } label: {
                Label("Add to Favorites", systemImage: "star")
            }
        }
    }
}
