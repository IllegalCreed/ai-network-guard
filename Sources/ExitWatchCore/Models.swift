import Foundation

/// The kind of endpoint response that a probe understands.
public enum ProbeParser: String, Sendable, Hashable {
    case ipifyJSON
    case cloudflareTrace
}

/// A destination whose observed egress IP should be checked.
public struct ProbeDefinition: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let detail: String
    public let url: URL
    public let parser: ProbeParser
    public let symbolName: String

    public init(
        id: String,
        name: String,
        detail: String,
        url: URL,
        parser: ProbeParser,
        symbolName: String
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.url = url
        self.parser = parser
        self.symbolName = symbolName
    }

    public var host: String {
        url.host ?? url.absoluteString
    }
}

public enum DefaultProbes {
    /// The initial set intentionally includes independent destinations. A split-tunnel
    /// proxy can return a different egress address for each of them.
    public static let all: [ProbeDefinition] = [
        ProbeDefinition(
            id: "public",
            name: "通用出口",
            detail: "ipify 公共探针",
            url: URL(string: "https://api64.ipify.org?format=json")!,
            parser: .ipifyJSON,
            symbolName: "globe"
        ),
        ProbeDefinition(
            id: "cloudflare",
            name: "Cloudflare 出口",
            detail: "Cloudflare trace",
            url: URL(string: "https://1.1.1.1/cdn-cgi/trace")!,
            parser: .cloudflareTrace,
            symbolName: "cloud"
        ),
        ProbeDefinition(
            id: "claude",
            name: "Claude 出口",
            detail: "claude.ai trace",
            url: URL(string: "https://claude.ai/cdn-cgi/trace")!,
            parser: .cloudflareTrace,
            symbolName: "sparkles"
        )
    ]
}

public struct TraceMetadata: Sendable, Hashable {
    public let colo: String?
    public let reportedCountry: String?
    public let visitScheme: String?

    public init(colo: String? = nil, reportedCountry: String? = nil, visitScheme: String? = nil) {
        self.colo = colo
        self.reportedCountry = reportedCountry
        self.visitScheme = visitScheme
    }
}

public enum NetworkKind: String, Sendable, Hashable {
    case residential
    case datacenter
    case vpn
    case proxy
    case tor
    case mobile
    case satellite
    case unknown

    public var label: String {
        switch self {
        case .residential: return "家宽/运营商（推测）"
        case .datacenter: return "机房/数据中心"
        case .vpn: return "VPN（数据库标记）"
        case .proxy: return "代理（数据库标记）"
        case .tor: return "Tor（数据库标记）"
        case .mobile: return "移动网络（推测）"
        case .satellite: return "卫星网络（推测）"
        case .unknown: return "未知"
        }
    }
}

public struct GeoInfo: Sendable, Hashable {
    public let countryCode: String
    public let countryName: String
    public let region: String?
    public let city: String?
    public let organization: String?
    public let asn: Int?
    public let isDatacenter: Bool
    public let isVPN: Bool
    public let isProxy: Bool
    public let isTor: Bool
    public let isMobile: Bool
    public let isSatellite: Bool

    public init(
        countryCode: String,
        countryName: String,
        region: String? = nil,
        city: String? = nil,
        organization: String? = nil,
        asn: Int? = nil,
        isDatacenter: Bool = false,
        isVPN: Bool = false,
        isProxy: Bool = false,
        isTor: Bool = false,
        isMobile: Bool = false,
        isSatellite: Bool = false
    ) {
        self.countryCode = countryCode.uppercased()
        self.countryName = countryName
        self.region = region
        self.city = city
        self.organization = organization
        self.asn = asn
        self.isDatacenter = isDatacenter
        self.isVPN = isVPN
        self.isProxy = isProxy
        self.isTor = isTor
        self.isMobile = isMobile
        self.isSatellite = isSatellite
    }

    public var isBlockedRegion: Bool {
        ["CN", "HK"].contains(countryCode)
    }

    public var networkKind: NetworkKind {
        if isTor { return .tor }
        if isVPN { return .vpn }
        if isProxy { return .proxy }
        if isDatacenter { return .datacenter }
        if isSatellite { return .satellite }
        if isMobile { return .mobile }
        if organization != nil { return .residential }
        return .unknown
    }

    public var locationText: String {
        [countryName, region, city]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }
}

public struct ProbeResult: Identifiable, Sendable, Hashable {
    public let definition: ProbeDefinition
    public let ip: String?
    public let geo: GeoInfo?
    public let trace: TraceMetadata?
    public let latencyMilliseconds: Int?
    public let errorMessage: String?
    public let checkedAt: Date

    public init(
        definition: ProbeDefinition,
        ip: String? = nil,
        geo: GeoInfo? = nil,
        trace: TraceMetadata? = nil,
        latencyMilliseconds: Int? = nil,
        errorMessage: String? = nil,
        checkedAt: Date = Date()
    ) {
        self.definition = definition
        self.ip = ip
        self.geo = geo
        self.trace = trace
        self.latencyMilliseconds = latencyMilliseconds
        self.errorMessage = errorMessage
        self.checkedAt = checkedAt
    }

    public var id: String { definition.id }
    public var hasIP: Bool { ip != nil }
    public var isBlockedRegion: Bool { geo?.isBlockedRegion == true }
    public var isResolved: Bool { ip != nil && geo != nil && errorMessage == nil }
}

public enum MonitorStatus: String, Sendable, Hashable {
    case idle
    case checking
    case safe
    case risk
    case unknown
    case offline

    public var label: String {
        switch self {
        case .idle: return "等待检查"
        case .checking: return "检查中"
        case .safe: return "状态安全"
        case .risk: return "发现风险"
        case .unknown: return "数据不完整"
        case .offline: return "探针不可用"
        }
    }

    public var systemImage: String {
        switch self {
        case .idle: return "shield"
        case .checking: return "arrow.triangle.2.circlepath"
        case .safe: return "checkmark.shield.fill"
        case .risk: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle.fill"
        case .offline: return "wifi.exclamationmark"
        }
    }

    public var isAlert: Bool {
        switch self {
        case .risk, .offline: return true
        case .idle, .checking, .safe, .unknown: return false
        }
    }
}

public enum CountryNames {
    public static func name(for code: String) -> String {
        switch code.uppercased() {
        case "CN": return "中国大陆"
        case "HK": return "中国香港"
        case "MO": return "中国澳门"
        case "TW": return "中国台湾"
        case "JP": return "日本"
        case "US": return "美国"
        case "SG": return "新加坡"
        case "KR": return "韩国"
        case "GB": return "英国"
        case "DE": return "德国"
        case "FR": return "法国"
        case "CA": return "加拿大"
        case "AU": return "澳大利亚"
        case "NL": return "荷兰"
        default: return code.uppercased()
        }
    }
}
