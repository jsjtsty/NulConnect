import AppKit
import Network

/// A summary of the physical network the Mac is currently using.
nonisolated struct NulConnectNetworkSnapshot: Equatable, Sendable {
    /// A physical interface (Wi-Fi, Ethernet, cellular, …) has a usable path.
    var isAvailable: Bool
    /// Identifies the network: the primary physical interface plus its
    /// gateways. Changes when switching Wi-Fi networks or plugging in
    /// Ethernet; `nil` while no network is available.
    var fingerprint: String?

    static let unknown = NulConnectNetworkSnapshot(isAvailable: true, fingerprint: nil)

    init(isAvailable: Bool, fingerprint: String?) {
        self.isAvailable = isAvailable
        self.fingerprint = fingerprint
    }

    init(path: NWPath) {
        // Our own utun (and other VPN tunnels) report as `.other`; they must
        // not count as connectivity or change the fingerprint.
        let physical = path.availableInterfaces.filter {
            $0.type != .loopback && $0.type != .other
        }
        guard path.status == .satisfied, let primary = physical.first else {
            self.init(isAvailable: false, fingerprint: nil)
            return
        }
        let gateways = path.gateways.map { "\($0)" }.sorted()
        self.init(
            isAvailable: true,
            fingerprint: ([primary.name] + gateways).joined(separator: "|")
        )
    }
}

/// Reports the network edge cases that break a long-lived tunnel: the
/// physical network going away or changing, and the Mac sleeping and waking.
@MainActor
final class NulConnectNetworkMonitor {
    enum Event {
        case pathChanged(NulConnectNetworkSnapshot)
        case willSleep
        case didWake(sleptFor: TimeInterval)
    }

    private(set) var snapshot: NulConnectNetworkSnapshot = .unknown

    private let pathMonitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.nulstudio.NulConnect.network-monitor")
    private var observers: [NSObjectProtocol] = []
    private var sleepStartedAt: Date?
    private var handler: ((Event) -> Void)?

    func start(handler: @escaping (Event) -> Void) {
        guard self.handler == nil else { return }
        self.handler = handler

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let snapshot = NulConnectNetworkSnapshot(path: path)
            Task { @MainActor [weak self] in
                self?.apply(snapshot)
            }
        }
        pathMonitor.start(queue: queue)

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWillSleep()
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDidWake()
            }
        })
    }

    func stop() {
        pathMonitor.cancel()
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        handler = nil
    }

    private func apply(_ snapshot: NulConnectNetworkSnapshot) {
        guard snapshot != self.snapshot else { return }
        NulConnectDiagnostics.log(
            "[NulConnect][Network] path changed available=\(snapshot.isAvailable) changedNetwork=\(snapshot.fingerprint != self.snapshot.fingerprint)"
        )
        self.snapshot = snapshot
        handler?(.pathChanged(snapshot))
    }

    private func handleWillSleep() {
        sleepStartedAt = Date()
        NulConnectDiagnostics.log("[NulConnect][Network] system will sleep")
        handler?(.willSleep)
    }

    private func handleDidWake() {
        let sleptFor = sleepStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        sleepStartedAt = nil
        NulConnectDiagnostics.log("[NulConnect][Network] system did wake sleptFor=\(Int(sleptFor))s")
        handler?(.didWake(sleptFor: sleptFor))
    }
}
