import XCTest
@testable import ExitWatchCore

final class ExitWatchCoreTests: XCTestCase {
    func testParsesIPifyJSON() throws {
        let data = Data(#"{"ip":"206.83.109.136"}"#.utf8)
        let result = try ProbePayloadParser.parse(data: data, parser: .ipifyJSON)

        XCTAssertEqual(result.ip, "206.83.109.136")
        XCTAssertNil(result.trace)
    }

    func testParsesCloudflareTrace() throws {
        let trace = """
        fl=abc123
        h=claude.ai
        ip=114.250.249.77
        colo=NRT
        loc=JP
        visit_scheme=https
        """

        let result = try ProbePayloadParser.parse(
            data: Data(trace.utf8),
            parser: .cloudflareTrace
        )

        XCTAssertEqual(result.ip, "114.250.249.77")
        XCTAssertEqual(result.trace?.colo, "NRT")
        XCTAssertEqual(result.trace?.reportedCountry, "JP")
        XCTAssertEqual(result.trace?.visitScheme, "https")
    }

    func testRejectsTraceWithoutIP() {
        XCTAssertThrowsError(
            try ProbePayloadParser.parse(
                data: Data("colo=NRT\nloc=JP\n".utf8),
                parser: .cloudflareTrace
            )
        ) { error in
            XCTAssertEqual(error as? ProbeParsingError, .missingIP)
        }
    }

    func testChineseRegionsAreBlocked() {
        let mainland = GeoInfo(
            countryCode: "CN",
            countryName: "China",
            organization: "China Unicom",
            isDatacenter: false
        )
        let hongKong = GeoInfo(
            countryCode: "hk",
            countryName: "Hong Kong",
            organization: "Example ISP"
        )
        let japan = GeoInfo(
            countryCode: "JP",
            countryName: "Japan",
            organization: "Example ISP"
        )

        XCTAssertTrue(mainland.isBlockedRegion)
        XCTAssertTrue(hongKong.isBlockedRegion)
        XCTAssertFalse(japan.isBlockedRegion)
        XCTAssertEqual(mainland.networkKind, .residential)
    }

    func testVPNSignalTakesPrecedenceForNetworkLabel() {
        let value = GeoInfo(
            countryCode: "JP",
            countryName: "Japan",
            organization: "Example Hosting",
            isDatacenter: true,
            isVPN: true
        )

        XCTAssertEqual(value.networkKind, .vpn)
        XCTAssertEqual(value.networkKind.label, "VPN（数据库标记）")
    }

    func testDecodesIPAPIShortResponse() throws {
        let payload = """
        {
          "ip": "114.250.249.77",
          "is_datacenter": false,
          "is_proxy": false,
          "is_vpn": false,
          "is_tor": false,
          "company_name": "China Unicom Beijing province network",
          "asn_num": 4808,
          "asn_org": "China Unicom Beijing Province Network",
          "cc": "CN"
        }
        """

        let response = try JSONDecoder().decode(IPAPIResponse.self, from: Data(payload.utf8))
        let geo = try response.makeGeoInfo(fallbackIP: "114.250.249.77")

        XCTAssertEqual(geo.countryCode, "CN")
        XCTAssertEqual(geo.countryName, "中国大陆")
        XCTAssertEqual(geo.asn, 4808)
        XCTAssertEqual(geo.organization, "China Unicom Beijing province network")
        XCTAssertTrue(geo.isBlockedRegion)
    }

    func testDefaultProbesCoverIndependentRoutes() {
        XCTAssertEqual(DefaultProbes.all.map(\.id), ["public", "cloudflare", "claude"])
        XCTAssertEqual(DefaultProbes.all.map(\.parser), [.ipifyJSON, .cloudflareTrace, .cloudflareTrace])
    }
}
