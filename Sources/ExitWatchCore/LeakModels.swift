import Foundation
import Network

/// The state of an on-demand privacy probe.
public enum LeakProbeStatus: String, Sendable, Hashable {
    case idle
    case checking
    case safe
    case risk
    case unknown
    case failed

    public var label: String {
        switch self {
        case .idle: return "尚未检测"
        case .checking: return "检测中"
        case .safe: return "未发现明显泄漏"
        case .risk: return "可能存在泄漏"
        case .unknown: return "无法判断"
        case .failed: return "检测失败"
        }
    }

    public var systemImage: String {
        switch self {
        case .idle: return "questionmark.shield"
        case .checking: return "arrow.triangle.2.circlepath"
        case .safe: return "checkmark.shield.fill"
        case .risk: return "exclamationmark.shield.fill"
        case .unknown: return "questionmark.circle.fill"
        case .failed: return "wifi.exclamationmark"
        }
    }
}

public enum DNSLeakAssessment: String, Sendable, Hashable {
    case noLeak
    /// The remote probe observed a well-known public resolver (for example
    /// Cloudflare or Google). This is common when a TUN client is forwarding
    /// encrypted DNS upstream, but the remote probe cannot prove the transport
    /// protocol by itself, so the UI describes it explicitly rather than
    /// claiming an unconditional clean bill of health.
    case trustedUpstream
    case possibleLeak
    case unknown

    public var label: String {
        switch self {
        case .noLeak: return "未发现明显泄漏"
        case .trustedUpstream: return "受信任 DNS 上游"
        case .possibleLeak: return "探针报告可能泄漏"
        case .unknown: return "结果不足，无法判断"
        }
    }
}

public struct DNSResolverInfo: Identifiable, Sendable, Hashable {
    public let ip: String
    public let countryCode: String?
    public let countryName: String?
    public let asn: String?

    public init(
        ip: String,
        countryCode: String? = nil,
        countryName: String? = nil,
        asn: String? = nil
    ) {
        self.ip = ip
        self.countryCode = countryCode
        self.countryName = countryName
        self.asn = asn
    }

    public var id: String { ip }

