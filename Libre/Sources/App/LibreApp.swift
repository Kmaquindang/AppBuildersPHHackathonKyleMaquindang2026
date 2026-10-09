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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(mesh)
                .onAppear {
                    mesh.start()
                    #if os(iOS)
                    // Keep the screen awake during demos. iOS pauses peer links when the app leaves the foreground.
                    UIApplication.shared.isIdleTimerDisabled = true
                    #endif
                }
        }
        #if os(macOS)
        .defaultSize(width: 760, height: 640)
        #endif
    }
}
