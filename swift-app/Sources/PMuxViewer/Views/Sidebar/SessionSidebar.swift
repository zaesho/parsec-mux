/// SessionSidebar — Two-section sidebar with Favorites and Available hosts.

import SwiftUI

struct SessionSidebar: View {
    @Environment(AppState.self) private var appState
    @Environment(SessionManager.self) private var sessionManager

    var body: some View {
        VStack(spacing: 0) {
            // Title area
            HStack {
                Text("PMux")
                    .font(PMuxFonts.heading)
                    .foregroundColor(PMuxColors.Text.primary)

                Spacer()

                PMuxPill(
                    text: "\(connectedCount)/\(appState.sessions.count)",
                    bg: PMuxColors.BG.surface,
                    fg: PMuxColors.Text.secondary
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(PMuxColors.Text.tertiary)

                TextField("Search hosts...", text: Binding(
                    get: { appState.sidebarSearch },
                    set: { appState.sidebarSearch = $0 }
                ))
                .textFieldStyle(.plain)
                .font(PMuxFonts.body)
                .foregroundColor(PMuxColors.Text.primary)

                if !appState.sidebarSearch.isEmpty {
                    Button {
                        appState.sidebarSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(PMuxColors.Text.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(PMuxColors.BG.surface)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            PMuxDivider()

            // Scrollable content
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    // FAVORITES section
                    sectionHeader(title: "FAVORITES", count: appState.filteredFavorites.count)

                    if appState.filteredFavorites.isEmpty {
                        emptyFavorites
                    } else {
                        LazyVStack(spacing: 4) {
                            ForEach(appState.filteredFavorites) { session in
                                let index = appState.sessions.firstIndex(where: { $0.id == session.id }) ?? 0
                                SessionSidebarRow(
                                    session: session,
                                    isActive: index == appState.activeSessionIndex,
                                    onSelect: {
                                        sessionManager.switchToSession(index: index)
                                    },
                                    onConnect: {
                                        sessionManager.connectSession(index: index)
                                    },
                                    onDisconnect: {
                                        sessionManager.disconnectSession(index: index)
                                    },
                                    onToggleFavorite: {
                                        sessionManager.removeFromFavorites(peerID: session.id)
                                    },
                                    onAssignSlot: { slot in
                                        sessionManager.assignSlot(peerID: session.id, newSlot: slot)
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 8)
                    }

                    // AVAILABLE section
                    HStack {
                        sectionHeader(title: "AVAILABLE", count: appState.availableHosts.count)
                        Spacer()

                        if appState.isLoadingHosts {
                            ProgressView()
                                .scaleEffect(0.4)
                                .frame(width: 16, height: 16)
                                .padding(.trailing, 16)
                        } else {
                            Button {
                                Task { await sessionManager.fetchHosts() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10))
                                    .foregroundColor(PMuxColors.Text.tertiary)
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 16)
                            .help("Refresh hosts")
                        }
                    }
                    .padding(.top, 8)

                    if let error = appState.hostLoadError {
                        Text(error)
                            .font(PMuxFonts.caption)
                            .foregroundColor(PMuxColors.Status.lost)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                    }

                    if appState.availableHosts.isEmpty && !appState.isLoadingHosts {
                        Text("No other hosts found")
                            .font(PMuxFonts.caption)
                            .foregroundColor(PMuxColors.Text.tertiary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    } else {
                        LazyVStack(spacing: 4) {
                            ForEach(appState.availableHosts) { host in
                                HostBrowserRow(
                                    host: host,
                                    onStar: {
                                        sessionManager.addToFavorites(host: host)
                                    },
                                    onConnect: {
                                        sessionManager.connectHost(peerID: host.peerID)
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.bottom, 8)
            }

            Spacer(minLength: 0)

            PMuxDivider()

            // Footer
            HStack(spacing: 12) {
                Button {
                    sessionManager.toggleGrid()
                } label: {
                    Image(systemName: appState.viewMode == .grid ? "square.grid.2x2.fill" : "square.fill")
                        .font(.system(size: 14))
                        .foregroundColor(PMuxColors.Text.secondary)
                }
                .buttonStyle(.plain)
                .help(appState.viewMode == .grid ? "Single mode" : "Grid mode")

                Spacer()

                Button {
                    appState.showAudioMixer.toggle()
                } label: {
                    Image(systemName: appState.audioEnabled ? "speaker.wave.2" : "speaker.slash")
                        .font(.system(size: 13))
                        .foregroundColor(appState.audioEnabled ? PMuxColors.accent : PMuxColors.Text.tertiary)
                }
                .buttonStyle(.plain)
                .help("Audio Mixer")

                Button {
                    appState.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundColor(PMuxColors.Text.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(PMuxColors.BG.raised)
    }

    // MARK: - Helpers

    private var connectedCount: Int {
        appState.sessions.filter(\.isConnected).count
    }

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(PMuxFonts.caption)
                .foregroundColor(PMuxColors.Text.tertiary)
                .tracking(1.2)

            Spacer()

            Text("\(count)")
                .font(PMuxFonts.captionBold)
                .foregroundColor(PMuxColors.Text.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var emptyFavorites: some View {
        VStack(spacing: 4) {
            Text("No favorites yet")
                .font(PMuxFonts.caption)
                .foregroundColor(PMuxColors.Text.tertiary)
            Text("Star a host below to add it")
                .font(PMuxFonts.metricSmall)
                .foregroundColor(PMuxColors.Text.tertiary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}
