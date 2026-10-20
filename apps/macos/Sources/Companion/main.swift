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
        MenuBarExtra("Relay", systemImage: "link") {
            CompanionView(server: server)
                .frame(width: 460)
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
    @State private var host = ""
    @State private var textToSend = ""
    @State private var isDropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    if let logoPath = Bundle.main.path(forResource: "MenuBarIcon@2x", ofType: "png"),
                       let nsImg = NSImage(contentsOfFile: logoPath) {
                        Image(nsImage: nsImg)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "link")
                            .font(.title3.weight(.bold))
                    }
                    Text("Relay")
                        .font(.title3.weight(.bold))
                    Spacer()
                    if let peer = server.peerName {
                        HStack(spacing: 5) {
                            Circle().fill(Color.green).frame(width: 7, height: 7)
                            Text(peer)
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
                Divider()
                if let request = server.pending {
                    Text("Pair with \(request.name)?").font(.headline)
                    Text(request.code).font(.system(.title, design: .monospaced)).textSelection(.enabled)
                    Text("Check that this code matches the phone.")
                    HStack {
                        Button("Approve pairing") { server.approve() }
                        Button("Reject") { server.reject() }
                    }
                } else if server.peerName == nil {
                    Text("Pair your phone").font(.headline)
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
                                    .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
                                Text("Scan with Relay on your phone to pair")
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
                    Text("Trusted phone: \(server.peerName!)").font(.headline)

                    // Drag and Drop Zone
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                                          style: StrokeStyle(lineWidth: 2, dash: [6]))
                            .background(RoundedRectangle(cornerRadius: 12)
                                .fill(isDropTargeted ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05)))
                            .frame(height: 80)
                        VStack(spacing: 4) {
                            Image(systemName: "arrow.down.doc")
                                .font(.title3)
                                .foregroundColor(.accentColor)
                            Text("Drag & drop files here to send")
                                .font(.callout)
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
                        Text("Capture from Phone").font(.headline)
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
                            Button("📸 Take Photo") {
                                Task { await server.requestCapture(mode: "photo") }
                            }
                            Button("📄 Scan Document") {
                                Task { await server.requestCapture(mode: "scan") }
                            }
                        }
                    }

                    Divider()

                    // Clipboard & Text sharing
                    HStack {
                        Text("Continuous Clipboard").font(.headline)
                        Spacer()
                        Toggle("", isOn: $server.clipboardSyncEnabled)
                            .labelsHidden()
                    }
                    Text("Copying on Mac automatically updates your phone's clipboard.")
                        .font(.caption).foregroundStyle(.secondary)

                    HStack {
                        TextField("Paste or type link/text…", text: $textToSend)
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
                                            .foregroundColor(.accentColor)
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
                    Toggle("Launch Companion at login", isOn: $server.launchAtLogin)
                        .font(.subheadline)
                    Button("Forget phone", role: .destructive) { server.forget() }
                }
                Text("Development build • files up to 100 MiB • original filenames retained")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .task { await server.start() }
    }
}
