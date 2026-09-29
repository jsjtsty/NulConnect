import Foundation
import os

/// Runtime switch for diagnostic logging. Lines go through libreatrust's
/// shared log writer, which appends to `NulConnect.log` in the log directory
/// and rotates it at 5 MB.
nonisolated enum NulConnectLog {
    private static let enabledState = OSAllocatedUnfairLock(initialState: false)

    static var isEnabled: Bool {
        enabledState.withLock { $0 }
    }

    static func setEnabled(_ enabled: Bool) {
        enabledState.withLock { $0 = enabled }
        atr_set_verbose_logging(enabled)
    }

    static var directoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NulConnect", isDirectory: true)
    }

    static func write(_ message: String) {
        message.withCString { atr_log_write($0) }
    }
}

@inline(__always)
nonisolated func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    guard NulConnectLog.isEnabled else { return }
    NulConnectLog.write(items.map { String(describing: $0) }.joined(separator: separator))
}
