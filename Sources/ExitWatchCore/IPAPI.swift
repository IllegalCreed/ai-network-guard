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

        let displayName = country ?? location?.country ?? CountryNames.name(for: code)
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
            isSatellite: isSatellite ?? false
        )
    }
}

struct Location: Decodable {
    let country: String?
    let countryCode: String?
    let state: String?
    let city: String?

    enum CodingKeys: String, CodingKey {
        case country, state, city
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
