// Accessibility.swift
// Shared pieces for the HIG pass: colored icon with text in the primary label color (colored text
// such as orange or green on white is under 4.5:1), and Dynamic Type previews.

import SwiftUI

/// "Warning" style line: the tint goes on the icon only, so the text keeps full contrast.
struct TintedLabel: View {
    let text: String
    let symbol: String
    let tint: Color
    var font: Font = .caption

    var body: some View {
        Label {
            Text(text)
                .font(font)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Header and chat, AX5") {
    let mesh = MeshService()
    return ChatScreen()
        .environmentObject(mesh)
        .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("Header and chat, dark, xxxLarge") {
    let mesh = MeshService()
    return ChatScreen()
        .environmentObject(mesh)
        .environment(\.dynamicTypeSize, .xxxLarge)
        .preferredColorScheme(.dark)
}

#Preview("Onboarding, AX5") {
    OnboardingFlow()
        .environmentObject(MeshService())
        .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("Labels, AX5") {
    VStack(alignment: .leading, spacing: 12) {
        TintedLabel(text: "No one nearby. 6 messages will send when a teammate is in range.", symbol: "clock", tint: .orange, font: .subheadline)
        TintedLabel(text: "Local Network looks blocked", symbol: "exclamationmark.triangle.fill", tint: .orange)
    }
    .padding()
    .environment(\.dynamicTypeSize, .accessibility5)
}
#endif
