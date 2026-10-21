import XCTest
import Foundation
@testable import CompanionTransport

final class LiveDeviceIntegrationTests: XCTestCase {
    private static let adb = "/opt/homebrew/bin/adb"

    private static func runAdbSync(_ arguments: [String]) throws -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func launchAdbAsync(_ arguments: [String]) throws -> (process: Process, readOutput: @Sendable () -> String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        return (process, {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        })
    }

    private func getMacWiFiIP() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let lines = (String(data: data, encoding: .utf8) ?? "").components(separatedBy: "\n")
        for line in lines {
            if line.contains("inet ") && !line.contains("127.0.0.1") {
                let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
                if parts.count >= 2 {
                    let ip = parts[1]
                    if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.") {
                        return ip
                    }
                }
            }
        }
        return nil
    }

    func testLivePairingAndBidirectionalTransfer() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Skipping live device integration tests unless RUN_LIVE_TESTS=1")
        }
        // 1. Verify ADB device is attached
        guard FileManager.default.fileExists(atPath: Self.adb) else {
            throw XCTSkip("ADB binary not found at \(Self.adb)")
        }
        let devicesResult = try Self.runAdbSync(["devices"])
        guard devicesResult.output.contains("\tdevice") else {
            throw XCTSkip("No authorized device connected via ADB: \(devicesResult.output)")
        }

        guard let macIP = getMacWiFiIP() else {
            throw XCTSkip("Could not determine Mac Wi-Fi IP address")
        }
        print("Using Mac Wi-Fi IP: \(macIP)")
        fflush(stdout)

        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killProcess.arguments = ["-9", "-x", "Companion"]
        try? killProcess.run()
        killProcess.waitUntilExit()
        try await Task.sleep(nanoseconds: 500_000_000)

        // 2. Start Companion server on Mac
        let server = await CompanionServer()
        await server.forget() // Ensure fresh start
        await server.start()
        defer {
            Task { @MainActor in
                server.stop()
            }
        }

        // Wait up to 3 seconds for listener to be ready
        for _ in 0..<30 {
            let fp = await server.fingerprint
            if !fp.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let macFingerprint = await server.fingerprint
        XCTAssertFalse(macFingerprint.isEmpty, "Server should have a valid fingerprint")

        // 3. Clear phone app state and create invitation
        _ = try Self.runAdbSync(["shell", "pm", "clear", "dev.companion.android"])
        await server.createInvitation(host: macIP)
        let invitation = await server.invitation
        XCTAssertFalse(invitation.isEmpty, "Invitation URL must not be empty")
        print("Created pairing invitation: \(invitation)")

        // 4. Launch instrumented test for pairing on the phone asynchronously
        let (adbProcess, readOutput) = try Self.launchAdbAsync([
            "shell", "am", "instrument", "-w",
            "-e", "class", "dev.companion.android.NativeTransferTest#pairingAndUpload",
            "-e", "invitation", "'\(invitation)'",
            "dev.companion.android.test/androidx.test.runner.AndroidJUnitRunner"
        ])

        // 5. Poll for pending pairing request on Mac
        var approved = false
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if let pending = await server.pending {
                print("Observed pending pairing request from: \(pending.name), code: \(pending.code)")
                XCTAssertFalse(pending.code.isEmpty)
                await server.approve()
                approved = true
                break
            }
        }
        XCTAssertTrue(approved, "Pairing request should arrive from phone and be approved")

        // 6. Wait for phone test to complete
        let phoneOutput = readOutput()
        print("Phone pairing and upload result:\n\(phoneOutput)")
        XCTAssertEqual(adbProcess.terminationStatus, 0, "Phone instrumentation test must exit 0")
        XCTAssertTrue(phoneOutput.contains("OK (1 test)"), "Phone test must report OK (1 test)")

        // 7. Verify uploaded file on Mac
        let receiveFolder = await server.receiveFolder
        try FileManager.default.createDirectory(at: receiveFolder, withIntermediateDirectories: true)
        let receivedFiles = try FileManager.default.contentsOfDirectory(at: receiveFolder, includingPropertiesForKeys: nil)
        let phoneUploaded = receivedFiles.first { $0.lastPathComponent.contains("companion-phone-test.bin") }
        XCTAssertNotNil(phoneUploaded, "File companion-phone-test.bin must exist in \(receiveFolder.path)")
        if let phoneUploaded {
            let attributes = try FileManager.default.attributesOfItem(atPath: phoneUploaded.path)
            let size = attributes[.size] as? Int64 ?? 0
            XCTAssertEqual(size, 1024 * 1024 + 17, "Uploaded file size must match expected bytes")
        }

        // 8. Test Mac -> Phone transfer
        let testOutDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testOutDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testOutDir) }

        let sampleFile = testOutDir.appendingPathComponent("mac-test-payload.dat")
        var sampleBytes = [UInt8](repeating: 0, count: 512 * 1024)
        for i in 0..<sampleBytes.count {
            sampleBytes[i] = UInt8(i % 256)
        }
        try Data(sampleBytes).write(to: sampleFile)

        await server.enqueue(sampleFile)
        print("Enqueued mac-test-payload.dat on Mac, receiving on phone...")

        let receiveResult = try Self.runAdbSync([
            "shell", "am", "instrument", "-w",
            "-e", "class", "dev.companion.android.NativeTransferTest#receiveQueuedFile",
            "dev.companion.android.test/androidx.test.runner.AndroidJUnitRunner"
        ])
        print("Phone receive result:\n\(receiveResult.output)")
        XCTAssertEqual(receiveResult.exitCode, 0, "Phone receive instrumentation must exit 0")
        XCTAssertTrue(receiveResult.output.contains("OK (1 test)"), "Phone receive must report OK (1 test)")
    }

    func testReconnectionAndTransferWhenAlreadyPaired() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Skipping live device integration tests unless RUN_LIVE_TESTS=1")
        }
        let devicesResult = try Self.runAdbSync(["devices"])
        guard devicesResult.output.contains("\tdevice") || devicesResult.output.contains(" device") else {
            throw XCTSkip("No authorized device connected via ADB: [\(devicesResult.output)]")
        }

        // 1. Start server with existing peer.json
        let server = await CompanionServer()
        await server.start()
        defer {
            Task { @MainActor in
                server.stop()
            }
        }

        let peer = await server.peerName
        XCTAssertNotNil(peer, "Server must load trusted peer from persistent storage")
        guard let macIP = await CompanionServer.detectLocalIP() else {
            XCTFail("Could not determine the Mac's current LAN address")
            return
        }

        // 2. Run upload test from phone without invitation
        let uploadResult = try Self.runAdbSync([
            "shell", "am", "instrument", "-w",
            "-e", "class", "dev.companion.android.NativeTransferTest#pairingAndUpload",
            "-e", "host", macIP,
            "dev.companion.android.test/androidx.test.runner.AndroidJUnitRunner"
        ])
        print("Reconnection upload result:\n\(uploadResult.output)")
        XCTAssertEqual(uploadResult.exitCode, 0)
        XCTAssertTrue(uploadResult.output.contains("OK (1 test)"))
        guard uploadResult.output.contains("OK (1 test)") else { return }

        let receiveFolder = await server.receiveFolder
        let uploaded = receiveFolder.appendingPathComponent("companion-phone-test.bin")
        let expectedUpload = Data((0..<(1024 * 1024 + 17)).map { UInt8($0 % 251) })
        XCTAssertEqual(try Data(contentsOf: uploaded), expectedUpload, "Phone upload bytes must match")

        // 3. Queue another file on Mac and receive on phone
        let testOutDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testOutDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testOutDir) }

        let sampleFile = testOutDir.appendingPathComponent("reconnect-\(UUID().uuidString).bin")
        let sampleData = Data(repeating: 0x42, count: 256 * 1024)
        try sampleData.write(to: sampleFile)

        await server.enqueue(sampleFile)
        let receiveResult = try Self.runAdbSync([
            "shell", "am", "instrument", "-w",
            "-e", "class", "dev.companion.android.NativeTransferTest#receiveQueuedFile",
            "-e", "expectedName", sampleFile.lastPathComponent,
            "-e", "expectedSha256", digest(sampleData),
            "dev.companion.android.test/androidx.test.runner.AndroidJUnitRunner"
        ])
        print("Reconnection receive result:\n\(receiveResult.output)")
        XCTAssertEqual(receiveResult.exitCode, 0)
        XCTAssertTrue(receiveResult.output.contains("OK (1 test)"))
    }
}

