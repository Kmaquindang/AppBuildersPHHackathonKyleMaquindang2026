// RoomViews.swift
// Rooms UI: invite QR code and join string, create / join / switch rooms (Settings and first run).

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// QR code for a join string (CoreImage, no network, no camera needed to show it).
struct RoomQRCode: View {
    let text: String

    var body: some View {
        if let image = RoomQRCode.render(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 200)
                .accessibilityLabel("Room invite QR code")
        } else {
            Text("Could not draw the QR code. Use the join string below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    static func render(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// Passcode field with confirm and a strength hint (create), or a single field (join).
struct PasscodeFields: View {
    @Binding var passcode: String
    var confirm: Binding<String>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField("Passcode (at least \(RoomPasscode.minLength) characters)", text: $passcode)
                .textContentType(.password)
            if let confirm {
                SecureField("Type the passcode again", text: confirm)
                    .textContentType(.password)
                if !passcode.isEmpty {
                    Text(RoomPasscode.hint(passcode))
                        .font(.caption)
                        .foregroundStyle(strengthColor)
                }
                if !confirm.wrappedValue.isEmpty && confirm.wrappedValue != passcode {
                    Text("The two passcodes do not match.").font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private var strengthColor: Color {
        switch RoomPasscode.strength(passcode) {
        case .tooShort, .weak: return .orange
        case .fair: return .secondary
        case .strong: return .green
        }
    }
}

enum RoomFormCheck {
    static func canCreate(name: String, passcode: String, confirm: String) -> Bool {
        !Room.cleanLabel(name).isEmpty && RoomPasscode.isAcceptable(passcode) && passcode == confirm
    }

    static func canJoin(name: String, passcode: String) -> Bool {
        !Room.cleanLabel(name).isEmpty && RoomPasscode.isAcceptable(passcode)
    }
}

/// Settings > Room: the active room, its invite, switching, creating and joining.
struct RoomSettingsSection: View {
    @EnvironmentObject private var mesh: MeshService
    @State private var createName = ""
    @State private var createCode = ""
    @State private var createConfirm = ""
    @State private var joinName = ""
    @State private var joinCode = ""
    @State private var joinText = ""
    @State private var message: String?
    @State private var showInvite = false
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var confirmLeave = false

    var body: some View {
        Section {
            LabeledContent("Active room", value: mesh.activeRoom.displayName)
            if !mesh.activeRoom.isDefault {
                LabeledContent("Check code", value: mesh.activeRoom.checkCode)
                LabeledContent("How to join", value: mesh.activeRoom.usesPasscode ? "Name + passcode, or QR" : "QR or join string only")
                DisclosureGroup("Invite: QR code and join string", isExpanded: $showInvite) {
                    VStack(alignment: .leading, spacing: 8) {
                        RoomQRCode(text: mesh.activeRoom.joinString)
                            .frame(maxWidth: .infinity)
                        Text(mesh.activeRoom.joinString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button("Copy join string") {
                            Clipboard.copy(mesh.activeRoom.joinString)
                            message = "Join string copied. Share it only with your team."
                        }
                        Text("The QR code and join string carry the room key, not the passcode. Anyone who has them can read the room.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if mesh.joinedRooms.count > 1 {
                ForEach(mesh.joinedRooms) { room in
                    Button {
                        mesh.activateRoom(room.id)
                        message = "Switched to \(room.displayName)."
                    } label: {
                        HStack {
                            Text(room.displayName)
                            Spacer()
                            if room.id == mesh.activeRoom.id { Image(systemName: "checkmark") }
                        }
                    }
                }
                Button("Leave \(mesh.activeRoom.displayName)...", role: .destructive) { confirmLeave = true }
            }

            DisclosureGroup("Create a room", isExpanded: $showCreate) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Room name, for example BOHOL-7", text: $createName)
                    PasscodeFields(passcode: $createCode, confirm: $createConfirm)
                    Button {
                        Task {
                            if let room = await mesh.createRoom(name: createName, passcode: createCode) {
                                message = "Created \(room.label) (check code \(room.checkCode)). Teammates join with the name and passcode, or the QR code. The passcode is not saved anywhere, so remember it."
                                createName = ""; createCode = ""; createConfirm = ""
                                showCreate = false
                            } else {
                                message = "Could not create the room. Check the name and passcode."
                            }
                        }
                    } label: {
                        BusyLabel(title: "Create room", busy: mesh.roomBusy)
                    }
                    .disabled(mesh.roomBusy || !RoomFormCheck.canCreate(name: createName, passcode: createCode, confirm: createConfirm))
                }
            }

            DisclosureGroup("Join a room", isExpanded: $showJoin) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Room name", text: $joinName)
                    PasscodeFields(passcode: $joinCode, confirm: nil)
                    Button {
                        Task {
                            if let room = await mesh.joinRoom(name: joinName, passcode: joinCode) {
                                message = "Joined \(room.label). Check code \(room.checkCode): it should match your teammates' screens. If it does not, the name or passcode was typed differently."
                                joinName = ""; joinCode = ""
                                showJoin = false
                            } else {
                                message = "Could not join. Check the name and passcode."
                            }
                        }
                    } label: {
                        BusyLabel(title: "Join room", busy: mesh.roomBusy)
                    }
                    .disabled(mesh.roomBusy || !RoomFormCheck.canJoin(name: joinName, passcode: joinCode))
                    HStack {
                        TextField("Or paste a join string (PASA1...)", text: $joinText)
                            .font(.body.monospaced())
                        Button("Join") {
                            if mesh.joinRoom(joinText) {
                                message = "Joined \(mesh.activeRoom.label) (check code \(mesh.activeRoom.checkCode))."
                                joinText = ""
                                showJoin = false
                            } else {
                                message = "That is not a Pasa room join string. Copy the whole PASA1... text."
                            }
                        }
                        .disabled(joinText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Room")
        } footer: {
            Text(footer)
        }
        .confirmationDialog("Leave \(mesh.activeRoom.displayName)? Its chat and memory stay on this device; join again with the name and passcode or the join string.",
                            isPresented: $confirmLeave) {
            Button("Leave room", role: .destructive) { mesh.leaveRoom(mesh.activeRoom.id) }
        }
    }

    private var footer: String {
        let common = "This device reads and writes one room at a time. It still relays other rooms' messages without being able to read them."
        if mesh.activeRoom.isDefault {
            return "Default is the open room: its key is public, so anyone running Pasa nearby can read it. Create a room for privacy. " + common
        }
        let pass = mesh.activeRoom.usesPasscode
            ? "Anyone who knows the room name and passcode, or has the QR code or join string, can read and write in it. The passcode is never shown again or stored. A short passcode can be guessed by someone who records room traffic, so use a long one. "
            : "This room was made before passcodes: join it with the QR code or join string. "
        return pass + "The room name (\(mesh.activeRoom.label)) is not secret. " + common
    }
}

/// Button label with a spinner while the room key is being derived.
struct BusyLabel: View {
    let title: String
    let busy: Bool

    var body: some View {
        HStack(spacing: 6) {
            if busy { ProgressView().controlSize(.small) }
            Text(busy ? "Making the room key..." : title)
        }
    }
}

/// First run: stay in Default, create a room, or join one (name + passcode, or a join string).
struct RoomOnboardingPicker: View {
    enum Choice: String, CaseIterable, Identifiable {
        case open = "Default", create = "Create", join = "Join"
        var id: String { rawValue }
    }

    @Binding var choice: Choice
    @Binding var name: String
    @Binding var passcode: String
    @Binding var confirm: String
    @Binding var joinText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Room")
                .font(.headline)
            Picker("Room", selection: $choice) {
                ForEach(Choice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch choice {
            case .open:
                Text("The open room. Anyone running Pasa nearby can read it. Fine for a demo; create a room for privacy. You can change this later in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            case .create:
                TextField("Room name, for example BOHOL-7", text: $name)
                    .textFieldStyle(.roundedBorder)
                PasscodeFields(passcode: $passcode, confirm: $confirm)
                    .textFieldStyle(.roundedBorder)
                Text("Like Wi-Fi: teammates join by typing the same name and passcode. The name is not secret; the passcode is never stored.")
                    .font(.caption).foregroundStyle(.secondary)
            case .join:
                TextField("Room name", text: $name)
                    .textFieldStyle(.roundedBorder)
                PasscodeFields(passcode: $passcode, confirm: nil)
                    .textFieldStyle(.roundedBorder)
                Text("Type the name and passcode exactly as your team set them, then compare the check code in Settings > Room.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Or paste a join string (PASA1...)", text: $joinText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
            }
        }
    }

    /// Whether Continue can go ahead with the current inputs. A pasted join string wins over
    /// the name and passcode fields.
    static func isReady(choice: Choice, name: String, passcode: String, confirm: String, joinText: String) -> Bool {
        switch choice {
        case .open: return true
        case .create: return RoomFormCheck.canCreate(name: name, passcode: passcode, confirm: confirm)
        case .join:
            return !joinText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || RoomFormCheck.canJoin(name: name, passcode: passcode)
        }
    }
}
