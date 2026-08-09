import Combine
import ExitWatchCore
import Foundation

@MainActor
final class LeakCheckModel: ObservableObject {
    @Published private(set) var dnsStatus: LeakProbeStatus = .idle
    @Published private(set) var dnsResult: DNSLeakResult?
    @Published private(set) var webRTCStatus: LeakProbeStatus = .idle
    @Published private(set) var webRTCResult: WebRTCLeakResult?
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckedAt: Date?
    @Published var automaticChecksEnabled: Bool {
        didSet {
            UserDefaults.standard.set(automaticChecksEnabled, forKey: Self.automaticChecksKey)
        }
    }

    var onPrivacyRisk: ((String, String, String) -> Void)?
    var onPrivacyRiskCleared: (() -> Void)?

    private let dnsService: DNSLeakProbeService
    private let webRTCService: WebRTCProbeService
    private var checkTask: Task<Void, Never>?
    private var lastKnownPublicIPs: Set<String> = []
    private static let automaticChecksKey = "ExitWatch.automaticLeakChecksEnabled"

    init(
        dnsService: DNSLeakProbeService = DNSLeakProbeService(),
        webRTCService: WebRTCProbeService? = nil
    ) {
        self.dnsService = dnsService
        self.webRTCService = webRTCService ?? WebRTCProbeService()
        self.automaticChecksEnabled = UserDefaults.standard.object(forKey: Self.automaticChecksKey) as? Bool ?? true
    }

    deinit {
        checkTask?.cancel()
    }

    func runAll(knownPublicIPs: Set<String>) {
        guard !isChecking else { return }
        lastKnownPublicIPs = knownPublicIPs
        isChecking = true
        dnsStatus = .checking
        webRTCStatus = .checking

        let dnsService = self.dnsService
        let webRTCService = self.webRTCService
        checkTask = Task { [weak self] in
            async let dnsResult = dnsService.check()
            async let webPayload = webRTCService.check()
            let values = await (dnsResult, webPayload)
            guard !Task.isCancelled else { return }
            self?.apply(dnsResult: values.0, webPayload: values.1, knownPublicIPs: knownPublicIPs)
        }
    }

    func runDNSOnly() {
        guard !isChecking else { return }
        isChecking = true
        dnsStatus = .checking

        let dnsService = self.dnsService
        checkTask = Task { [weak self] in
            let result = await dnsService.check()
            guard !Task.isCancelled else { return }
            self?.apply(dnsResult: result)
        }
    }

    func runWebRTCOnly(knownPublicIPs: Set<String>) {
        guard !isChecking else { return }
        lastKnownPublicIPs = knownPublicIPs
        isChecking = true
        webRTCStatus = .checking

        let webRTCService = self.webRTCService
        checkTask = Task { [weak self] in
            let payload = await webRTCService.check()
            guard !Task.isCancelled else { return }
            self?.apply(webPayload: payload, knownPublicIPs: knownPublicIPs)
        }
    }

    func stop() {
        checkTask?.cancel()
        checkTask = nil
        isChecking = false
    }

    private func apply(
        dnsResult: DNSLeakResult? = nil,
        webPayload: WebRTCProbePayload? = nil,
        knownPublicIPs: Set<String>? = nil
    ) {
        if let dnsResult {
            self.dnsResult = dnsResult
            dnsStatus = status(for: dnsResult)
        }

        if let webPayload {
            let expected = knownPublicIPs ?? lastKnownPublicIPs
            let candidates = WebRTCCandidateParser.parse(lines: webPayload.candidateLines)
            let publicAddresses = uniqueAddresses(
                candidates.filter { $0.isPublicAddress }.map(\.address)
            )
            let privateAddresses = uniqueAddresses(
                candidates.filter { $0.isPrivateAddress && !$0.isObfuscatedAddress }.map(\.address)
            )
            let unexpectedPublicAddresses = uniqueAddresses(
                expected.isEmpty
                    ? []
                    : candidates
                        .filter {
                            ($0.candidateType == "host" || $0.candidateType == "srflx") &&
                                $0.isPublicAddress &&
                                !expected.contains($0.address)
                        }
                        .map(\.address)
            )
            let assessment = WebRTCCandidateParser.assess(
                candidates: candidates,
                expectedPublicIPs: expected
            )
            self.webRTCResult = WebRTCLeakResult(
                supported: webPayload.supported,
                candidates: candidates,
                publicAddresses: publicAddresses,
                privateAddresses: privateAddresses,
                unexpectedPublicAddresses: unexpectedPublicAddresses,
                assessment: assessment,
                errorMessage: webPayload.errorMessage
            )
            webRTCStatus = status(for: webPayload, assessment: assessment, candidates: candidates)
        }

        lastCheckedAt = Date()
        isChecking = false
        checkTask = nil
        publishPrivacyState()
    }

    private func apply(dnsResult: DNSLeakResult) {
        apply(dnsResult: dnsResult, webPayload: nil)
    }

    private func apply(webPayload: WebRTCProbePayload, knownPublicIPs: Set<String>) {
        apply(dnsResult: nil, webPayload: webPayload, knownPublicIPs: knownPublicIPs)
    }

    private func status(for result: DNSLeakResult) -> LeakProbeStatus {
        if result.errorMessage != nil && result.resolvers.isEmpty {
            return .failed
        }
        switch result.assessment {
        case .noLeak, .trustedUpstream: return .safe
        case .possibleLeak: return .risk
        case .unknown: return .unknown
        }
    }

    private func status(
        for payload: WebRTCProbePayload,
        assessment: WebRTCLeakAssessment,
        candidates: [WebRTCCandidate]
    ) -> LeakProbeStatus {
        if !payload.supported || payload.errorMessage != nil {
            return .failed
        }
        if candidates.isEmpty {
            return .unknown
        }
        switch assessment {
        case .noLeak: return .safe
        case .possibleLeak: return .risk
        case .unknown: return .unknown
        }
    }

    private func uniqueAddresses(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func publishPrivacyState() {
        var messages: [String] = []
        var signatureParts: [String] = []

        if dnsStatus == .risk {
            let conclusion = dnsResult?.conclusion ?? "DNS 探针报告可能存在泄漏"
            let resolvers = dnsResult?.resolvers.map(\.ip).joined(separator: ", ") ?? "未知解析器"
            messages.append("DNS：\(conclusion)（\(resolvers)）")
            signatureParts.append("dns:\(resolvers):\(conclusion)")
        }

        if webRTCStatus == .risk {
            let unexpected = webRTCResult?.unexpectedPublicAddresses ?? []
            let addresses = unexpected.isEmpty ? "无" : unexpected.joined(separator: ", ")
            let local = webRTCResult?.privateAddresses.joined(separator: ", ") ?? ""
            let detail = local.isEmpty ? "公网候选：\(addresses)" : "公网候选：\(addresses)；本地候选：\(local)"
            messages.append("WebRTC：\(detail)")
            signatureParts.append("webrtc:\(addresses):\(local)")
        }

        guard !messages.isEmpty else {
            onPrivacyRiskCleared?()
            return
        }

        onPrivacyRisk?(
            "\(ProductInfo.displayName)：发现隐私风险",
            messages.joined(separator: "\n"),
            signatureParts.sorted().joined(separator: "|")
        )
    }
}
