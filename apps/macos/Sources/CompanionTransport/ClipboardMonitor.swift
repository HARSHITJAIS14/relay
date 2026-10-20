import Foundation
import AppKit

@MainActor
public final class ClipboardMonitor: ObservableObject {
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var lastObservedString: String?
    private var timer: Timer?
    public var onClipboardChanged: ((String) -> Void)?

    public var currentString: String? {
        NSPasteboard.general.string(forType: .string)
    }

    public init() {}

    public func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        lastObservedString = NSPasteboard.general.string(forType: .string)
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount
        guard let currentString = NSPasteboard.general.string(forType: .string),
              !currentString.isEmpty,
              currentString != lastObservedString else { return }
        lastObservedString = currentString
        onClipboardChanged?(currentString)
    }

    public func applyRemoteText(_ text: String) {
        lastObservedString = text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastChangeCount = NSPasteboard.general.changeCount
    }
}
