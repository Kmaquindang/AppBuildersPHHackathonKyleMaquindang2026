// LibreApp.swift
// Pasa: offline device-to-device mesh team chat with a local AI assistant.
// One SwiftUI codebase for iOS and macOS.

import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct LibreApp: App {
    // One MeshService for the app, so a Bluetooth relaunch (below) and the UI share it.
    @StateObject private var mesh = MeshService.shared
    #if os(iOS)
    @UIApplicationDelegateAdaptor(LibreAppDelegate.self) private var appDelegate
    #endif
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
                // pasa://join?room=...&code=...&v=1 from a scanned QR code or a tapped link.
                .onOpenURL { url in mesh.handleJoinURL(url) }
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
        #if os(macOS)
        // Projector mode: the room's QR code, name and code full screen.
        Window("Join room", id: "projector") {
            ProjectorView().environmentObject(mesh)
        }
        #endif
    }
}

#if os(iOS)
/// Bluetooth state restoration (issue #5): when iOS relaunches Libre in the background for a
/// Bluetooth event, no window appears, so start the mesh here. Its Bluetooth managers are then
/// recreated with their restore identifiers and receive what iOS kept (BLETransport).
final class LibreAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if launchOptions?[.bluetoothCentrals] != nil || launchOptions?[.bluetoothPeripherals] != nil {
            let mesh = MeshService.shared
            if mesh.onboardingDone { mesh.start() }
        }
        return true
    }
}
#endif
