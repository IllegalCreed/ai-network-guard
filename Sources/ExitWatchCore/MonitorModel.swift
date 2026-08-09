import Foundation
import Combine
import UserNotifications

@MainActor
public final class MonitorModel: ObservableObject {
    @Published public private(set) var status: MonitorStatus = .idle
    @Published public private(set) var probes: [ProbeResult] = []
    @Published public private(set) var lastCheckedAt: Date?
    @Published public private(set) var isChecking = false

    @Published public var checkIntervalSeconds: Double {
        didSet {
            UserDefaults.standard.set(checkIntervalSeconds, forKey: Self.intervalKey)
        }
    }

    @Published public var alertsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(alertsEnabled, forKey: Self.alertsKey)
        }
    }

    public let definitions: [ProbeDefinition]
    public var onStatusChange: ((MonitorStatus) -> Void)?

    private let service: IPProbeService
    private var loopTask: Task<Void, Never>?
    private var previousAlertSignature: String?

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
    }

    public func start() {
        guard loopTask == nil else { return }
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
    }

    public func refresh() {
        guard !isChecking else { return }
        Task { [weak self] in
            await self?.performCheck()
        }
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
            return "部分探针已返回，但地理信息尚未完成"
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
        guard !results.isEmpty else { return .offline }
        let withIP = results.filter(\.hasIP)
        guard !withIP.isEmpty else { return .offline }
        if withIP.contains(where: \.isBlockedRegion) { return .risk }
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

        let signature = results
            .filter { $0.isBlockedRegion || $0.errorMessage != nil }
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
        if risky.isEmpty {
            body = "所有探针暂时无法连接，请确认代理是否掉线。"
        } else {
            body = risky.joined(separator: "\n")
        }

        let content = UNMutableNotificationContent()
        content.title = newStatus == .risk ? "出口守望：发现风险 IP" : "出口守望：探针不可用"
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
