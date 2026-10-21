import SwiftUI
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

struct CompanionView: View {
    @ObservedObject var server: CompanionServer
    @Environment(\.colorScheme) private var colorScheme
    @State private var host = ""
    @State private var textToSend = ""
    @State private var isDropTargeted = false
    private let relayGreen = Color(red: 0.14, green: 0.36, blue: 0.31)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Two devices. One flow.")
                        .font(.system(size: 28, weight: .medium))
                    Text(server.peerName == nil ? "Your Mac, meet your Android." : "A little less back and forth.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                if let request = server.pending {
                    Text("Pair with \(request.name)?").font(.headline)
                    Text(request.code).font(.system(.title, design: .monospaced)).textSelection(.enabled)
                    Text("Check that this code matches the phone.")
                    HStack {
                        Button("Approve pairing") { server.approve() }
                        Button("Reject") { server.reject() }
                    }
                } else if server.peerName == nil {
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
                    Text("Copy on Mac, then use Relay on your phone to sync or paste. Android may require a tap.")
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
                Divider()
                Label(server.status, systemImage: "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("DIRECT CONNECTION  /  NO ACCOUNT NEEDED")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(colorScheme == .dark ? Color(red: 0.55, green: 0.80, blue: 0.69) : relayGreen)
        .task { await server.start() }
    }
}
