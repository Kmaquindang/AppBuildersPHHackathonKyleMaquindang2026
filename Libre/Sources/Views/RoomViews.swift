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

/// Settings > Room: the active room, its invite, switching, creating and joining.
struct RoomSettingsSection: View {
    @EnvironmentObject private var mesh: MeshService
    @State private var newLabel = ""
    @State private var joinText = ""
    @State private var message: String?
    @State private var showInvite = false
    @State private var confirmLeave = false

    var body: some View {
        Section {
            LabeledContent("Active room", value: mesh.activeRoom.displayName)
            if !mesh.activeRoom.isDefault {
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
            HStack {
                TextField("New room label, for example BOHOL-7", text: $newLabel)
                Button("Create") {
                    mesh.createRoom(label: newLabel)
                    message = "Created \(mesh.activeRoom.label). Show its QR code or share the join string with your team."
                    newLabel = ""
                    showInvite = true
                }
            }
            HStack {
                TextField("Paste a join string (PASA1...)", text: $joinText)
                    .font(.body.monospaced())
                Button("Join") {
                    if mesh.joinRoom(joinText) {
                        message = "Joined \(mesh.activeRoom.label)."
                        joinText = ""
                    } else {
                        message = "That is not a Pasa room join string. Copy the whole PASA1... text."
                    }
                }
                .disabled(joinText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Room")
        } footer: {
            Text(footer)
        }
        .confirmationDialog("Leave \(mesh.activeRoom.displayName)? Its chat and memory stay on this device; join again with the join string.",
                            isPresented: $confirmLeave) {
            Button("Leave room", role: .destructive) { mesh.leaveRoom(mesh.activeRoom.id) }
        }
    }

    private var footer: String {
        let common = "This device reads and writes one room at a time. It still relays other rooms' messages without being able to read them."
        if mesh.activeRoom.isDefault {
            return "Default is the open room: its key is public, so anyone running Pasa nearby can read it. Create a room for privacy. " + common
        }
        return "Anyone with this room's QR code or join string can read and write in it, so share it only with your team. The label (\(mesh.activeRoom.label)) is not secret. " + common
    }
}

/// First run: stay in Default, create a room, or join one with a join string.
struct RoomOnboardingPicker: View {
    enum Choice: String, CaseIterable, Identifiable {
        case open = "Default", create = "Create", join = "Join"
        var id: String { rawValue }
    }

    @Binding var choice: Choice
    @Binding var label: String
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
                TextField("Room label, for example BOHOL-7", text: $label)
                    .textFieldStyle(.roundedBorder)
                Text("Pasa makes a secret key for the room. Invite your team from Settings with the QR code or join string. The label is not secret.")
                    .font(.caption).foregroundStyle(.secondary)
            case .join:
                TextField("Paste the join string (PASA1...)", text: $joinText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                Text("Ask a teammate for the join string from their Settings > Room.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
