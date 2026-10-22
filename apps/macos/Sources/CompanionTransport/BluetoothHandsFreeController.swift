import Foundation
import IOBluetooth
import OSLog

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

    private var targetDevice: IOBluetoothDevice?
    private var handsFree: IOBluetoothHandsFreeDevice?

    public override init() {
        super.init()
        refreshDevices()
    }

    public func refreshDevices(hint: String? = nil) {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            isBluetoothPaired = false
            pairedDeviceName = nil
            statusMessage = "No Bluetooth devices paired"
            return
        }

        // Search for device matching phone name hint or Android device signatures
        var matched: IOBluetoothDevice? = nil
        for dev in paired {
            let name = dev.nameOrAddress ?? ""
            if let h = hint, !h.isEmpty, name.localizedCaseInsensitiveContains(h) {
                matched = dev
                break
            }
            if name.localizedCaseInsensitiveContains("iQOO") ||
               name.localizedCaseInsensitiveContains("Pixel") ||
               name.localizedCaseInsensitiveContains("Samsung") ||
               name.localizedCaseInsensitiveContains("Phone") ||
               name.localizedCaseInsensitiveContains("Android") ||
               name.localizedCaseInsensitiveContains("OnePlus") ||
               name.localizedCaseInsensitiveContains("Xiaomi") {
                matched = dev
                break
            }
        }

        // Fallback: If only one paired device and it's not a mouse/keyboard
        if matched == nil {
            for dev in paired {
                let name = dev.nameOrAddress ?? ""
                if !name.localizedCaseInsensitiveContains("mouse") &&
                   !name.localizedCaseInsensitiveContains("keyboard") &&
                   !name.localizedCaseInsensitiveContains("trackpad") {
                    matched = dev
                    break
                }
            }
        }

        if let dev = matched {
            self.targetDevice = dev
            self.pairedDeviceName = dev.nameOrAddress
            self.isBluetoothPaired = true
            self.statusMessage = "Paired with \(dev.nameOrAddress ?? "Phone")"
            logger.info("Found paired Bluetooth device: \(dev.nameOrAddress ?? "", privacy: .public)")
        } else {
            self.isBluetoothPaired = false
            self.pairedDeviceName = nil
            self.statusMessage = "Phone not paired via Mac Bluetooth"
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
