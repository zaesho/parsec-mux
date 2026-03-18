/// QualityPicker — Custom dark modal with themed segmented controls.

import SwiftUI

struct QualityPicker: View {
    @Environment(AppState.self) private var appState
    @Environment(SessionManager.self) private var sessionManager

    var body: some View {
        if appState.showQualityPicker {
            ZStack {
                // Backdrop
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { dismiss() }

                // Modal
                VStack(spacing: 16) {
                    // Header
                    HStack {
                        Text("Quality Settings")
                            .font(PMuxFonts.heading)
                            .foregroundColor(PMuxColors.Text.primary)
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(PMuxColors.Text.secondary)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(PMuxColors.BG.elevated))
                        }
                        .buttonStyle(.plain)
                    }

                    PMuxDivider()

                    // Resolution
                    qualityRow(label: "Resolution",
                               isSelected: appState.qualityEditField == .resolution) {
                        PMuxSegmentedControl(
                            items: resPresets.map(\.label),
                            selectedIndex: Binding(
                                get: {
                                    resPresets.firstIndex {
                                        $0.w == appState.qualityEditValue.resX &&
                                        $0.h == appState.qualityEditValue.resY
                                    } ?? 0
                                },
                                set: { idx in
                                    appState.qualityEditValue.resX = resPresets[idx].w
                                    appState.qualityEditValue.resY = resPresets[idx].h
                                }
                            )
                        )
                    }

                    // Codec
                    qualityRow(label: "Codec",
                               isSelected: appState.qualityEditField == .codec) {
                        PMuxSegmentedControl(
                            items: ["H.264", "H.265"],
                            selectedIndex: Binding(
                                get: { appState.qualityEditValue.h265 ? 1 : 0 },
                                set: { appState.qualityEditValue.h265 = $0 == 1 }
                            )
                        )
                    }

                    // Color
                    qualityRow(label: "Color",
                               isSelected: appState.qualityEditField == .color) {
                        PMuxSegmentedControl(
                            items: ["4:2:0", "4:4:4"],
                            selectedIndex: Binding(
                                get: { appState.qualityEditValue.color444 ? 1 : 0 },
                                set: { appState.qualityEditValue.color444 = $0 == 1 }
                            )
                        )
                    }

                    // Decoder
                    qualityRow(label: "Decoder",
                               isSelected: appState.qualityEditField == .decoder) {
                        PMuxSegmentedControl(
                            items: ["Software", "Hardware"],
                            selectedIndex: Binding(
                                get: { appState.qualityEditValue.decoderIndex == 1 ? 1 : 0 },
                                set: { appState.qualityEditValue.decoderIndex = $0 == 1 ? 1 : 0 }
                            )
                        )
                    }

                    PMuxDivider()

                    // Actions
                    HStack(spacing: 12) {
                        Button("Cancel") { dismiss() }
                            .buttonStyle(PMuxButtonStyle(variant: .secondary))
                            .keyboardShortcut(.cancelAction)

                        Spacer()

                        Button("Apply") {
                            let idx = appState.activeSessionIndex
                            sessionManager.applyQuality(sessionIndex: idx,
                                                         quality: appState.qualityEditValue)
                            dismiss()
                        }
                        .buttonStyle(PMuxButtonStyle(variant: .accent))
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(20)
                .frame(width: 340)
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
            .animation(.easeOut(duration: 0.2), value: appState.showQualityPicker)
        }
    }

    private func dismiss() {
        appState.showQualityPicker = false
    }

    private func qualityRow<Content: View>(label: String, isSelected: Bool,
                                            @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            // Active field indicator
            RoundedRectangle(cornerRadius: 1)
                .fill(isSelected ? PMuxColors.accent : Color.clear)
                .frame(width: 2, height: 20)
                .padding(.trailing, 8)

            Text(label)
                .font(PMuxFonts.caption)
                .foregroundColor(isSelected ? PMuxColors.Text.primary : PMuxColors.Text.secondary)
                .frame(width: 80, alignment: .leading)

            content()
        }
        .padding(.vertical, 2)
    }
}
