import SwiftUI
import Combine
import CompanionCore
import CompanionTransport
import AppKit
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins

@main
struct CompanionApp: App {
    @StateObject private var server: CompanionServer

    init() {
        let s = CompanionServer()
        _server = StateObject(wrappedValue: s)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                s.handleSleep()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                await s.handleWake()
            }
        }
        Task { @MainActor in
            await s.start()
        }
    }

    var body: some Scene {
        WindowGroup("Relay") {
            CompanionView(server: server)
                .frame(minWidth: 460, minHeight: 560)
        }
        .defaultSize(width: 480, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Send File to Phone…") {
                    let picker = NSOpenPanel()
                    picker.canChooseDirectories = false
                    picker.allowsMultipleSelection = false
                    if picker.runModal() == .OK, let url = picker.url {
                        Task { await server.enqueue(url) }
                    }
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Open Received Files") {
                    NSWorkspace.shared.open(server.receiveFolder)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Device") {
                Button("Take Photo from Phone") {
                    Task { await server.requestCapture(mode: "photo") }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Scan Document from Phone") {
                    Task { await server.requestCapture(mode: "scan") }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            CompanionView(server: server)
                .frame(width: 460, height: 600)
        } label: {
            if let path = Bundle.main.path(forResource: "MenuBarIcon", ofType: "png"),
               let nsImg = NSImage(contentsOfFile: path) {
                let _ = nsImg.isTemplate = true
                Image(nsImage: nsImg)
                    .renderingMode(.template)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

func generateQRCode(from string: String) -> NSImage? {
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let outputImage = filter.outputImage else { return nil }
    let transform = CGAffineTransform(scaleX: 6, y: 6)
    let scaledImage = outputImage.transformed(by: transform)
    guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
    return NSImage(cgImage: cgImage, size: NSSize(width: scaledImage.extent.width, height: scaledImage.extent.height))
}

enum RelayTab: String, CaseIterable {
    case transfer = "Transfer"
    case messages = "Messages"
    case calls = "Calls"
    case notifications = "Notifications"
}

private func formatTimestamp(_ ms: Int64) -> String {
    let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
    let calendar = Calendar.current
    let formatter = DateFormatter()
    if calendar.isDateInToday(date) {
        formatter.dateFormat = "h:mm a"
    } else {
        formatter.dateFormat = "MMM d, h:mm a"
    }
    return formatter.string(from: date)
}

private func formatDuration(_ totalSeconds: Int) -> String {
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%02d:%02d", minutes, seconds)
}

struct CompanionView: View {
    @ObservedObject var server: CompanionServer
    @ObservedObject private var bluetooth = BluetoothHandsFreeController.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: RelayTab = .transfer
    @State private var host = ""
    @State private var textToSend = ""
    @State private var isDropTargeted = false
    @State private var replyTexts: [String: String] = [:]
    @State private var chatInput = ""
    @State private var showNewSmsModal = false
    @State private var newSmsNumber = ""
    @State private var newSmsText = ""
    @State private var dialerNumber = ""
    @State private var callDurationSeconds = 0
    @State private var isSpeakerOn = false

    private let relayGreen = Color(red: 0.14, green: 0.36, blue: 0.31)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header Bar
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(relayGreen, in: RoundedRectangle(cornerRadius: 10))
                    Text("Relay")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    Spacer()
                    if let peer = server.peerName {
                        HStack(spacing: 5) {
                            Circle().fill(Color.green).frame(width: 7, height: 7)
                            Text("Paired · \(peer)")
                                .lineLimit(1)
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.green.opacity(0.12)))
                    } else {
                        HStack(spacing: 5) {
                            Circle().fill(Color.secondary).frame(width: 7, height: 7)
                            Text("Waiting for phone")
                                .font(.caption.weight(.medium))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.secondary.opacity(0.1)))
                    }
                }

                // Live Call Banner (Floating whenever a call is active)
                if let call = server.activeCall {
                    callStatusBanner(call: call)
                }

                if let request = server.pending {
                    Text("Pair with \(request.name)?").font(.headline)
                    Text(request.code).font(.system(.title, design: .monospaced)).textSelection(.enabled)
                    Text("Check that this code matches the phone.")
                    HStack {
                        Button("Approve pairing") { server.approve() }
                        Button("Reject") { server.reject() }
                    }
                } else if server.peerName == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Two devices. One flow.")
                            .font(.system(size: 28, weight: .medium))
                        Text("Your Mac, meet your Android.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    Text("01  /  Pair your phone").font(.headline)
                    if !server.invitation.isEmpty {
                        if let qr = generateQRCode(from: server.invitation) {
                            VStack(spacing: 8) {
                                Image(nsImage: qr)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 170, height: 170)
                                    .padding(8)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))

                                Text("Open Relay on Android and scan this code.\nThen compare the verification code on both devices.")
                                    .multilineTextAlignment(.center)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        HStack {
                            Button("Copy invitation link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(server.invitation, forType: .string)
                            }
                            Spacer()
                        }
                    } else {
                        TextField("Mac Wi-Fi address", text: $host)
                            .textFieldStyle(.roundedBorder)
                        Button("Create pairing invitation") { server.createInvitation(host: host) }
                    }
                } else {
                    // Segmented navigation tabs
                    HStack(spacing: 6) {
                        ForEach(RelayTab.allCases, id: \.self) { tab in
                            Button {
                                selectedTab = tab
                                if tab == .messages && server.smsThreads.isEmpty {
                                    server.requestSmsSync()
                                }
                                if tab == .calls {
                                    bluetooth.refreshDevices(peerNameHint: server.peerName)
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    switch tab {
                                    case .transfer:
                                        Image(systemName: "arrow.triangle.swap")
                                    case .messages:
                                        Image(systemName: "message.fill")
                                    case .calls:
                                        Image(systemName: "phone.fill")
                                    case .notifications:
                                        Image(systemName: "bell.fill")
                                    }
                                    Text(tab.rawValue)
                                        .font(.subheadline.weight(selectedTab == tab ? .semibold : .medium))
                                    if tab == .notifications && !server.notifications.isEmpty {
                                        Text("\(server.notifications.count)")
                                            .font(.system(size: 10, weight: .bold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(selectedTab == tab ? Color.white.opacity(0.3) : relayGreen.opacity(0.2)))
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(selectedTab == tab ? relayGreen : Color.secondary.opacity(0.08))
                                )
                                .foregroundStyle(selectedTab == tab ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)

                    // Tab Contents
                    switch selectedTab {
                    case .transfer:
                        transferTabView
                    case .messages:
                        messagesTabView
                    case .calls:
                        callsTabView
                    case .notifications:
                        notificationsTabView
                    }
                }

                Divider()
                Label(server.status, systemImage: "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("DIRECT CONNECTION  /  NO ACCOUNT NEEDED  /  LOCAL WI-FI")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(colorScheme == .dark ? Color(red: 0.55, green: 0.80, blue: 0.69) : relayGreen)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if server.activeCall?.state == "OFFHOOK" {
                callDurationSeconds += 1
            } else {
                callDurationSeconds = 0
            }
        }
        .task { await server.start() }
    }

    // MARK: - Transfer Tab View
    private var transferTabView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("FILES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)

            // Drag and Drop Zone
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isDropTargeted ? relayGreen : Color.secondary.opacity(0.3),
                                  style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(isDropTargeted ? relayGreen.opacity(0.1) : Color.secondary.opacity(0.05)))
                    .frame(height: 120)
                VStack(spacing: 4) {
                    Image(systemName: "arrow.up.doc")
                        .font(.title3)
                        .foregroundStyle(colorScheme == .dark ? Color(red: 0.55, green: 0.80, blue: 0.69) : relayGreen)
                    Text("Drop a file. It’s on your phone.")
                        .font(.callout.weight(.medium))
                    Text("Send directly over Wi-Fi · Up to 100 MiB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url {
                            Task { @MainActor in
                                await server.enqueue(url)
                            }
                        }
                    }
                }
                return true
            }

            HStack {
                Button("Choose file to send…") {
                    let picker = NSOpenPanel()
                    picker.canChooseDirectories = false
                    picker.allowsMultipleSelection = false
                    if picker.runModal() == .OK, let url = picker.url {
                        Task { await server.enqueue(url) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(relayGreen)
                Button("Open received files") {
                    NSWorkspace.shared.open(server.receiveFolder)
                }
            }

            if !server.lastTransfer.isEmpty {
                Text(server.lastTransfer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            }

            Divider()

            // Photo & Document Capture
            HStack {
                Text("Camera & scanner").font(.headline)
                Spacer()
            }
            if let active = server.activeCaptureRequest {
                HStack {
                    Text("Waiting for phone to \(active == "scan" ? "scan document" : "take photo")…")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Cancel") {
                        server.cancelCapture()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            } else {
                HStack {
                    Button {
                        Task { await server.requestCapture(mode: "photo") }
                    } label: {
                        Label("Take photo", systemImage: "camera")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    Button {
                        Task { await server.requestCapture(mode: "scan") }
                    } label: {
                        Label("Scan document", systemImage: "doc.viewfinder")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                }
            }

            Divider()

            // Clipboard & Text sharing
            HStack {
                Text("Clipboard").font(.headline)
                Spacer()
                Toggle("Sync clipboard", isOn: $server.clipboardSyncEnabled)
                    .labelsHidden()
            }
            Text("Copy on Mac, then use Relay on your phone to sync or paste.")
                .font(.caption).foregroundStyle(.secondary)

            Text("Send a thought").font(.headline)
            HStack {
                TextField("A link, a note, anything…", text: $textToSend)
                    .textFieldStyle(.roundedBorder)
                Button("Send") {
                    let text = textToSend
                    textToSend = ""
                    Task { await server.sendText(text) }
                }
                .disabled(textToSend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // Received inbox items
            if !server.inbox.isEmpty {
                Divider()
                HStack {
                    Text("Inbox from phone (\(server.inbox.count))").font(.headline)
                    Spacer()
                }
                VStack(spacing: 8) {
                    ForEach(server.inbox) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top) {
                                Image(systemName: item.isLink ? "link" : "doc.text")
                                    .foregroundStyle(colorScheme == .dark ? Color(red: 0.55, green: 0.80, blue: 0.69) : relayGreen)
                                Text(item.text)
                                    .font(.system(.body, design: item.isLink ? .monospaced : .default))
                                    .textSelection(.enabled)
                                    .lineLimit(4)
                                Spacer()
                                Button(role: .destructive) {
                                    Task { await server.removeInboxItem(id: item.id) }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                }
                                .buttonStyle(.borderless)
                            }
                            HStack {
                                if item.isLink, let url = URL(string: item.text) {
                                    Button("Open Link") {
                                        NSWorkspace.shared.open(url)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(item.text, forType: .string)
                                }
                                .controlSize(.small)
                                Spacer()
                                Text(item.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                    }
                }
            }

            Divider()
            Toggle("Launch Relay at login", isOn: $server.launchAtLogin)
                .font(.subheadline)
            Button("Forget phone", role: .destructive) { server.forget() }
        }
    }

    // MARK: - Messages (SMS) Tab View
    private var messagesTabView: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let activeId = server.activeThreadId,
               let thread = server.smsThreads.first(where: { $0.threadId == activeId }) ??
                            server.smsThreads.first {
                // Conversation View
                HStack(spacing: 8) {
                    Button {
                        server.activeThreadId = nil
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Conversations")
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))

                    Spacer()

                    Button {
                        server.selectSmsThread(threadId: thread.threadId)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh Messages")
                }

                HStack(spacing: 10) {
                    Circle()
                        .fill(relayGreen.opacity(0.2))
                        .frame(width: 34, height: 34)
                        .overlay(
                            Text(String((thread.contactName.isEmpty ? thread.address : thread.contactName).prefix(1)).uppercased())
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(relayGreen)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(thread.contactName.isEmpty ? thread.address : thread.contactName)
                            .font(.headline)
                        if !thread.address.isEmpty && thread.address != thread.contactName {
                            Text(thread.address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 2)

                Divider()

                // Messages Bubble Stream
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            if server.activeThreadMessages.isEmpty {
                                Text("No messages loaded yet or waiting for response...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 20)
                            } else {
                                ForEach(server.activeThreadMessages, id: \.id) { msg in
                                    let isFromMe = (msg.isFromMe == true) || (msg.type == 2)
                                    HStack {
                                        if isFromMe { Spacer(minLength: 40) }
                                        VStack(alignment: isFromMe ? .trailing : .leading, spacing: 3) {
                                            Text(msg.body)
                                                .font(.body)
                                                .textSelection(.enabled)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 14)
                                                        .fill(isFromMe ? relayGreen : Color.secondary.opacity(0.12))
                                                )
                                                .foregroundStyle(isFromMe ? Color.white : Color.primary)
                                            Text(formatTimestamp(msg.date))
                                                .font(.system(size: 9))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 4)
                                        }
                                        if !isFromMe { Spacer(minLength: 40) }
                                    }
                                    .id(msg.id)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(minHeight: 220, maxHeight: 320)
                    .onChange(of: server.activeThreadMessages.count) { _ in
                        if let last = server.activeThreadMessages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }

                // Compose / Reply bar for active thread
                HStack(spacing: 8) {
                    TextField("Send an SMS via phone…", text: $chatInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            sendChatSms(to: thread.address)
                        }
                    Button {
                        sendChatSms(to: thread.address)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                            .foregroundStyle(chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : relayGreen)
                    }
                    .buttonStyle(.plain)
                    .disabled(chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                // Threads List View
                HStack {
                    Text("SMS Conversations").font(.headline)
                    Spacer()
                    Button {
                        server.requestSmsSync()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Sync")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        showNewSmsModal.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.pencil")
                            Text("New SMS")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(relayGreen)
                    .controlSize(.small)
                }

                // Compose new thread drawer
                if showNewSmsModal {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Compose New Message").font(.subheadline.weight(.semibold))
                        TextField("Recipient Phone Number (e.g. +1...)", text: $newSmsNumber)
                            .textFieldStyle(.roundedBorder)
                        TextField("Message body…", text: $newSmsText)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Spacer()
                            Button("Cancel") {
                                showNewSmsModal = false
                                newSmsNumber = ""
                                newSmsText = ""
                            }
                            .buttonStyle(.plain)
                            .font(.caption)

                            Button("Send SMS") {
                                let num = newSmsNumber.trimmingCharacters(in: .whitespacesAndNewlines)
                                let text = newSmsText.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !num.isEmpty && !text.isEmpty {
                                    server.sendSms(address: num, text: text)
                                    showNewSmsModal = false
                                    newSmsNumber = ""
                                    newSmsText = ""
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(relayGreen)
                            .controlSize(.small)
                            .disabled(newSmsNumber.isEmpty || newSmsText.isEmpty)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                }

                if server.smsThreads.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "message.badge.waveform")
                            .font(.system(size: 36))
                            .foregroundStyle(relayGreen.opacity(0.7))
                        Text("No SMS threads synced yet")
                            .font(.headline)
                        Text("Sync SMS conversations from your Android phone over your private Wi-Fi network.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Sync Conversations Now") {
                            server.requestSmsSync()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(relayGreen)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    VStack(spacing: 8) {
                        ForEach(server.smsThreads) { thread in
                            Button {
                                server.selectSmsThread(threadId: thread.threadId)
                            } label: {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(relayGreen.opacity(0.18))
                                        .frame(width: 38, height: 38)
                                        .overlay(
                                            Text(String((thread.contactName.isEmpty ? thread.address : thread.contactName).prefix(1)).uppercased())
                                                .font(.system(size: 15, weight: .bold))
                                                .foregroundStyle(relayGreen)
                                        )

                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(thread.contactName.isEmpty ? thread.address : thread.contactName)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(Color.primary)
                                            Spacer()
                                            Text(formatTimestamp(thread.date))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(thread.snippet)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    if thread.unreadCount > 0 {
                                        Circle()
                                            .fill(relayGreen)
                                            .frame(width: 8, height: 8)
                                    }
                                }
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func sendChatSms(to address: String) {
        let trimmed = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        server.sendSms(address: address, text: trimmed)
        chatInput = ""
    }

    // MARK: - Notifications Tab View
    private var notificationsTabView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Mirrored Notifications (\(server.notifications.count))").font(.headline)
                Spacer()
                if !server.notifications.isEmpty {
                    Button("Clear All") {
                        server.clearAllNotifications()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if server.notifications.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bell.badge.waveform")
                        .font(.system(size: 36))
                        .foregroundStyle(relayGreen.opacity(0.7))
                    Text("No active notifications")
                        .font(.headline)
                    Text("Incoming notifications from WhatsApp, Messages, Telegram, and other apps will mirror here in real time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                VStack(spacing: 10) {
                    ForEach(server.notifications) { notif in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(notif.appName.uppercased())
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(relayGreen)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(relayGreen.opacity(0.12)))

                                Spacer()

                                Text(formatTimestamp(notif.timestamp))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                Button {
                                    server.dismissNotification(id: notif.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }

                            if !notif.title.isEmpty {
                                Text(notif.title)
                                    .font(.subheadline.weight(.semibold))
                            }

                            if !notif.text.isEmpty {
                                Text(notif.text)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                            }

                            if notif.canReply {
                                HStack(spacing: 8) {
                                    TextField("Inline reply…", text: Binding(
                                        get: { replyTexts[notif.id] ?? "" },
                                        set: { replyTexts[notif.id] = $0 }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit {
                                        sendReply(for: notif)
                                    }

                                    Button("Reply") {
                                        sendReply(for: notif)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(relayGreen)
                                    .controlSize(.small)
                                    .disabled((replyTexts[notif.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                                .padding(.top, 2)
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
                    }
                }
            }
        }
    }

    private func sendReply(for notif: MirroredNotification) {
        let text = (replyTexts[notif.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        server.replyToNotification(id: notif.id, text: text)
        replyTexts[notif.id] = ""
    }

    // MARK: - Call Status Banner
    @ViewBuilder
    private func callStatusBanner(call: ActiveCall) -> some View {
        if call.state == "RINGING" {
            HStack(spacing: 12) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.green, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(bluetooth.isBluetoothPaired ? "INCOMING CALL (MAC AUDIO READY)" : "INCOMING CALL (WI-FI)")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(.green)
                    }
                    Text(call.callerName)
                        .font(.headline)
                    if !call.number.isEmpty && call.number != call.callerName {
                        Text(call.number)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Quick Decline Menu with Presets
                Menu {
                    Button("“Can't talk right now, I'll call you back.”") {
                        server.declineCallWithSms(number: call.number, message: "Can't talk right now, I'll call you back.")
                    }
                    Button("“In a meeting, what's up?”") {
                        server.declineCallWithSms(number: call.number, message: "In a meeting, what's up?")
                    }
                    Button("“Driving right now, talk later.”") {
                        server.declineCallWithSms(number: call.number, message: "Driving right now, talk later.")
                    }
                } label: {
                    Image(systemName: "message.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.secondary.opacity(0.12)))
                }
                .menuStyle(.borderlessButton)

                // Decline Button
                Button {
                    server.rejectCall()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.red))
                }
                .buttonStyle(.plain)

                if bluetooth.isBluetoothPaired {
                    // Answer on Phone
                    Button {
                        isSpeakerOn = false
                        server.answerCall(speaker: false, routeToMacAudio: false)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "iphone")
                            Text("Phone")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Capsule().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    // Answer on Mac Button (Direct Hands-Free Audio)
                    Button {
                        isSpeakerOn = false
                        server.answerCall(speaker: false, routeToMacAudio: true)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "macbook.and.iphone")
                            Text("Answer on Mac")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.green))
                    }
                    .buttonStyle(.plain)
                } else {
                    // Answer on Speakerphone Button
                    Button {
                        isSpeakerOn = true
                        server.answerCall(speaker: true, routeToMacAudio: false)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "speaker.wave.2.fill")
                            Text("Speaker")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Capsule().strokeBorder(Color.green, lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    // Answer Button
                    Button {
                        isSpeakerOn = false
                        server.answerCall(speaker: false, routeToMacAudio: false)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "phone.fill")
                            Text("Answer")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.green))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.35), lineWidth: 1))
        } else if call.state == "OFFHOOK" {
            HStack(spacing: 12) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.green, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(bluetooth.isAudioRoutedToMac ? "MAC AUDIO LIVE" : "CALL IN PROGRESS")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(bluetooth.isAudioRoutedToMac ? .green : .blue)
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(formatDuration(callDurationSeconds))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(call.callerName)
                        .font(.headline)
                    if !call.number.isEmpty && call.number != call.callerName {
                        Text(call.number)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if bluetooth.isBluetoothPaired {
                    // Mute Mac Mic
                    Button {
                        bluetooth.toggleMute()
                    } label: {
                        Image(systemName: bluetooth.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(bluetooth.isMuted ? Color.red : Color.primary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.secondary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)

                    // Audio Route Toggle (Mac Audio <-> Phone Audio)
                    Button {
                        if bluetooth.isAudioRoutedToMac {
                            bluetooth.routeAudioToPhone()
                        } else {
                            bluetooth.routeAudioToMac()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: bluetooth.isAudioRoutedToMac ? "speaker.wave.3.fill" : "iphone")
                            Text(bluetooth.isAudioRoutedToMac ? "Mac Audio" : "Phone Audio")
                                .font(.caption2.weight(.medium))
                        }
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(bluetooth.isAudioRoutedToMac ? Color.green : Color.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                } else {
                    // Toggle Speakerphone on Phone over Wi-Fi
                    Button {
                        isSpeakerOn.toggle()
                        server.setSpeakerphone(on: isSpeakerOn)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isSpeakerOn ? "speaker.wave.3.fill" : "speaker.wave.1")
                            Text(isSpeakerOn ? "Speaker On" : "Speaker Off")
                                .font(.caption2.weight(.medium))
                        }
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isSpeakerOn ? Color.green : Color.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }

                // End Button
                Button {
                    server.endCall()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "phone.down.fill")
                        Text("End")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.red))
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blue.opacity(0.25), lineWidth: 1))
        }
    }

    // MARK: - Calls Tab View
    private var callsTabView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 1. Audio & Call Companion Status Card
            if bluetooth.isBluetoothPaired {
                HStack(spacing: 12) {
                    Image(systemName: bluetooth.isAudioRoutedToMac ? "speaker.wave.3.fill" : "iphone")
                        .font(.system(size: 18))
                        .foregroundStyle(bluetooth.isAudioRoutedToMac ? Color.green : relayGreen)
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 8).fill(bluetooth.isAudioRoutedToMac ? Color.green.opacity(0.12) : relayGreen.opacity(0.12)))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(bluetooth.isAudioRoutedToMac ? "Mac Mic & Speakers Live" : "Mac Audio Bridge Ready")
                                .font(.subheadline.weight(.semibold))
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                        Text(bluetooth.isAudioRoutedToMac ? "Cellular call audio streaming through Mac speakers" : "Paired with \(bluetooth.pairedDeviceName ?? "Phone") · Calls route to Mac")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(bluetooth.isAudioRoutedToMac ? "Handoff to Phone" : "Connect Mac Audio") {
                        if bluetooth.isAudioRoutedToMac {
                            bluetooth.routeAudioToPhone()
                        } else {
                            bluetooth.connectHandsFree()
                            bluetooth.routeAudioToMac()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 18))
                            .foregroundStyle(relayGreen)
                            .frame(width: 36, height: 36)
                            .background(RoundedRectangle(cornerRadius: 8).fill(relayGreen.opacity(0.12)))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connect Phone for Mac Audio")
                                .font(.subheadline.weight(.semibold))
                            Text("Wi-Fi call control is active · Pair Bluetooth to speak & listen through Mac")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Open Mac Bluetooth") {
                            bluetooth.openBluetoothSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(relayGreen)
                        .controlSize(.small)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .top, spacing: 6) {
                            Text("1.")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(relayGreen)
                            Text("Click **Open Mac Bluetooth** above to make your Mac discoverable.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(alignment: .top, spacing: 6) {
                            Text("2.")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(relayGreen)
                            Text("On your phone (\(server.peerName ?? "Android")), open **Settings > Bluetooth > Pair new device** and tap **\(Host.current().localizedName ?? "Mac")**.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))

                    HStack {
                        Button {
                            bluetooth.refreshDevices(peerNameHint: server.peerName)
                        } label: {
                            Label("Check Bluetooth Connection", systemImage: "arrow.clockwise")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(relayGreen)

                        Spacer()

                        if !bluetooth.availablePhones.isEmpty {
                            Menu {
                                ForEach(bluetooth.availablePhones, id: \.self) { name in
                                    Button(name) {
                                        bluetooth.selectDevice(name: name)
                                    }
                                }
                            } label: {
                                Text("Select paired device…")
                                    .font(.caption)
                            }
                            .menuStyle(.borderlessButton)
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
            }

            // 2. Dialer Card
            VStack(spacing: 14) {
                HStack {
                    TextField("Enter phone number…", text: $dialerNumber)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

                    if !dialerNumber.isEmpty {
                        Button {
                            if !dialerNumber.isEmpty {
                                dialerNumber.removeLast()
                            }
                        } label: {
                            Image(systemName: "delete.left.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 4)
                    }
                }

                // Dial Keypad Grid (3 columns: 1-9, *, 0, #)
                let keypad: [[(String, String)]] = [
                    [("1", ""), ("2", "ABC"), ("3", "DEF")],
                    [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
                    [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
                    [("*", ""), ("0", "+"), ("#", "")]
                ]

                VStack(spacing: 8) {
                    ForEach(0..<keypad.count, id: \.self) { row in
                        HStack(spacing: 12) {
                            ForEach(0..<keypad[row].count, id: \.self) { col in
                                let item = keypad[row][col]
                                Button {
                                    dialerNumber.append(item.0)
                                } label: {
                                    VStack(spacing: 1) {
                                        Text(item.0)
                                            .font(.system(size: 17, weight: .semibold))
                                            .foregroundStyle(Color.primary)
                                        if !item.1.isEmpty {
                                            Text(item.1)
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 38)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Call Button
                Button {
                    let number = dialerNumber.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !number.isEmpty else { return }
                    server.dialNumber(number, routeToMacAudio: bluetooth.isBluetoothPaired)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text(bluetooth.isBluetoothPaired ? "Call from Mac" : "Call on Phone")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(dialerNumber.isEmpty ? Color.secondary.opacity(0.2) : Color.green))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(dialerNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.05)))

            // 3. Quick Call from Synced Contacts
            if !server.smsThreads.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RECENT CONTACTS")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.0)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        ForEach(server.smsThreads.prefix(8)) { thread in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(relayGreen.opacity(0.18))
                                    .frame(width: 30, height: 30)
                                    .overlay(
                                        Text(String((thread.contactName.isEmpty ? thread.address : thread.contactName).prefix(1)).uppercased())
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(relayGreen)
                                    )

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(thread.contactName.isEmpty ? thread.address : thread.contactName)
                                        .font(.subheadline.weight(.medium))
                                    if !thread.address.isEmpty && thread.address != thread.contactName {
                                        Text(thread.address)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                Button {
                                    dialerNumber = thread.address
                                    server.dialNumber(thread.address, routeToMacAudio: bluetooth.isBluetoothPaired)
                                } label: {
                                    Image(systemName: "phone.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white)
                                        .frame(width: 28, height: 28)
                                        .background(Circle().fill(Color.green))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.04)))
                        }
                    }
                }
            }
        }
    }
}
