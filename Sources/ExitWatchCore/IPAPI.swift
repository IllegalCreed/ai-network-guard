import Foundation

struct IPAPIResponse: Decodable {
    let ip: String?
    let cc: String?
    let country: String?
    let countryCode: String?
    let city: String?
    let region: String?
    let isDatacenter: Bool?
    let isVPN: Bool?
    let isProxy: Bool?
    let isTor: Bool?
    let isMobile: Bool?
    let isSatellite: Bool?
    let companyName: String?
    let asnNum: Int?
    let asnOrg: String?
    let location: Location?
    let company: Company?
    let asn: ASN?

    enum CodingKeys: String, CodingKey {
        case ip, cc, country, city, region
        case countryCode = "country_code"
        case isDatacenter = "is_datacenter"
        case isVPN = "is_vpn"
        case isProxy = "is_proxy"
        case isTor = "is_tor"
        case isMobile = "is_mobile"
        case isSatellite = "is_satellite"
        case companyName = "company_name"
        case asnNum = "asn_num"
        case asnOrg = "asn_org"
        case location, company, asn
    }

    func makeGeoInfo(fallbackIP: String) throws -> GeoInfo {
        let code = (countryCode ?? cc ?? location?.countryCode ?? "").uppercased()
        guard !code.isEmpty else { throw IPAPIDecodingError.missingCountry(fallbackIP) }

        let displayName = CountryNames.displayName(
            for: code,
            fallback: country ?? location?.country
        )
        let organization = companyName ?? asnOrg ?? company?.name ?? asn?.org
        let resolvedASN = asnNum ?? asn?.asn
        let hostingFlag = company?.type?.lowercased() == "hosting" || asn?.type?.lowercased() == "hosting"

        return GeoInfo(
            countryCode: code,
            countryName: displayName,
            region: region ?? location?.state,
            city: city ?? location?.city,
            organization: organization,
            asn: resolvedASN,
            isDatacenter: (isDatacenter ?? false) || hostingFlag,
            isVPN: isVPN ?? false,
            isProxy: isProxy ?? false,
            isTor: isTor ?? false,
            isMobile: isMobile ?? false,
            isSatellite: isSatellite ?? false,
            timeZoneIdentifier: location?.timezone
        )
    }
}

/// The public ipwho.is response is intentionally kept as a separate model.
/// Its schema is different from ipapi.is, but it exposes the same small set of
/// fields that the dashboard needs and does not require an API key.
struct IPWhoIsResponse: Decodable {
    let success: Bool?
    let message: String?
    let country: String?
    let countryCode: String?
    let region: String?
    let city: String?
    let connection: IPWhoIsConnection?
    let security: IPWhoIsSecurity?
    let timezone: IPWhoIsTimezone?

    enum CodingKeys: String, CodingKey {
        case success, message, country, region, city, connection, security, timezone
        case countryCode = "country_code"
    }

    func makeGeoInfo(fallbackIP: String) throws -> GeoInfo {
        guard success != false else {
            throw IPWhoIsDecodingError.unsuccessful(fallbackIP, message)
        }

        let code = countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        guard !code.isEmpty else { throw IPWhoIsDecodingError.missingCountry(fallbackIP) }

        let asn = connection?.asn
        let organization = connection?.org ?? connection?.isp
        let security = security
        return GeoInfo(
            countryCode: code,
            countryName: CountryNames.displayName(for: code, fallback: country),
            region: region,
            city: city,
            organization: organization,
            asn: asn,
            isDatacenter: security?.hosting ?? false,
            isVPN: security?.vpn ?? false,
            isProxy: security?.proxy ?? false,
            isTor: security?.tor ?? false,
            timeZoneIdentifier: timezone?.id,
            timeZoneOffsetSeconds: timezone?.offset
        )
    }
}

struct IPWhoIsConnection: Decodable {
    let asn: Int?
    let org: String?
    let isp: String?
}

struct IPWhoIsSecurity: Decodable {
    let proxy: Bool?
    let vpn: Bool?
    let tor: Bool?
    let hosting: Bool?
}

struct IPWhoIsTimezone: Decodable {
    let id: String?
    let offset: Int?
}

struct Location: Decodable {
    let country: String?
    let countryCode: String?
    let state: String?
    let city: String?
    let timezone: String?

    enum CodingKeys: String, CodingKey {
        case country, state, city, timezone
        case countryCode = "country_code"
    }
}

struct Company: Decodable {
    let name: String?
    let type: String?
}

struct ASN: Decodable {
    let asn: Int?
    let org: String?
    let type: String?
}

enum IPAPIDecodingError: LocalizedError, Sendable, Equatable {
    case missingCountry(String)

    var errorDescription: String? {
        switch self {
        case .missingCountry(let ip): return "IP \(ip) 的地理信息不完整"
        }
    }
}

enum IPWhoIsDecodingError: LocalizedError, Sendable, Equatable {
    case missingCountry(String)
    case unsuccessful(String, String?)

    var errorDescription: String? {
        switch self {
        case .missingCountry(let ip): return "IP \(ip) 的备用地理信息不完整"
        case .unsuccessful(_, let message):
            if let message, !message.isEmpty { return "备用定位服务：\(message)" }
            return "备用定位服务未返回结果"
        }
    }
}