    public var locationText: String {
        [countryName, countryCode]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    public var detailText: String {
        [ip, locationText.isEmpty ? nil : locationText, asn]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    /// A provider hint is deliberately conservative: it identifies a known
    /// public resolver organization, not whether this particular request was
    /// encrypted. The latter is handled by the proxy/TUN client.
    public var publicProviderName: String? {
        let value = (asn ?? "").lowercased()
        if value.contains("as13335") || value.contains("cloudflare") {
            return "Cloudflare"
        }
        if value.contains("as15169") || value.contains("google") {
            return "Google"
        }
        if value.contains("as19281") || value.contains("quad9") {
            return "Quad9"
        }
        if value.contains("as36692") || value.contains("opendns") || value.contains("cisco") {
            return "Cisco OpenDNS"
        }
        return nil
    }

    public var isKnownPublicResolver: Bool {
        publicProviderName != nil
    }
}

public struct DNSLeakResult: Sendable, Hashable {
    public let testID: String?
    public let clientIP: String?
    public let resolvers: [DNSResolverInfo]
    public let conclusion: String?
    public let assessment: DNSLeakAssessment
    public let errorMessage: String?
    public let checkedAt: Date

    public init(
        testID: String? = nil,
        clientIP: String? = nil,
        resolvers: [DNSResolverInfo] = [],
        conclusion: String? = nil,
        assessment: DNSLeakAssessment = .unknown,
        errorMessage: String? = nil,
        checkedAt: Date = Date()
    ) {
        self.testID = testID
        self.clientIP = clientIP
        self.resolvers = resolvers
        self.conclusion = conclusion
        self.assessment = assessment
        self.errorMessage = errorMessage
        self.checkedAt = checkedAt
    }
}

public struct WebRTCCandidate: Identifiable, Sendable, Hashable {
    public let address: String
    public let candidateType: String
    public let transport: String
    public let isPrivateAddress: Bool
    public let isPublicAddress: Bool
    public let isObfuscatedAddress: Bool

    public init(
        address: String,
        candidateType: String,
        transport: String,
        isPrivateAddress: Bool,
        isPublicAddress: Bool,
        isObfuscatedAddress: Bool = false
    ) {
        self.address = address
        self.candidateType = candidateType
        self.transport = transport
        self.isPrivateAddress = isPrivateAddress
        self.isPublicAddress = isPublicAddress
        self.isObfuscatedAddress = isObfuscatedAddress
    }

    public var id: String {
        "\(candidateType):\(transport):\(address)"
    }
}

public enum WebRTCLeakAssessment: String, Sendable, Hashable {
    case noLeak
    case possibleLeak
    case unknown

    public var label: String {
        switch self {
        case .noLeak: return "未发现明显泄漏"
        case .possibleLeak: return "发现候选地址泄漏"
        case .unknown: return "结果不足，无法判断"
        }
    }
}

public struct WebRTCLeakResult: Sendable, Hashable {
    public let supported: Bool
    public let candidates: [WebRTCCandidate]
    public let publicAddresses: [String]
    public let privateAddresses: [String]
    public let unexpectedPublicAddresses: [String]
    public let assessment: WebRTCLeakAssessment
    public let errorMessage: String?
    public let checkedAt: Date

    public init(
        supported: Bool,
        candidates: [WebRTCCandidate] = [],
        publicAddresses: [String] = [],
        privateAddresses: [String] = [],
        unexpectedPublicAddresses: [String] = [],
        assessment: WebRTCLeakAssessment = .unknown,
        errorMessage: String? = nil,
        checkedAt: Date = Date()
    ) {
        self.supported = supported
        self.candidates = candidates
        self.publicAddresses = publicAddresses
        self.privateAddresses = privateAddresses
        self.unexpectedPublicAddresses = unexpectedPublicAddresses
        self.assessment = assessment
        self.errorMessage = errorMessage
        self.checkedAt = checkedAt
    }
}

public enum DNSLeakParsingError: LocalizedError, Sendable, Equatable {
    case invalidPayload
    case noResults

    public var errorDescription: String? {
        switch self {
        case .invalidPayload: return "DNS 泄漏探针返回的数据无法解析"
        case .noResults: return "DNS 泄漏探针没有返回结果"
        }
    }
}

/// Parses the small JSON format returned by bash.ws/dnsleak/test/{id}?json.
/// Keeping this parser independent from the network service makes the result
/// handling testable and lets the UI distinguish a real risk from a timeout.
public enum DNSLeakPayloadParser {
    public static func parse(data: Data, testID: String? = nil, checkedAt: Date = Date()) throws -> DNSLeakResult {
        guard let blocks = try? JSONDecoder().decode([DNSLeakBlock].self, from: data) else {
            throw DNSLeakParsingError.invalidPayload
        }
        guard !blocks.isEmpty else {
            throw DNSLeakParsingError.noResults
        }

        let clientIP = blocks.first(where: { $0.type == "ip" })?.ip?.trimmedNonEmpty
        var seenIPs = Set<String>()
        let resolvers = blocks
            .filter { $0.type == "dns" }
            .compactMap { block -> DNSResolverInfo? in
                guard let ip = block.ip?.trimmedNonEmpty, seenIPs.insert(ip).inserted else {
                    return nil
                }
                return DNSResolverInfo(
                    ip: ip,
                    countryCode: block.country?.trimmedNonEmpty,
                    countryName: block.countryName?.trimmedNonEmpty,
                    asn: block.asn?.trimmedNonEmpty
                )
            }

        let conclusion = blocks
            .first(where: { $0.type == "conclusion" })?
            .ip?
            .trimmedNonEmpty
        let assessment = assess(conclusion: conclusion, resolvers: resolvers)

        return DNSLeakResult(
            testID: testID,
            clientIP: clientIP,
            resolvers: resolvers,
            conclusion: conclusion,
            assessment: assessment,
            checkedAt: checkedAt
        )
    }

    private static func assess(
        conclusion: String?,
        resolvers: [DNSResolverInfo]
    ) -> DNSLeakAssessment {
        guard let conclusion else { return .unknown }

        let normalized = conclusion
            .lowercased()
            .replacingOccurrences(of: "–", with: "-")

        if normalized.contains("may be leaking") ||
            normalized.contains("possible leak") ||
            (normalized.contains("leak") &&
                !normalized.contains("no leak") &&
                !normalized.contains("not leaking") &&
                !normalized.contains("does not leak")) {
            // bash.ws reports the public resolver it observes, but it cannot
            // tell whether the client reached that resolver using DoH/DoT or
            // plain UDP. If every resolver belongs to a well-known public
            // provider, make that ambiguity visible instead of presenting it
            // as a confirmed local/ISP DNS leak.
            if !resolvers.isEmpty && resolvers.allSatisfy(\.isKnownPublicResolver) {
                return .trustedUpstream
            }
            return .possibleLeak
        }

        if normalized.contains("no leak") ||
            normalized.contains("not leaking") ||
            normalized.contains("does not leak") ||
            normalized.contains("secure") {
            return .noLeak
        }

        return .unknown
    }
}

private struct DNSLeakBlock: Decodable {
    let ip: String?
    let country: String?
    let countryName: String?
    let asn: String?
    let type: String?

    enum CodingKeys: String, CodingKey {
        case ip, country, asn, type
        case countryName = "country_name"
    }
}

/// Parses ICE candidate lines emitted by RTCPeerConnection. The parser is
/// deliberately conservative: relay addresses are displayed but do not count
/// as a local/public leak because they belong to the TURN relay.
public enum WebRTCCandidateParser {
    public static func parse(lines: [String]) -> [WebRTCCandidate] {
        var seen = Set<String>()
        var values: [WebRTCCandidate] = []

        for rawLine in lines {
            let line = rawLine
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "a=candidate:", with: "candidate:")
            guard !line.isEmpty, line.lowercased() != "end-of-candidates" else { continue }

            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 8 else { continue }

            let addressIndex = 4
            guard tokens.indices.contains(addressIndex),
                  let typeIndex = tokens.firstIndex(where: { $0.lowercased() == "typ" }),
                  tokens.indices.contains(typeIndex + 1) else {
                continue
            }

            let address = tokens[addressIndex].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let candidateType = tokens[typeIndex + 1].lowercased()
            let transport = tokens.count > 2 ? tokens[2].lowercased() : "unknown"
            guard !address.isEmpty else { continue }

            let classification = classify(address: address)
            let candidate = WebRTCCandidate(
                address: address,
                candidateType: candidateType,
                transport: transport,
                isPrivateAddress: classification.isPrivate,
                isPublicAddress: classification.isPublic,
                isObfuscatedAddress: classification.isObfuscated
            )
            guard seen.insert(candidate.id).inserted else { continue }
            values.append(candidate)
        }

        return values
    }

    public static func assess(
        candidates: [WebRTCCandidate],
        expectedPublicIPs: Set<String>
    ) -> WebRTCLeakAssessment {
        let normalizedExpected = Set(expectedPublicIPs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let directCandidates = candidates.filter { $0.candidateType == "host" || $0.candidateType == "srflx" }
        let unexpectedPublic = normalizedExpected.isEmpty
            ? []
            : directCandidates.filter {
                $0.isPublicAddress && !normalizedExpected.contains($0.address)
            }

        if !unexpectedPublic.isEmpty {
            return .possibleLeak
        }

        let literalPrivateHost = candidates.contains {
            $0.candidateType == "host" && $0.isPrivateAddress && !$0.isObfuscatedAddress
        }
        if literalPrivateHost {
            return .possibleLeak
        }

        let matchedPublic = directCandidates.contains {
            $0.isPublicAddress && normalizedExpected.contains($0.address)
        }
        if matchedPublic {
            return .noLeak
        }

        return .unknown
    }

    private static func classify(address: String) -> (isPrivate: Bool, isPublic: Bool, isObfuscated: Bool) {
        if address.lowercased().hasSuffix(".local") {
            return (false, false, true)
        }

        if let ipv4 = IPv4Address(address) {
            let bytes = Array(ipv4.rawValue)
            guard bytes.count == 4 else { return (false, false, false) }
            let first = bytes[0]
            let second = bytes[1]
            let isPrivate = first == 10 ||
                (first == 172 && (16...31).contains(second)) ||
                (first == 192 && second == 168) ||
                (first == 169 && second == 254) ||
                first == 127 ||
                (first == 100 && (64...127).contains(second)) ||
                first == 0 ||
                first >= 224
            return (isPrivate, !isPrivate, false)
        }

        if let ipv6 = IPv6Address(address) {
            let bytes = Array(ipv6.rawValue)
            guard bytes.count == 16 else { return (false, false, false) }
            let isUniqueLocal = (bytes[0] & 0xfe) == 0xfc
            let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let isUnspecified = bytes.allSatisfy { $0 == 0 }
            let isMulticast = bytes[0] == 0xff
            let isPrivate = isUniqueLocal || isLinkLocal || isLoopback || isUnspecified || isMulticast
            return (isPrivate, !isPrivate, false)
        }

        return (false, false, false)
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
