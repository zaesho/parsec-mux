/// SessionSidebar — Two-section sidebar with Favorites and Available hosts.

import SwiftUI

struct SessionSidebar: View {
    @Environment(AppState.self) private var appState
    @Environment(SessionManager.self) private var sessionManager

    var body: some View {
        VStack(spacing: 0) {
            // Title area
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(PMuxColors.accent)

                Text("pmux")
                    .font(PMuxFonts.heading)
                    .foregroundColor(PMuxColors.Text.primary)

                Spacer()

                PMuxPill(
                    text: "\(connectedCount)/\(appState.sessions.count)",
                    bg: PMuxColors.BG.surface,
                    fg: PMuxColors.Text.secondary
                )

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.sidebarVisible = false
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12))
                        .foregroundColor(PMuxColors.Text.tertiary)
                }
                .buttonStyle(.plain)
                .help("Collapse sidebar (⌘⇧S)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
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
                            .font(.system(size: 11))
                            .foregroundColor(PMuxColors.Text.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(PMuxColors.BG.surface)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            PMuxDivider()

            // Scrollable content
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    // FAVORITES section
                    sectionHeader(title: "FAVORITES", icon: "star.fill", count: appState.filteredFavorites.count)

                    if appState.filteredFavorites.isEmpty {
                        emptyFavorites
                    } else {
                        LazyVStack(spacing: 3) {
                            ForEach(appState.filteredFavorites) { session in
                                if let index = appState.sessions.firstIndex(where: { $0.id == session.id }) {
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
                        }
                        .padding(.horizontal, 8)
                    }

                    // AVAILABLE section
                    HStack {
                        sectionHeader(title: "AVAILABLE", icon: "globe", count: appState.availableHosts.count)
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
                    .padding(.top, 6)

                    if let error = appState.hostLoadError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(PMuxFonts.caption)
                            .foregroundColor(PMuxColors.Status.lost)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                    }

                    if appState.availableHosts.isEmpty && !appState.isLoadingHosts {
                        HStack(spacing: 6) {
                            Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                                .font(.system(size: 11))
                                .foregroundColor(PMuxColors.Text.tertiary)
                            Text("No other hosts found")
                                .font(PMuxFonts.caption)
                                .foregroundColor(PMuxColors.Text.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    } else {
                        LazyVStack(spacing: 3) {
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

            // Footer toolbar
            HStack(spacing: 12) {
                // View mode: click toggles grid, menu picks layout
                Menu {
                    Button {
                        if appState.viewMode == .grid {
                            sessionManager.enterSingleMode()
                        } else {
                            sessionManager.enterGridMode()
                        }
                    } label: {
                        Label(appState.viewMode == .grid ? "Single Mode" : "Grid Mode",
                              systemImage: appState.viewMode == .grid ? "rectangle" : "square.grid.2x2")
                    }

                    Divider()

                    ForEach(GridMode.allCases) { mode in
                        Button {
                            appState.gridMode = mode
                            if appState.viewMode != .grid {
                                sessionManager.enterGridMode()
                            }
                        } label: {
                            HStack {
                                Label(mode.rawValue, systemImage: mode.icon)
                                if mode == appState.gridMode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: appState.viewMode == .grid ? "square.grid.2x2.fill" : "rectangle")
                            .font(.system(size: 12))
                        if appState.viewMode == .grid {
                            Text(appState.gridMode.rawValue)
                                .font(PMuxFonts.metricSmall)
                        }
                    }
                    .foregroundColor(appState.viewMode == .grid ? PMuxColors.accent : PMuxColors.Text.secondary)
                }
                .buttonStyle(.plain)
                .help("Grid layout")

                Spacer()

                Button {
                    appState.activeOverlay = appState.activeOverlay == .audioMixer ? .none : .audioMixer
                } label: {
                    Image(systemName: appState.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 12))
                        .foregroundColor(appState.audioEnabled ? PMuxColors.accent : PMuxColors.Text.tertiary)
                }
                .buttonStyle(.plain)
                .help("Audio Mixer")

                Button {
                    appState.activeOverlay = .settings
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12))
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

    private func sectionHeader(title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(PMuxColors.Text.tertiary)

            Text(title)
                .font(PMuxFonts.caption)
                .foregroundColor(PMuxColors.Text.tertiary)
                .tracking(0.8)

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
        VStack(spacing: 6) {
            Image(systemName: "star")
                .font(.system(size: 18, weight: .light))
                .foregroundColor(PMuxColors.Text.tertiary)
            Text("No favorites yet")
                .font(PMuxFonts.caption)
                .foregroundColor(PMuxColors.Text.tertiary)
            Text("Star a host below to add it")
                .font(PMuxFonts.metricSmall)
                .foregroundColor(PMuxColors.Text.tertiary.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
