import Combine
import ExitWatchCore
import Foundation

@MainActor
final class AgentGuardModel: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled {
                evaluateCurrentState()
            } else {
                actionTask?.cancel()
                actionTask = nil
                lastRiskSignature = nil
                lastActionText = "自动关闭已关闭"
            }
        }
    }

    @Published private(set) var lastActionText: String?

    var onAgentsClosed: ((String, String, String) -> Void)?

    private let service: AgentGuardService
    private var actionTask: Task<Void, Never>?
    private var currentStatus: MonitorStatus = .idle
    private var currentProbes: [ProbeResult] = []
    private var lastRiskSignature: String?

    private static let enabledKey = "ExitWatch.agentGuardEnabled"

    init(service: AgentGuardService? = nil) {
        self.service = service ?? AgentGuardService()
        self.enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
    }

    deinit {
        actionTask?.cancel()
    }

    func update(status: MonitorStatus, probes: [ProbeResult]) {
        currentStatus = status
        currentProbes = probes

        guard status == .risk else {
            lastRiskSignature = nil
            return
        }
        evaluateCurrentState()
    }

    func stop() {
        actionTask?.cancel()
        actionTask = nil
    }

    private func evaluateCurrentState() {
        guard enabled, currentStatus == .risk, actionTask == nil else { return }

        let risky = currentProbes.filter(\.isBlockedRegion)
        guard !risky.isEmpty else { return }

        let signature = risky
            .map { "\($0.id):\($0.ip ?? "-"):\($0.geo?.countryCode ?? "-")" }
            .sorted()
            .joined(separator: "|")
        guard signature != lastRiskSignature else { return }
        lastRiskSignature = signature

        let service = self.service
        actionTask = Task { [weak self] in
            let outcome = await service.terminateAgents()
            guard !Task.isCancelled else { return }
            self?.apply(outcome: outcome)
        }
    }

    private func apply(outcome: AgentTerminationOutcome) {
        actionTask = nil

        guard !outcome.discovered.isEmpty else {
            lastActionText = "已检测到风险出口，未发现正在运行的 Claude Code 或 ChatGPT。"
            return
        }

        let terminatedNames = uniqueNames(outcome.terminated)
        let failedNames = uniqueNames(outcome.failed)
        let forcedNames = uniqueNames(outcome.forceTerminated)

        if terminatedNames.isEmpty {
            lastActionText = "尝试关闭 Claude Code / ChatGPT 失败，请手动处理。"
        } else {
            var text = "已关闭：\(terminatedNames.joined(separator: "、"))"
            if !forcedNames.isEmpty {
                text += "（\(forcedNames.joined(separator: "、"))使用强制结束）"
            }
            if !failedNames.isEmpty {
                text += "；未能关闭：\(failedNames.joined(separator: "、"))"
            }
            lastActionText = text
        }

        let body: String
        if terminatedNames.isEmpty {
            body = "出口已回到中国大陆或中国香港，但无法关闭：\(failedNames.isEmpty ? "目标进程" : failedNames.joined(separator: "、"))。"
        } else if failedNames.isEmpty {
            body = "出口已回到中国大陆或中国香港，已关闭：\(terminatedNames.joined(separator: "、"))。"
        } else {
            body = "出口已回到中国大陆或中国香港，已关闭：\(terminatedNames.joined(separator: "、"))；未能关闭：\(failedNames.joined(separator: "、"))。"
        }
        let title = terminatedNames.isEmpty
            ? "\(ProductInfo.displayName)：自动关闭失败"
            : "\(ProductInfo.displayName)：已关闭代理软件"
        let signature = "agent-guard:\(lastRiskSignature ?? ""):\(outcome.discovered.map(\.id).sorted().joined(separator: "|"))"
        onAgentsClosed?(title, body, signature)
    }

    private func uniqueNames(_ processes: [GuardedAgentProcess]) -> [String] {
        var seen = Set<String>()
        return processes
            .map(\.displayName)
            .filter { seen.insert($0).inserted }
    }
}
