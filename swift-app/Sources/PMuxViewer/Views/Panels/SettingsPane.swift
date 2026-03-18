/// SettingsPane — Full-featured settings modal with sections.

import SwiftUI

struct SettingsPane: View {
    @Environment(AppState.self) private var appState
    @Environment(SessionManager.self) private var sessionManager

    var body: some View {
        if appState.activeOverlay == .settings {
            ZStack {
                // Backdrop — blocks all input to views underneath
                Rectangle()
                    .fill(Color.black.opacity(0.4))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { appState.activeOverlay = .none }
                    .allowsHitTesting(true)

                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Text("Settings")
                            .font(PMuxFonts.heading)
                            .foregroundColor(PMuxColors.Text.primary)
                        Spacer()
                        Button { appState.activeOverlay = .none } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(PMuxColors.Text.secondary)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(PMuxColors.BG.elevated))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                    PMuxDivider()

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 20) {
                            // Connection section
                            settingsSection("Connection") {
                                settingsToggle(
                                    "Auto-connect favorites on launch",
                                    icon: "bolt.fill",
                                    isOn: Binding(
                                        get: { appState.autoConnectOnLaunch },
                                        set: { appState.autoConnectOnLaunch = $0 }
                                    )
                                )

                                settingsToggle(
                                    "Auto-reconnect on disconnect",
                                    icon: "arrow.clockwise",
                                    isOn: Binding(
                                        get: { appState.autoReconnect },
                                        set: { appState.autoReconnect = $0 }
                                    )
                                )
                            }

                            // Default quality section
                            settingsSection("Default Quality") {
                                settingsToggle(
                                    "H.265 codec",
                                    icon: "film",
                                    isOn: Binding(
                                        get: { appState.defaultH265 },
                                        set: { appState.defaultH265 = $0 }
                                    )
                                )

                                settingsToggle(
                                    "4:4:4 color",
                                    icon: "paintpalette",
                                    isOn: Binding(
                                        get: { appState.defaultColor444 },
                                        set: { appState.defaultColor444 = $0 }
                                    )
                                )

                                settingsToggle(
                                    "Hardware decoder",
                                    icon: "cpu",
                                    isOn: Binding(
                                        get: { appState.defaultHWDecode },
                                        set: { appState.defaultHWDecode = $0 }
                                    )
                                )
                            }

                            // Audio section
                            settingsSection("Audio") {
                                settingsToggle(
                                    "Enable audio",
                                    icon: "speaker.wave.2",
                                    isOn: Binding(
                                        get: { appState.audioEnabled },
                                        set: { sessionManager.toggleAudio(enabled: $0) }
                                    )
                                )

                                HStack {
                                    Image(systemName: "info.circle")
                                        .font(.system(size: 10))
                                        .foregroundColor(PMuxColors.Text.tertiary)
                                    Text("Stereo PCM 48kHz from remote host")
                                        .font(PMuxFonts.metricSmall)
                                        .foregroundColor(PMuxColors.Text.tertiary)
                                }
                                .padding(.leading, 28)
                            }

                            // Keyboard shortcuts reference
                            settingsSection("Keyboard Shortcuts") {
                                shortcutRow("F1–F8", "Switch to session slot")
                                shortcutRow("⌘⇧G", "Toggle grid mode")
                                shortcutRow("⌘⇧S", "Toggle sidebar")
                                shortcutRow("⌘⇧D", "Toggle debug overlay")
                                shortcutRow("⌘⇧Q", "Quality settings")
                                shortcutRow("⌘⇧8/9", "Previous / next session")
                                shortcutRow("⌘⇧R", "Reconnect")
                                shortcutRow("⌘⇧`", "Disconnect")
                                shortcutRow("⌘⇧F", "Force single mode")
                                shortcutRow("⌘⇧←→↑↓", "Navigate grid")
                            }

                            // About
                            settingsSection("About") {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("pmux")
                                            .font(PMuxFonts.bodyBold)
                                            .foregroundColor(PMuxColors.Text.primary)
                                        Text("Multi-session Parsec remote desktop viewer")
                                            .font(PMuxFonts.caption)
                                            .foregroundColor(PMuxColors.Text.secondary)
                                        Text("v2.0")
                                            .font(PMuxFonts.metricSmall)
                                            .foregroundColor(PMuxColors.Text.tertiary)
                                    }
                                    Spacer()
                                }
                            }
                        }
                        .padding(20)
                    }
                }
                .frame(width: 400)
                .frame(maxHeight: 520)
                .background(
                    RoundedRectangle(cornerRadius: PMuxSpacing.modalRadius, style: .continuous)
                        .fill(PMuxColors.BG.raised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PMuxSpacing.modalRadius, style: .continuous)
                        .stroke(PMuxColors.Border.subtle, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .animation(.easeOut(duration: 0.2), value: appState.activeOverlay == .settings)
        }
    }

    // MARK: - Helpers

    private func settingsSection<Content: View>(_ title: String,
                                                  @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(PMuxFonts.caption)
                .foregroundColor(PMuxColors.Text.tertiary)
                .tracking(1.0)

            VStack(spacing: 6) {
                content()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: PMuxSpacing.cardRadius, style: .continuous)
                    .fill(PMuxColors.BG.surface)
            )
        }
    }

    private func settingsToggle(_ label: String, icon: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(PMuxColors.Text.secondary)
                .frame(width: 18)

            Text(label)
                .font(PMuxFonts.body)
                .foregroundColor(PMuxColors.Text.primary)

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(PMuxColors.accent)
        }
    }

    private func shortcutRow(_ key: String, _ desc: String) -> some View {
        HStack(spacing: 10) {
            Text(key)
                .font(PMuxFonts.metric)
                .foregroundColor(PMuxColors.Text.accent)
                .frame(width: 80, alignment: .trailing)

            Text(desc)
                .font(PMuxFonts.caption)
                .foregroundColor(PMuxColors.Text.secondary)

            Spacer()
        }
    }
}
