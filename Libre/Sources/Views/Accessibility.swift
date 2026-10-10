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


/// Brand colors from the C4 logo (Oct 10, 2026). Used by onboarding and Get Started only.
/// Contrast: #0B7A55 with white text is about 5.5:1 (filled buttons, both modes). Tinted text and
/// icons use #0B7A55 on light backgrounds (about 5.5:1) and the lighter #12B886 in dark mode
/// (about 8:1 on black), so both pass WCAG AA.
enum Brand {
    static let button = Color(red: 11 / 255, green: 122 / 255, blue: 85 / 255)
    static var emerald: Color {
        #if os(iOS)
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 18 / 255, green: 184 / 255, blue: 134 / 255, alpha: 1)
            : UIColor(red: 11 / 255, green: 122 / 255, blue: 85 / 255, alpha: 1) })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 18 / 255, green: 184 / 255, blue: 134 / 255, alpha: 1)
                : NSColor(red: 11 / 255, green: 122 / 255, blue: 85 / 255, alpha: 1) })
        #endif
    }
}
