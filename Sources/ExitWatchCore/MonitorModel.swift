import Foundation
import Combine
import Network
import UserNotifications

@MainActor
public final class MonitorModel: ObservableObject {
    @Published public private(set) var status: MonitorStatus = .idle
    @Published public private(set) var probes: [ProbeResult] = []
    @Published public private(set) var lastCheckedAt: Date?
    @Published public private(set) var isChecking = false
    @Published public private(set) var networkInterfaceLabel = "未检测"

    @Published public var checkIntervalSeconds: Double {
        didSet {
            UserDefaults.standard.set(checkIntervalSeconds, forKey: Self.intervalKey)
        }
    }

    @Published public var alertsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(alertsEnabled, forKey: Self.alertsKey)
            if !alertsEnabled {
                previousAlertSignature = nil
                previousPrivacyAlertSignature = nil
                previousAgentGuardNotificationSignature = nil
                pathAlertSignature = nil
            } else {
                Task { [weak self] in
                    guard let self else { return }
                    await self.requestNotificationPermission()
                    if self.networkPathUnavailable {
                        self.notifyNetworkPathUnavailableIfNeeded(interface: self.lastNetworkInterface)
                    }
                }
            }
        }
    }

    public let definitions: [ProbeDefinition]
    public var onStatusChange: ((MonitorStatus) -> Void)?
    public var onNetworkPathChange: (() -> Void)?

    private let service: IPProbeService
    private var loopTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(
        label: "com.illegalcreed.exitwatch.network-path",
        qos: .utility
    )
    private var networkPathUnavailable = false
    private var hasObservedNetworkPath = false
    private var lastNetworkInterface: String?
    private var pathAlertSignature: String?
    private var previousAlertSignature: String?
    private var previousPrivacyAlertSignature: String?
    private var previousAgentGuardNotificationSignature: String?

    private static let intervalKey = "ExitWatch.checkIntervalSeconds"
    private static let alertsKey = "ExitWatch.alertsEnabled"

    public init(
        service: IPProbeService = IPProbeService(),
        definitions: [ProbeDefinition] = DefaultProbes.all
    ) {
        self.service = service
        self.definitions = definitions

        let savedInterval = UserDefaults.standard.double(forKey: Self.intervalKey)
        self.checkIntervalSeconds = savedInterval > 0 ? min(max(savedInterval, 15), 600) : 60
        self.alertsEnabled = UserDefaults.standard.object(forKey: Self.alertsKey) as? Bool ?? true
    }

    deinit {
        loopTask?.cancel()
        pathMonitor?.cancel()
    }

    public func start() {
        guard loopTask == nil else { return }
        startNetworkPathMonitor()
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.requestNotificationPermission()
            await self.performCheck()

            while !Task.isCancelled {
                let nanoseconds = UInt64(max(self.checkIntervalSeconds, 15) * 1_000_000_000)
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    break
                }
                if Task.isCancelled { break }
                await self.performCheck()
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        networkPathUnavailable = false
        hasObservedNetworkPath = false
        lastNetworkInterface = nil
        networkInterfaceLabel = "未检测"
        pathAlertSignature = nil
    }

    public func refresh() {
        guard !isChecking else { return }
        Task { [weak self] in
            await self?.performCheck()
        }
    }

    private func startNetworkPathMonitor() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let unavailable = path.status != .satisfied
            let interface = Self.interfaceName(for: path)
            Task { @MainActor [weak self] in
                self?.handleNetworkPathUpdate(
                    unavailable: unavailable,
                    interface: interface
                )
            }
        }
        monitor.start(queue: pathMonitorQueue)
    }

    private func handleNetworkPathUpdate(unavailable: Bool, interface: String?) {
        let wasUnavailable = networkPathUnavailable
        let wasObserved = hasObservedNetworkPath
        let interfaceChanged = lastNetworkInterface != nil && lastNetworkInterface != interface

        hasObservedNetworkPath = true
        networkPathUnavailable = unavailable
        lastNetworkInterface = interface
        networkInterfaceLabel = interface ?? (unavailable ? "网络不可用" : "其他接口")

        if unavailable {
            setStatus(.offline)

            // The first callback can be unsatisfied while macOS is still
            // bringing the interface up. Let the initial probe establish the
            // baseline before showing a banner for that transient state.
            guard wasObserved, !wasUnavailable else { return }

            notifyNetworkPathUnavailableIfNeeded(interface: interface)
            return
        }

        if wasUnavailable {
            pathAlertSignature = nil
            previousAlertSignature = nil
            onNetworkPathChange?()
            refresh()
        } else if interfaceChanged {
            // A Wi‑Fi/VPN/interface switch can change the egress even when
            // the path remains satisfied, so run a fresh check immediately.
            onNetworkPathChange?()
            refresh()
        }
    }

    private func notifyNetworkPathUnavailableIfNeeded(interface: String?) {
        guard alertsEnabled else { return }
        let signature = "network-path-unavailable:\(interface ?? "unknown")"
        guard signature != pathAlertSignature else { return }
        pathAlertSignature = signature
        previousAlertSignature = signature
        enqueueNotification(
            title: "\(ProductInfo.displayName)：网络路径异常",
            body: "系统网络路径不可用（\(interface ?? "接口未知")），已立即暂停出口判断。"
        )
    }

    nonisolated private static func interfaceName(for path: NWPath) -> String? {
        if path.usesInterfaceType(.wifi) { return "Wi‑Fi" }
        if path.usesInterfaceType(.wiredEthernet) { return "有线网络" }
        if path.usesInterfaceType(.cellular) { return "蜂窝网络" }
        if path.usesInterfaceType(.other) { return "其他接口" }
        return nil
    }

    /// Delivers a deduplicated notification for a privacy-probe risk. This is
    /// intentionally separate from the IP status notification so a resolved
    /// IP risk does not suppress a later DNS/WebRTC risk (or vice versa).
    public func notifyPrivacyRisk(title: String, body: String, signature: String) {
        guard alertsEnabled else {
            previousPrivacyAlertSignature = nil
            return
        }
        guard signature != previousPrivacyAlertSignature else { return }
        previousPrivacyAlertSignature = signature
        enqueueNotification(title: title, body: body)
    }

    public func clearPrivacyRiskNotification() {
        previousPrivacyAlertSignature = nil
    }

    /// Delivers a deduplicated notification after the optional agent guard has
    /// acted on a confirmed CN/HK egress. The guard still closes processes when
    /// notifications are disabled; this method only controls the banner.
    public func notifyAgentGuard(title: String, body: String, signature: String) {
        guard alertsEnabled else {
            previousAgentGuardNotificationSignature = nil
            return
        }
        guard signature != previousAgentGuardNotificationSignature else { return }
        previousAgentGuardNotificationSignature = signature
        enqueueNotification(title: title, body: body)
    }

    public var riskCount: Int {
        probes.filter(\.isBlockedRegion).count
    }

    public var resolvedCount: Int {
        probes.filter(\.isResolved).count
    }

    public var uniqueIPCount: Int {
        Set(probes.compactMap(\.ip)).count
    }

    public var summaryText: String {
        switch status {
        case .idle:
            return "准备检查网络出口"
        case .checking:
            return "正在检查 \(definitions.count) 个出口探针…"
        case .risk:
            return "\(riskCount) 个探针位于中国大陆或中国香港"
        case .unknown:
            return "部分探针失败或地理信息不完整"
        case .offline:
            return "暂时无法连接探针服务，请检查网络"
        case .safe:
            if uniqueIPCount > 1 {
                return "出口均不在风险地区，但检测到 \(uniqueIPCount) 个不同 IP"
            }
            return "所有探针均不在中国大陆或中国香港"
        }
    }

    private func performCheck() async {
        guard !isChecking else { return }
        isChecking = true
        setStatus(.checking)

        let results = await service.check(definitions)
        probes = results
        lastCheckedAt = Date()

        let nextStatus = evaluate(results)
        setStatus(nextStatus)
        handleNotification(for: nextStatus, results: results)
        isChecking = false
    }

    private func evaluate(_ results: [ProbeResult]) -> MonitorStatus {
        guard !networkPathUnavailable else { return .offline }
        guard !results.isEmpty else { return .offline }
        let withIP = results.filter(\.hasIP)
        guard !withIP.isEmpty else { return .offline }
        if withIP.contains(where: \.isBlockedRegion) { return .risk }
        if results.contains(where: { !$0.hasIP }) { return .unknown }
        if withIP.contains(where: { $0.geo == nil }) { return .unknown }
        return .safe
    }

    private func setStatus(_ newStatus: MonitorStatus) {
        status = newStatus
        onStatusChange?(newStatus)
    }

    private func handleNotification(for newStatus: MonitorStatus, results: [ProbeResult]) {
        guard alertsEnabled else {
            previousAlertSignature = nil
            return
        }

        guard newStatus.isAlert else {
            previousAlertSignature = nil
            return
        }

        // A path-level notification has already explained this outage. Keep
        // the next polling result from producing a duplicate banner until the
        // path recovers.
        if newStatus == .offline, let pathAlertSignature {
            previousAlertSignature = pathAlertSignature
            return
        }

        let signature = results
            .filter { $0.isBlockedRegion || $0.errorMessage != nil || !$0.isResolved }
            .map { "\($0.id):\($0.ip ?? "-"): \($0.geo?.countryCode ?? "-")" }
            .sorted()
            .joined(separator: "|")
        guard signature != previousAlertSignature else { return }
        previousAlertSignature = signature

        let risky = results.filter(\.isBlockedRegion).map { result in
            let place = result.geo?.locationText ?? "位置未知"
            return "\(result.definition.name)：\(result.ip ?? "未知 IP")（\(place)）"
        }
        let body: String
        if newStatus == .offline {
            body = "所有探针暂时无法连接，请确认代理是否掉线。"
        } else if !risky.isEmpty {
            body = risky.joined(separator: "\n")
        } else {
            let incomplete = results
                .filter { $0.errorMessage != nil || !$0.isResolved }
                .map { result in
                    let detail = result.errorMessage ?? "数据不完整"
                    return "\(result.definition.name)：\(detail)"
                }
            body = incomplete.isEmpty
                ? "部分探针返回的数据不完整，请检查代理与网络状态。"
                : incomplete.joined(separator: "\n")
        }

        let title: String
        switch newStatus {
        case .risk:
            title = "\(ProductInfo.displayName)：发现风险 IP"
        case .offline:
            title = "\(ProductInfo.displayName)：探针不可用"
        case .unknown:
            title = "\(ProductInfo.displayName)：网络状态异常"
        case .idle, .checking, .safe:
            return
        }
        enqueueNotification(title: title, body: body)
    }

    private func enqueueNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "exitwatch-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func requestNotificationPermission() async {
        guard alertsEnabled else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
}
