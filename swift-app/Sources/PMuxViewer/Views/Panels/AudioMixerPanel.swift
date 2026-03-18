/// AudioMixerPanel — Floating mixer panel with per-session volume and mix mode control.

import SwiftUI

struct AudioMixerPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(SessionManager.self) private var sessionManager

    var body: some View {
        if appState.activeOverlay == .audioMixer {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 12))
                        .foregroundColor(PMuxColors.accent)
                    Text("Audio Mixer")
                        .font(PMuxFonts.heading)
                        .foregroundColor(PMuxColors.Text.primary)
                    Spacer()
                    Button { appState.activeOverlay = .none } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(PMuxColors.Text.tertiary)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(PMuxColors.BG.elevated))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

                // Mix mode picker
                if let mixer = sessionManager.audioMixer {
                    HStack(spacing: 0) {
                        PMuxSegmentedControl(
                            items: AudioMixMode.allCases.map(\.rawValue),
                            selectedIndex: Binding(
                                get: {
                                    AudioMixMode.allCases.firstIndex(of: mixer.mixMode) ?? 0
                                },
                                set: { idx in
                                    mixer.mixMode = AudioMixMode.allCases[idx]
                                    sessionManager.updateAudioVolumes()
                                }
                            )
                        )
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)

                    PMuxDivider()

                    // Master volume
                    volumeRow(
                        icon: "speaker.wave.2.fill",
                        label: "Master",
                        color: PMuxColors.accent,
                        volume: Binding(
                            get: { mixer.masterVolume },
                            set: { mixer.masterVolume = $0 }
                        ),
                        isEnabled: true
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)

                    PMuxDivider()

                    // Per-session volumes
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 2) {
                            ForEach(appState.sessions) { session in
                                if session.isConnected {
                                    let isActive = isSessionAudible(session, mixer: mixer)
                                    volumeRow(
                                        icon: "circle.fill",
                                        label: session.nickname,
                                        color: isActive ? session.health.color : PMuxColors.Text.tertiary,
                                        volume: Binding(
                                            get: { mixer.sessionVolumes[session.id] ?? 1.0 },
                                            set: { mixer.setSessionVolume(peerID: session.id, volume: $0) }
                                        ),
                                        isEnabled: mixer.mixMode == .manual
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "speaker.slash")
                            .font(.system(size: 24))
                            .foregroundColor(PMuxColors.Text.tertiary)
                        Text("Audio disabled")
                            .font(PMuxFonts.caption)
                            .foregroundColor(PMuxColors.Text.tertiary)
                        Text("Enable in Settings")
                            .font(PMuxFonts.metricSmall)
                            .foregroundColor(PMuxColors.Text.tertiary.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            }
            .frame(width: 260)
            .frame(maxHeight: 360)
            .background(
                RoundedRectangle(cornerRadius: PMuxSpacing.modalRadius, style: .continuous)
                    .fill(PMuxColors.BG.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PMuxSpacing.modalRadius, style: .continuous)
                    .stroke(PMuxColors.Border.subtle, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }

    // MARK: - Helpers

    private func volumeRow(icon: String, label: String, color: Color,
                            volume: Binding<Float>, isEnabled: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundColor(color)
                .frame(width: 12)

            Text(label)
                .font(PMuxFonts.caption)
                .foregroundColor(isEnabled ? PMuxColors.Text.primary : PMuxColors.Text.tertiary)
                .lineLimit(1)
                .frame(width: 70, alignment: .leading)

            Slider(value: volume, in: 0...1)
                .tint(PMuxColors.accent)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1.0 : 0.4)

            Text("\(Int(volume.wrappedValue * 100))")
                .font(PMuxFonts.metricSmall)
                .foregroundColor(PMuxColors.Text.tertiary)
                .frame(width: 28, alignment: .trailing)
        }
        .frame(height: 24)
    }

    private func isSessionAudible(_ session: SessionModel, mixer: AudioMixer) -> Bool {
        switch mixer.mixMode {
        case .afv:
            return session.id == appState.activeSession?.id
        case .grid:
            return appState.gridIndices.contains { idx in
                idx >= 0 && idx < appState.sessions.count && appState.sessions[idx].id == session.id
            }
        case .manual, .all:
            return true
        }
    }
}
