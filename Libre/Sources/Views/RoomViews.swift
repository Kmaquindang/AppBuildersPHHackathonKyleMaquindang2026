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
                    TintedLabel(text: "The two passcodes do not match.", symbol: "exclamationmark.triangle.fill", tint: .red)
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
    @State private var showShare = false

    /// Code rooms this device created; on the Mac also Town Square and any code room (browser joins).
    private var showJoinScreenButton: Bool {
        #if os(macOS)
        return mesh.activeJoinLink != nil || mesh.gatewayCanJoin(mesh.activeRoom)
        #else
        return mesh.activeJoinLink != nil
        #endif
    }
    @State private var showCodeCreate = false
    @State private var showCodeJoin = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text("Active room").font(.caption).foregroundStyle(.secondary)
                Text(mesh.activeRoom.displayName).font(.headline)
                if let subtitle = mesh.activeRoom.subtitle { RoomSubtitle(text: subtitle) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if showJoinScreenButton {
                Button { showShare = true } label: { Label("Show join screen", systemImage: "qrcode") }
            }
            Button { showCodeCreate = true } label: { Label("Create a room", systemImage: "plus.rectangle.on.rectangle") }
            Button { showCodeJoin = true } label: { Label("Join a room", systemImage: "qrcode.viewfinder") }
            if mesh.joinedRooms.count > 1 {
                ForEach(mesh.joinedRooms) { room in
                    Button {
                        mesh.activateRoom(room.id)
                        message = "Switched to \(room.displayName)."
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(room.displayName)
                                if let subtitle = room.subtitle { RoomSubtitle(text: subtitle) }
                            }
                            Spacer()
                            if room.id == mesh.activeRoom.id { Image(systemName: "checkmark") }
                        }
                    }
                }
                Button("Leave \(mesh.activeRoom.displayName)...", role: .destructive) { confirmLeave = true }
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Room")
        } footer: {
            Text(mesh.activeRoom.isDefault ? "Town Square is open to everyone nearby. Create a room with a code for privacy." : "Switch rooms here. Room details and admin tools are in Advanced.")
        }
        .sheet(isPresented: $showShare) {
            NavigationStack {
                ScrollView { RoomShareView().padding() }
                    .navigationTitle("Join \(mesh.activeRoom.displayName)")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showShare = false } } }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 640)
            #endif
        }
        .sheet(isPresented: $showCodeCreate) {
            NavigationStack {
                ScrollView { CreateCodeRoomView(onDone: { showCodeCreate = false }).padding() }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showCodeCreate = false } } }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 640)
            #endif
        }
        .sheet(isPresented: $showCodeJoin) {
            CodeJoinView()
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 420)
                #endif
        }
        .confirmationDialog("Leave \(mesh.activeRoom.displayName)? Its chat and memory stay on this device; join again with the name and passcode or the join string.",
                            isPresented: $confirmLeave) {
            Button("Leave room", role: .destructive) { mesh.leaveRoom(mesh.activeRoom.id) }
        }
    }
}

/// Advanced room tools: check code, invite strings, passcode rooms (older style), room admin.
struct RoomAdvancedSection: View {
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

