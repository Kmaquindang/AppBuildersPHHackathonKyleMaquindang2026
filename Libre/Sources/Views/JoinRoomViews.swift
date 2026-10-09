// JoinRoomViews.swift
// "Create your room" (Mac onboarding and Settings), the join screen with a QR code and the code
// printed large (hide or show, new code, expiry, approve new members, projector mode), and the
// phone side: scan the QR code or type the name and code. Pasa must be installed on each phone;
// there is no offline web fallback.

import SwiftUI
#if os(iOS)
import AVFoundation
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Name in, code out. Used as the last Mac onboarding step and from Settings.
struct CreateCodeRoomView: View {
    @EnvironmentObject private var mesh: MeshService
    var onDone: () -> Void = {}
    var showSkip = false
    @State private var name = ""
    @State private var expiry: CodeExpiry = .off
    @State private var approval = false
    @State private var created = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create your room").font(.title.weight(.bold)).padding(.top, 20)
            if created {
                RoomShareView()
                Button("Done") { onDone() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Text("Give the room a name people can say out loud, like CLASS-7B. Pasa makes a short code. Phones join by scanning the QR code or typing the name and code.")
                    .foregroundStyle(.secondary)
                TextField("Room name, for example CLASS-7B", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                Picker("Code expires", selection: $expiry) {
                    ForEach(CodeExpiry.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Approve new members", isOn: $approval)
                Text(approval ? "You tap Approve for each phone that enters the right code." : "Anyone with the right code gets in while an admin device is nearby.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { TintedLabel(text: error, symbol: "exclamationmark.triangle.fill", tint: .red, font: .callout) }
                Button {
                    Task {
                        if await mesh.createCodeRoom(name: name, expiry: expiry, approval: approval) != nil {
                            created = true
                            error = nil
                        } else {
                            error = mesh.lastProblem ?? "Could not create the room. Use letters and numbers for the name."
                        }
                    }
                } label: {
                    BusyLabel(title: "Create room", busy: mesh.roomBusy).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(mesh.roomBusy || Room.cleanLabel(name).isEmpty)
                if showSkip {
                    Button("Skip for now (use Town Square, open to everyone nearby)") { onDone() }.font(.callout)
                }
            }
        }
    }
}

/// The join screen for the active code room: QR code, room name and code printed large, and the
/// admin controls. Only the room's creator holds the code.
struct RoomShareView: View {
    @EnvironmentObject private var mesh: MeshService
    @State private var hidden = false
    @State private var confirmNew = false
    @State private var newExpiry: CodeExpiry = .off
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #else
    @State private var projector = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let link = mesh.activeJoinLink {
                JoinCard(link: link, hidden: hidden, qrSize: 220, browserURL: browserURL)
                Button(hidden ? "Show code" : "Hide code") { hidden.toggle() }
                    .buttonStyle(.bordered)
                DisclosureGroup("Admin options") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("New code...") { confirmNew = true }
                            .disabled(mesh.roomBusy)
                        Button {
                            #if os(macOS)
                            openWindow(id: "projector")
                            #else
                            projector = true
                            #endif
                        } label: { Label("Projector mode", systemImage: "rectangle.inset.filled.and.person.filled") }
                        Picker("Code expires", selection: Binding(
                            get: { currentExpiryChoice },
                            set: { mesh.setCodeExpiry($0) })) {
                            ForEach(CodeExpiry.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        Toggle("Approve new members", isOn: Binding(
                            get: { mesh.activeRoom.gov?.manifest?.approval == true },
                            set: { mesh.setJoinApproval($0) }))
                        #if os(macOS)
                        Text("Browser joins for Android phones: Settings, Advanced.").font(.caption).foregroundStyle(.secondary)
                        #endif
                    }
                    .padding(.top, 6)
                }
                PendingJoinsList()
            } else if let url = browserURL {
                BrowserJoinCard(room: mesh.activeRoom.displayName, url: url, open: mesh.activeRoom.isDefault, qrSize: 220)
            } else {
                Text(mesh.activeRoom.usesCode
                     ? "Only the device that created \(mesh.activeRoom.displayName) can show its code."
                     : "This room has no join code. Create a room with a code to show a join screen.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text(browserURL == nil
                 ? "This QR opens the \(AppBrand.name) app on iPhone. Android phones can join in a browser when browser joins are on (Settings, Advanced)."
                 : "This QR opens a page in any phone browser. iPhones with Pasa can tap Open in Pasa app on that page.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog("Make a new code? Everyone who is not an admin must enter the new code to stay in the room.", isPresented: $confirmNew) {
            ForEach(CodeExpiry.allCases, id: \.self) { choice in
                Button("New code (expires: \(choice.label))") { Task { await mesh.newRoomCode(expiry: choice) } }
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $projector) { ProjectorView().environmentObject(mesh) }
        #endif
    }

    /// The browser QR (http on the local network) when browser joins are on. Never has the code.
    private var browserURL: String? {
        #if os(macOS)
        return mesh.gatewayCanJoin(mesh.activeRoom) ? mesh.gatewayJoinURL(room: mesh.activeRoom) : nil
        #else
        return nil
        #endif
    }

    /// Off when no expiry; otherwise the nearest choice (the exact time is on the card).
    private var currentExpiryChoice: CodeExpiry {
        guard let exp = mesh.activeRoom.gov?.manifest?.codeExpiresAt else { return .off }
        return exp.timeIntervalSinceNow > 3600 * 1.5 ? .day : .hour
    }
}

#if os(macOS)
/// Mac only: turn the browser gateway on or off, with the honest small print.
struct BrowserGatewayControls: View {
    @EnvironmentObject private var mesh: MeshService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Let Android and other phones join in a browser", isOn: Binding(
                get: { mesh.gatewayOn }, set: { mesh.setGateway($0) }))
                .font(.headline)
            if mesh.gatewayOn {
                if let problem = mesh.gatewayProblem {
                    Text(problem).font(.callout).foregroundStyle(.red)
                } else if mesh.gatewayAddress == nil {
                    Text("This Mac is not on a Wi-Fi network. Join the same Wi-Fi or phone hotspot as the phones.")
                        .font(.callout).foregroundStyle(.orange)
                } else if mesh.gatewayPort == 0 {
                    Text("Starting...").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Browser members now: \(mesh.gatewayMembers)").font(.callout)
                }
                Text("Phones must be on the same Wi-Fi as this Mac. The browser page is plain HTTP: people on the same Wi-Fi could read browser members' messages. The Pasa app stays encrypted.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Off. Only phones with the Pasa app can join.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { mesh.refreshGatewayAddress() }
    }
}
#endif

/// Browser QR for a room without a printable code here (Town Square, or a code room this Mac
/// did not create: the browser user types the code shown on the creator's screen).
struct BrowserJoinCard: View {
    let room: String
    let url: String
    var open: Bool
    var qrSize: CGFloat = 220
    var big = false

    var body: some View {
        VStack(spacing: big ? 28 : 10) {
            if let image = RoomQRCode.render(url) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none).resizable().scaledToFit()
                    .frame(width: qrSize, height: qrSize)
                    .padding(big ? 24 : 8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("QR code to open the join page for \(room)")
            }
            Text("Room").font(big ? .title2 : .caption).foregroundStyle(.secondary)
            Text(room)
                .font(.system(size: big ? 96 : 34, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.4).lineLimit(1)
            Text(open ? "No code needed." : "Type the room code on the page.")
                .font(big ? .title2 : .headline)
            Text(url).font(big ? .title3 : .caption).textSelection(.enabled).foregroundStyle(.secondary)
            Text("Scan with the phone camera. Same Wi-Fi as this Mac.")
                .font(big ? .title3 : .caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// QR code plus the name and code in big type.
struct JoinCard: View {
    let link: JoinLink
    var hidden = false
    var qrSize: CGFloat = 220
    var big: Bool = false
    /// When browser joins are on: the QR opens the Mac's local page (room only, never the code).
    var browserURL: String? = nil

    var body: some View {
        VStack(spacing: big ? 28 : 10) {
            if hidden {
                RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.15))
                    .frame(width: qrSize, height: qrSize)
                    .overlay(Label("Code hidden", systemImage: "eye.slash").foregroundStyle(.secondary))
                    .accessibilityLabel("QR code hidden")
            } else if let image = RoomQRCode.render(browserURL ?? link.url) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none).resizable().scaledToFit()
                    .frame(width: qrSize, height: qrSize)
                    .padding(big ? 24 : 8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(browserURL == nil ? "QR code to join \(link.room) in the Pasa app" : "QR code to open the join page for \(link.room)")
                if let browserURL {
                    Text(browserURL).font(big ? .title3 : .caption).textSelection(.enabled).foregroundStyle(.secondary)
                    Text("Scan with the phone camera. Same Wi-Fi as this Mac.").font(big ? .title3 : .caption).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 4) {
                Text("Room").font(big ? .title2 : .caption).foregroundStyle(.secondary)
                Text(link.room)
                    .font(.system(size: big ? 96 : 34, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.4).lineLimit(1)
                Text("Code").font(big ? .title2 : .caption).foregroundStyle(.secondary)
                Text(hidden ? "••••-••••" : link.code)
                    .font(.system(size: big ? 120 : 40, weight: .heavy, design: .monospaced))
                    .minimumScaleFactor(0.4).lineLimit(1)
                    .textSelection(.enabled)
                    .accessibilityLabel(hidden ? "Code hidden" : "Code " + link.code.map { String($0) }.joined(separator: " "))
                Text(link.expiryLine())
                    .font(big ? .title3 : .caption)
                    .foregroundStyle(link.isExpired() ? Color.red : Color.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Valid join requests waiting for an admin (only with "Approve new members" on).
struct PendingJoinsList: View {
    @EnvironmentObject private var mesh: MeshService

    var body: some View {
        let list = mesh.pendingJoins[mesh.activeRoom.id] ?? []
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Waiting for approval (\(list.count))").font(.headline)
                ForEach(list) { p in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(p.request.name).font(.body.weight(.medium))
                            Text(p.request.device).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Approve") { mesh.approveJoin(p) }.buttonStyle(.borderedProminent)
                        Button("Deny", role: .destructive) { mesh.denyJoin(p) }.buttonStyle(.bordered)
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .contain)
                }
            }
        }
    }
}

/// Full-screen join card for a projector or TV.
struct ProjectorView: View {
    @EnvironmentObject private var mesh: MeshService
    @Environment(\.dismiss) private var dismiss

    private var browserURL: String? {
        #if os(macOS)
        return mesh.gatewayCanJoin(mesh.activeRoom) ? mesh.gatewayJoinURL(room: mesh.activeRoom) : nil
        #else
        return nil
        #endif
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(white: 0.06).ignoresSafeArea()
            if let link = mesh.activeJoinLink {
                VStack(spacing: 24) {
                    Text("Join with Pasa").font(.largeTitle.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                    JoinCard(link: link, qrSize: 420, big: true, browserURL: browserURL)
                        .foregroundStyle(.white)
                    Text(browserURL == nil ? "Open Pasa, tap Scan QR, or type the room name and code."
                                           : "Scan with your phone camera, then type the code. Same Wi-Fi as this Mac.")
                        .font(.title2).foregroundStyle(.white.opacity(0.7))
                }
                .padding(40)
            } else if let url = browserURL {
                BrowserJoinCard(room: mesh.activeRoom.displayName, url: url, open: mesh.activeRoom.isDefault, qrSize: 420, big: true)
                    .foregroundStyle(.white)
                    .padding(40)
            } else {
                Text("No join code for this room.").font(.title).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .padding()
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 700)
        .onAppear {
            // Fill the screen (projector) when the window opens.
            DispatchQueue.main.async {
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("projector") == true }), !window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                }
            }
        }
        #endif
    }
}

/// Phone (and Mac) join: scan the QR code, or type the room name and code.
/// Room name handed over by a room-only link (browser page "Open in Pasa app").
struct JoinPrefill: Identifiable, Equatable {
    let id = UUID()
    let room: String
}

struct CodeJoinView: View {
    @EnvironmentObject private var mesh: MeshService
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    private let prefilled: Bool

    init(room: String = "") {
        _name = State(initialValue: room)
        prefilled = !room.isEmpty
    }
    @State private var code = ""
    @State private var message: String?
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Form {
                #if os(iOS)
                Section {
                    Button { scanning = true } label: { Label("Scan QR", systemImage: "qrcode.viewfinder").frame(minHeight: 44) }
                } footer: {
                    Text("Point the camera at the QR code on the teacher's or admin's screen.")
                }
                #endif
                Section {
                    TextField("Room name", text: $name)
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .autocorrectionDisabled()
                    TextField("Code, for example K7QM-3XRF", text: $code)
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    Button {
                        Task { await join(name: name, code: code, expiresAt: nil) }
                    } label: { BusyLabel(title: "Join room", busy: mesh.roomBusy) }
                    .disabled(mesh.roomBusy || Room.cleanLabel(name).isEmpty || !JoinCode.isValid(code))
                } header: {
                    Text(prefilled ? "Type the code for \(name)" : "Or type it")
                } footer: {
                    Text("Codes use only letters and numbers that cannot be mixed up (no 0, O, 1 or I). The code is on the room admin's screen.")
                }
                if let message {
                    Section { Text(message).font(.callout) }
                }
            }
            .navigationTitle("Join a room")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            #if os(iOS)
            .sheet(isPresented: $scanning) {
                QRScannerSheet { text in
                    scanning = false
                    switch JoinLink.parse(text) {
                    case .success(let link):
                        name = link.room
                        code = link.code
                        Task { await join(name: link.room, code: link.code, expiresAt: link.expiresAt) }
                    case .failure:
                        // The Mac's browser QR (http://.../join?room=X): fill in the room, type the code.
                        if let room = GatewayNet.roomFromJoinURL(text) ?? JoinLink.roomOnly(text) {
                            name = room
                            message = "Room \(room) filled in. Type the code shown on the screen."
                        } else {
                            message = "That QR code is not a Pasa room link."
                        }
                    }
                }
            }
            #endif
        }
    }

    private func join(name: String, code: String, expiresAt: Date?) async {
        switch await mesh.joinCodeRoom(name: name, code: code, expiresAt: expiresAt) {
        case .sent(let room):
            message = room.canSend ? "You are in \(room.displayName)." : "Asked to join \(room.displayName). The admin device lets you in when it is nearby\(room.gov?.manifest?.approval == true ? " and an admin approves" : "")."
        case .expired: message = "That code expired. Ask the admin for a new one."
        case .badCode: message = "That code is not valid. Check it and try again."
        case .failed: message = "Could not join right now. Try again."
        }
    }
}

#if os(iOS)
/// Camera QR scanner (AVFoundation, on device). Calls back once with the first QR text.
struct QRScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var denied = false

    var body: some View {
        NavigationStack {
            Group {
                if denied {
                    VStack(spacing: 12) {
                        Text("Camera access is off for Pasa.").font(.headline)
                        Text("Turn it on in Settings > Pasa > Camera, or type the room name and code instead.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                    .padding()
                } else {
                    QRScannerView(onCode: onCode).ignoresSafeArea()
                }
            }
            .navigationTitle("Scan QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: denied = false
            case .notDetermined: denied = !(await AVCaptureDevice.requestAccess(for: .video))
            default: denied = true
            }
        }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            let s = session
            DispatchQueue.global(qos: .userInitiated).async { if !s.isRunning { s.startRunning() } }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let s = session
            DispatchQueue.global(qos: .userInitiated).async { if s.isRunning { s.stopRunning() } }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let qr = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first, let text = qr.stringValue else { return }
            done = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCode?(text)
        }
    }
}
#endif
