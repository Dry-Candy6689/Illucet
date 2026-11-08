import Foundation
import Network

enum NetworkInterfaceKind: String, Codable, Equatable, Sendable {
    case unavailable
    case wifi
    case cellular
    case wiredEthernet
    case other
}

struct NetworkPathSnapshot: Codable, Equatable, Sendable {
    let isSatisfied: Bool
    let interface: NetworkInterfaceKind
    let isExpensive: Bool
    let isConstrained: Bool

    static let unavailable = Self(
        isSatisfied: false,
        interface: .unavailable,
        isExpensive: false,
        isConstrained: false
    )

    var isUnmeteredLocalNetwork: Bool {
        isSatisfied
            && (interface == .wifi || interface == .wiredEthernet)
            && !isExpensive
            && !isConstrained
    }
}

enum NetworkAccessDecision: Equatable, Sendable {
    case allow
    case waitForConnectivity
    case waitForWiFi
    case waitForUnmeteredNetwork
    case waitForUnconstrainedNetwork
    case requireCellularConfirmation
}

struct NetworkAccessPolicy: Equatable, Sendable {
    var wifiOnly: Bool
    var askBeforeCellular: Bool
    var allowsExpensiveAccess: Bool
    var allowsConstrainedAccess: Bool

    init(
        wifiOnly: Bool,
        askBeforeCellular: Bool,
        allowsExpensiveAccess: Bool = true,
        allowsConstrainedAccess: Bool = true
    ) {
        self.wifiOnly = wifiOnly
        self.askBeforeCellular = askBeforeCellular
        self.allowsExpensiveAccess = allowsExpensiveAccess
        self.allowsConstrainedAccess = allowsConstrainedAccess
    }

    func decision(
        for snapshot: NetworkPathSnapshot,
        cellularApprovalGranted: Bool = false
    ) -> NetworkAccessDecision {
        guard snapshot.isSatisfied else {
            return .waitForConnectivity
        }
        if wifiOnly, !snapshot.isUnmeteredLocalNetwork {
            return .waitForWiFi
        }
        if snapshot.isConstrained, !allowsConstrainedAccess {
            return .waitForUnconstrainedNetwork
        }
        if snapshot.interface == .cellular,
           askBeforeCellular,
           !cellularApprovalGranted {
            return .requireCellularConfirmation
        }
        if snapshot.isExpensive, !allowsExpensiveAccess {
            return .waitForUnmeteredNetwork
        }
        return .allow
    }
}

protocol NetworkPathMonitoring: Sendable {
    var updates: AsyncStream<NetworkPathSnapshot> { get }
    func currentSnapshot() async -> NetworkPathSnapshot
}

/// Production network-path source. The scheduler consumes the typed snapshots;
/// UI code and queue policy never receive `NWPath` objects directly.
final class NetworkPathMonitorService:
    NetworkPathMonitoring,
    @unchecked Sendable
{
    nonisolated let updates: AsyncStream<NetworkPathSnapshot>

    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let continuation:
        AsyncStream<NetworkPathSnapshot>.Continuation
    private var current = NetworkPathSnapshot.unavailable

    init(
        monitor: NWPathMonitor = NWPathMonitor(),
        queue: DispatchQueue = DispatchQueue(
            label: "com.local.illucet.network.scheduler"
        )
    ) {
        self.monitor = monitor
        self.queue = queue
        var captured:
            AsyncStream<NetworkPathSnapshot>.Continuation!
        updates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            captured = $0
        }
        continuation = captured
        monitor.pathUpdateHandler = { [weak self] path in
            self?.receive(path)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
        continuation.finish()
    }

    func currentSnapshot() async -> NetworkPathSnapshot {
        lock.withLock { current }
    }

    private func receive(_ path: NWPath) {
        let snapshot = Self.snapshot(path)
        lock.withLock {
            current = snapshot
        }
        continuation.yield(snapshot)
    }

    private static func snapshot(_ path: NWPath) -> NetworkPathSnapshot {
        let satisfied = path.status == .satisfied
        let interface: NetworkInterfaceKind
        if !satisfied {
            interface = .unavailable
        } else if path.usesInterfaceType(.wifi) {
            interface = .wifi
        } else if path.usesInterfaceType(.cellular) {
            interface = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            interface = .wiredEthernet
        } else {
            interface = .other
        }
        return NetworkPathSnapshot(
            isSatisfied: satisfied,
            interface: interface,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
}