    var body: some View {
        Section {
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
            DisclosureGroup("Create a passcode room", isExpanded: $showCreate) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Room name, for example BOHOL-7", text: $createName)
                    PasscodeFields(passcode: $createCode, confirm: $createConfirm)
                    Button {
                        Task {
                            if let room = await mesh.createRoom(name: createName, passcode: createCode) {
                                message = "Created \(room.displayName) (check code \(room.checkCode)). Teammates join with the name and passcode, or the QR code. The passcode is not saved anywhere, so remember it."
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

            DisclosureGroup("Join a passcode room or paste a join string", isExpanded: $showJoin) {
                VStack(alignment: .leading, spacing: 8) {
                    NearbyRoomsList(selectedName: $joinName)
                    TextField("Room name", text: $joinName)
                    PasscodeFields(passcode: $joinCode, confirm: nil)
                    Button {
                        Task {
                            if let beacon = mesh.nearbyRooms.first(where: { $0.beacon.label == Room.cleanLabel(joinName) })?.beacon {
                                switch await mesh.joinNearby(beacon, passcode: joinCode) {
                                case .joined(let room):
                                    message = "Joined \(room.displayName). \(room.canSend ? "" : "Waiting for an admin device to let you in (automatic when it is nearby). ")Admin fingerprint \(room.adminFingerprint ?? "not heard yet"): compare it with the admin's screen."
                                    joinName = ""; joinCode = ""
                                    showJoin = false
                                case .wrongPasscode:
                                    message = "Wrong passcode for \(Room.displayName(forLabel: beacon.label)). Ask the room admin."
                                case .failed:
                                    message = "Could not join. Check the name and passcode."
                                }
                            } else if let room = await mesh.joinRoom(name: joinName, passcode: joinCode) {
                                message = "Joined \(room.displayName). Check code \(room.checkCode): it should match your teammates' screens. If it does not, the name or passcode was typed differently. If an admin must let you in, that happens automatically when an admin device is nearby."
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
                                message = "Joined \(mesh.activeRoom.displayName) (check code \(mesh.activeRoom.checkCode))."
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
            Text("Room details: \(mesh.activeRoom.displayName)")
        } footer: {
            Text(footer)
        }
        if !mesh.activeRoom.isDefault, mesh.activeRoom.gov != nil {
            RoomAdminSection()
        }
    }

    private var footer: String {
        let common = mesh.isAIPeer
            ? "As the AI peer, this Mac answers in every room it has joined (one question at a time, rooms take turns). It still relays other rooms' messages without being able to read them."
            : "This device reads and writes one room at a time (switch from the room chip in the header). It still relays other rooms' messages without being able to read them."
        if mesh.activeRoom.isDefault {
            return "Town Square is open to everyone nearby, no code needed: its key is public, so anyone running Pasa nearby can read it. Create a room for privacy. " + common
        }
        let pass = mesh.activeRoom.usesPasscode
            ? "Anyone who knows the room name and passcode, or has the QR code or join string, can read and write in it. The passcode is never shown again or stored. A short passcode can be guessed by someone who records room traffic, so use a long one. "
            : "This room was made before passcodes: join it with the QR code or join string. "
        return pass + "The room name (\(mesh.activeRoom.displayName)) is not secret. " + common
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

/// First run: stay in Town Square (the open room), create a room, or join one (name + passcode, or a join string).
struct RoomOnboardingPicker: View {
    enum Choice: String, CaseIterable, Identifiable {
        case open = "Town Square", create = "Create", join = "Join"
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
                RoomSubtitle(text: Room.townSquareSubtitle)
                Text("Anyone running Pasa nearby can read it. Fine for a demo; create a room for privacy. You can change this later in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .create:
                TextField("Room name, for example BOHOL-7", text: $name)
                    .textFieldStyle(.roundedBorder)
                PasscodeFields(passcode: $passcode, confirm: $confirm)
                    .textFieldStyle(.roundedBorder)
                Text("Like Wi-Fi: teammates join by typing the same name and passcode. The name is not secret; the passcode is never stored.")
                    .font(.caption).foregroundStyle(.secondary)
            case .join:
                NearbyRoomsList(selectedName: $name)
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

/// Nearby rooms: Listed rooms heard over the mesh (signed beacons, gone after 45 s of silence).
/// Tapping one fills its name; the passcode is still needed.
struct NearbyRoomsList: View {
    @EnvironmentObject private var mesh: MeshService
    @Binding var selectedName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nearby rooms").font(.subheadline.weight(.semibold))
            if mesh.nearbyRooms.isEmpty {
                Text("None heard yet. Listed rooms show here when their admin device is nearby with Pasa open. Hidden rooms never show: type the name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(mesh.nearbyRooms, id: \.beacon.room) { heard in
                let b = heard.beacon
                let joined = mesh.joinedRooms.contains { $0.id == b.room }
                Button {
                    selectedName = b.label
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Room.displayName(forLabel: b.label)).font(.body.weight(.semibold))
                            Text("Admin \(b.adminName), key \(b.adminFingerprint)\(heard.conflict ? ". Warning: another device claims this room" : "")")
                                .font(.caption2).foregroundStyle(heard.conflict ? Color.red : Color.secondary)
                        }
                        Spacer()
                        if joined { Text("Joined").font(.caption2).foregroundStyle(.secondary) }
                        Text(b.badge)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((b.isClosed || b.isFull ? Color.orange : Color.green).opacity(0.2), in: Capsule())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(b.isClosed || b.isFull)
            }
            Text("Listed room names and member counts are visible to anyone nearby running Pasa.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Settings > Room admin: Listed or Hidden, member cap, members with Kick, close or reopen,
/// admin fingerprint. Every change is a signed manifest that every device checks.
struct RoomAdminSection: View {
    @EnvironmentObject private var mesh: MeshService
    @State private var kickTarget: RoomMember?
    @State private var confirmClose = false
    @State private var note: String?

    private var room: Room { mesh.activeRoom }
    private var manifest: RoomManifest? { room.gov?.manifest }

    private var roleText: String {
        if room.isRemoved { return "Removed by an admin" }
        if mesh.isRoomCreatorAdmin { return "You are the room admin (this device holds the admin key)" }
        if mesh.isRoomAdmin { return "You are a co-admin" }
        if room.isPending { return manifest == nil ? "Waiting for the room admin" : "Waiting to be let in" }
        return "Member"
    }

    var body: some View {
        Section {
            LabeledContent("Your role", value: roleText)
            if let m = manifest {
                LabeledContent("Admin", value: "\(m.adminName), key \(Fingerprint.of(m.adminKey))")
                LabeledContent("Status", value: "\(m.statusWord), \(m.members.count)/\(m.cap) members, key epoch \(m.epoch)")
                Toggle("Listed in Nearby rooms", isOn: Binding(get: { m.listed }, set: { on in
                    if mesh.setRoomListed(on) { note = on ? "Listed: the name and member count are visible to anyone nearby." : "Hidden: people must type the name." }
                }))
                .disabled(!mesh.isRoomAdmin)
                Stepper("Member cap: \(m.cap)", value: Binding(get: { m.cap }, set: { mesh.setRoomCap($0) }),
                        in: RoomLimits.minCap...RoomLimits.maxCap)
                    .disabled(!mesh.isRoomAdmin)
                ForEach(m.members) { member in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            let role = mesh.roomRole(of: member)
                            HStack(spacing: 4) {
                                Text(member.name + (mesh.isMe(member) ? " (you)" : ""))
                                if role.isAdmin { AdminBadge(role: role, showWord: true) }
                            }
                            .accessibilityElement(children: .combine)
                            Text("\(member.device), key \(member.fingerprint)").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if mesh.isRoomCreatorAdmin && !mesh.isMe(member) {
                            Button(mesh.isCoAdmin(member) ? "Remove co-admin" : "Make co-admin") {
                                mesh.setCoAdmin(member, !mesh.isCoAdmin(member))
                            }
                            .font(.caption)
                        }
                        if mesh.isRoomAdmin && !mesh.isMe(member) {
                            Button("Kick", role: .destructive) { kickTarget = member }
                                .font(.caption)
                        }
                    }
                }
                if mesh.isRoomAdmin {
                    Button(m.state == .closed ? "Reopen room" : "Close room...", role: m.state == .closed ? nil : .destructive) {
                        if m.state == .closed { mesh.setRoomClosed(false) } else { confirmClose = true }
                    }
                }
            } else {
                Text("No room manifest heard yet. It arrives when an admin device of this room is nearby.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Room admin")
        } footer: {
            Text("Kick makes a new room key and hands it to everyone else, so the removed device cannot read new messages. Messages it already received stay on it. The removed device's key is banned, but a changed copy of the app could make a new key and ask to join again with the passcode: to fully lock someone out, make a new room with a new passcode. Joining needs an admin device nearby. The cap limits who is let in.\(room.epoch == 0 ? " This room still uses the passcode key (it was made before admin keys), so anyone with the passcode can read it until the first kick." : "")")
        }
        .confirmationDialog(kickTarget.map { "Kick \($0.name)? Pasa makes a new room key for everyone else." } ?? "",
                            isPresented: Binding(get: { kickTarget != nil }, set: { if !$0 { kickTarget = nil } })) {
            Button("Kick and change the room key", role: .destructive) {
                if let target = kickTarget, mesh.kick(target) { note = "\(target.name) removed. New room key sent to the others." }
                kickTarget = nil
            }
        }
        .confirmationDialog("Close \(room.displayName)? Nobody can send in it; chat and memory stay read-only. You can reopen it.", isPresented: $confirmClose) {
            Button("Close room", role: .destructive) { mesh.setRoomClosed(true) }
        }
    }
}


/// The open room's one-line subtitle ("Open to everyone nearby. No code needed."). Wraps at any
/// Dynamic Type size instead of truncating.
struct RoomSubtitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }
}
