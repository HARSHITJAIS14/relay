import Foundation
import IOBluetooth
import OSLog
import AppKit

private let logger = Logger(subsystem: "dev.companion", category: "bluetooth")

@MainActor
public final class BluetoothHandsFreeController: NSObject, ObservableObject {
    public static let shared = BluetoothHandsFreeController()

    @Published public private(set) var isBluetoothPaired: Bool = false
    @Published public private(set) var isHandsFreeConnected: Bool = false
    @Published public private(set) var isAudioRoutedToMac: Bool = false
    @Published public private(set) var isMuted: Bool = false
    @Published public private(set) var pairedDeviceName: String? = nil
    @Published public private(set) var statusMessage: String = "Ready"
    @Published public private(set) var availablePhones: [String] = []

    private var targetDevice: IOBluetoothDevice?
    private var handsFree: IOBluetoothHandsFreeDevice?

    public override init() {
        super.init()
        refreshDevices()
    }

    public func refreshDevices(hint: String?) {
        refreshDevices(peerNameHint: hint)
    }

    public func refreshDevices(peerNameHint: String? = nil) {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            isBluetoothPaired = false
            pairedDeviceName = nil
            availablePhones = []
            statusMessage = "No Bluetooth devices paired"
            return
        }

        var candidatePhones: [IOBluetoothDevice] = []
        var matched: IOBluetoothDevice? = nil

        for dev in paired {
            let name = dev.nameOrAddress ?? ""
            let major = dev.deviceClassMajor // 2 = Phone, 4 = Audio (headphones/speakers)

            // CRITICAL: Audio peripherals (headphones, earbuds, headsets, speakers) are audio OUTPUTS, never the phone!
            if major == 4 ||
               name.localizedCaseInsensitiveContains("buds") ||
               name.localizedCaseInsensitiveContains("airpods") ||
               name.localizedCaseInsensitiveContains("airdopes") ||
               name.localizedCaseInsensitiveContains("flip") ||
               name.localizedCaseInsensitiveContains("headphone") ||
               name.localizedCaseInsensitiveContains("headset") ||
               name.localizedCaseInsensitiveContains("speaker") ||
               name.localizedCaseInsensitiveContains("mouse") ||
               name.localizedCaseInsensitiveContains("keyboard") ||
               name.localizedCaseInsensitiveContains("trackpad") {
                continue
            }

            candidatePhones.append(dev)

            // 1. Match by peer name from Relay Wi-Fi pairing (e.g. "I2217" or phone model)
            if let hint = peerNameHint, !hint.isEmpty,
               (name.localizedCaseInsensitiveContains(hint) || hint.localizedCaseInsensitiveContains(name)) {
                matched = dev
                break
            }

            // 2. Match by Bluetooth Major Class 2 (Phone)
            if major == 2 {
                if matched == nil {
                    matched = dev
                }
            }

            // 3. Match known phone brands
            if matched == nil && (
                name.localizedCaseInsensitiveContains("iQOO") ||
                name.localizedCaseInsensitiveContains("Pixel") ||
                name.localizedCaseInsensitiveContains("Galaxy") ||
                name.localizedCaseInsensitiveContains("Phone")
            ) {
                matched = dev
            }
        }

        self.availablePhones = candidatePhones.compactMap { $0.nameOrAddress }

        if let dev = matched {
            self.targetDevice = dev
            self.pairedDeviceName = dev.nameOrAddress
            self.isBluetoothPaired = true
            self.statusMessage = "Paired with \(dev.nameOrAddress ?? "Phone")"
            logger.info("Found paired Bluetooth phone: \(dev.nameOrAddress ?? "", privacy: .public)")
        } else {
            self.targetDevice = nil
            self.pairedDeviceName = nil
            self.isBluetoothPaired = false
            self.statusMessage = "Phone not paired via Mac Bluetooth"
        }
    }

    public func selectDevice(name: String) {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }
        if let dev = paired.first(where: { ($0.nameOrAddress ?? "") == name }) {
            self.targetDevice = dev
            self.pairedDeviceName = dev.nameOrAddress
            self.isBluetoothPaired = true
            self.statusMessage = "Selected \(dev.nameOrAddress ?? "Phone")"
        }
    }

    public func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    public func connectHandsFree() {
        if targetDevice == nil {
            refreshDevices()
        }
        guard let device = targetDevice else {
            statusMessage = "Please pair your phone in macOS Bluetooth settings"
            return
        }

        if handsFree == nil {
            handsFree = IOBluetoothHandsFreeDevice(device: device, delegate: self)
        }

        statusMessage = "Connecting Hands-Free Audio…"
        handsFree?.connect()
    }

    public func disconnectHandsFree() {
        handsFree?.disconnect()
        isHandsFreeConnected = false
        isAudioRoutedToMac = false
        statusMessage = "Disconnected"
    }

    public func routeAudioToMac() {
        guard let hf = handsFree else {
            connectHandsFree()
            return
        }
        logger.info("Routing call audio to Mac speakers & microphone")
        hf.connectSCO()
        hf.transferAudioToComputer()
        isAudioRoutedToMac = true
        statusMessage = "Audio routed to Mac"
    }

    public func routeAudioToPhone() {
        guard let hf = handsFree else { return }
        logger.info("Handoff audio back to phone handset")
        hf.transferAudioToPhone()
        hf.disconnectSCO()
        isAudioRoutedToMac = false
        statusMessage = "Audio routed to phone"
    }

    public func toggleMute() {
        guard let hf = handsFree else { return }
        isMuted.toggle()
        hf.isInputMuted = isMuted
        logger.info("Mute set to \(self.isMuted)")
    }

    public func acceptCall() {
        handsFree?.acceptCall()
        routeAudioToMac()
    }

    public func endCall() {
        handsFree?.endCall()
        routeAudioToPhone()
    }
}

extension BluetoothHandsFreeController {
    @objc func handsFree(_ handsFree: IOBluetoothHandsFreeDevice, isConnected: NSNumber) {
        Task { @MainActor in
            self.isHandsFreeConnected = isConnected.boolValue
            if isConnected.boolValue {
                self.statusMessage = "Hands-Free Connected"
                logger.info("Bluetooth Hands-Free SLC connected")
            } else {
                self.statusMessage = "Hands-Free Disconnected"
                self.isAudioRoutedToMac = false
                logger.info("Bluetooth Hands-Free SLC disconnected")
            }
        }
    }

    @objc func handsFree(_ handsFree: IOBluetoothHandsFreeDevice, isSCOConnected: NSNumber) {
        Task { @MainActor in
            self.isAudioRoutedToMac = isSCOConnected.boolValue
            logger.info("Bluetooth SCO Audio state: \(isSCOConnected.boolValue)")
            if isSCOConnected.boolValue {
                self.statusMessage = "Call audio live on Mac speaker & mic"
            }
        }
    }
}
