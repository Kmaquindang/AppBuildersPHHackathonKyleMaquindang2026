// LibreApp.swift
// Pasa: offline device-to-device mesh team chat with a local AI assistant.
// One SwiftUI codebase for iOS and macOS.

import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct LibreApp: App {
    @StateObject private var mesh = MeshService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(mesh)
                .onAppear {
                    // First run starts the mesh from onboarding, right after the Local Network primer.
                    if mesh.onboardingDone { mesh.start() }
                    #if os(iOS)
                    // Keep the screen awake during demos. iOS pauses peer links when the app leaves the foreground.
                    UIApplication.shared.isIdleTimerDisabled = true
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    // iOS drops peer links in the background. Coming back: rediscover, flush, catch up.
                    switch phase {
                    case .active:
                        #if os(iOS)
                        UIApplication.shared.isIdleTimerDisabled = true
                        #endif
                        mesh.appBecameActive()
                    case .background:
                        #if os(iOS)
                        UIApplication.shared.isIdleTimerDisabled = false   // save battery while away
                        #endif
                        mesh.appWentToBackground()
                    default:
                        break
                    }
                }
        }
        #if os(macOS)
        .defaultSize(width: 760, height: 640)
        #endif
    }
}
