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

    func testDecodesIPWhoIsResponse() throws {
        let payload = """
        {
          "ip": "206.83.109.136",
          "success": true,
          "country": "Japan",
          "country_code": "JP",
          "region": "Tokyo",
          "city": "Tokyo",
          "connection": {
            "asn": 14593,
            "org": "Space Exploration Technologies Corporation",
            "isp": "Starlink"
          },
          "timezone": {
            "id": "Asia/Tokyo",
            "offset": 32400
          },
          "security": {
            "proxy": false,
            "vpn": false,
            "tor": false,
            "hosting": true
          }
        }
        """

        let response = try JSONDecoder().decode(IPWhoIsResponse.self, from: Data(payload.utf8))
        let geo = try response.makeGeoInfo(fallbackIP: "206.83.109.136")

        XCTAssertEqual(geo.countryCode, "JP")
        XCTAssertEqual(geo.countryName, "日本")
        XCTAssertEqual(geo.region, "Tokyo")
        XCTAssertEqual(geo.city, "Tokyo")
        XCTAssertEqual(geo.asn, 14593)
        XCTAssertEqual(geo.organization, "Space Exploration Technologies Corporation")
        XCTAssertTrue(geo.isDatacenter)
        XCTAssertEqual(geo.timeZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(geo.timeZoneOffsetSeconds, 32400)
    }

    func testBuildsLocalEnvironmentSnapshot() {
        let snapshot = DeviceEnvironmentSnapshot.current(
            timeZone: TimeZone(identifier: "Asia/Tokyo")!,
            preferredLanguages: ["en-US"],
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 1)
        )

        XCTAssertEqual(snapshot.timeZoneLabel, "Asia/Tokyo (UTC+9)")
        XCTAssertEqual(snapshot.preferredLanguageIdentifier, "en-US")
        XCTAssertEqual(snapshot.operatingSystemLabel, "macOS 14.5.1")
        XCTAssertEqual(DeviceEnvironmentSnapshot.utcOffsetLabel(seconds: 19_800), "UTC+05:30")
    }

    func testDefaultProbesCoverIndependentRoutes() {
        XCTAssertEqual(DefaultProbes.all.map(\.id), ["public", "cloudflare", "claude"])
        XCTAssertEqual(DefaultProbes.all.map(\.parser), [.ipifyJSON, .cloudflareTrace, .cloudflareTrace])
    }

    func testParsesDNSLeakResultWithoutLeak() throws {
        let payload = """
        [
          {"ip":"203.0.113.10","country":"jp","country_name":"Japan","asn":"AS64500","type":"ip"},
          {"ip":"1.1.1.1","country":"us","country_name":"United States","asn":"AS13335","type":"dns"},
          {"ip":"DNS does not leak.","country":"","country_name":"","asn":"","type":"conclusion"}
        ]
        """

        let result = try DNSLeakPayloadParser.parse(data: Data(payload.utf8), testID: "abc")

        XCTAssertEqual(result.testID, "abc")
        XCTAssertEqual(result.clientIP, "203.0.113.10")
        XCTAssertEqual(result.resolvers.map(\.ip), ["1.1.1.1"])
        XCTAssertEqual(result.assessment, .noLeak)
    }

    func testParsesDNSLeakResultWithPossibleLeak() throws {
        let payload = """
        [
          {"ip":"114.114.114.114","country":"cn","country_name":"China","asn":"AS4808 China Unicom","type":"dns"},
          {"ip":"DNS may be leaking.","country":"","country_name":"","asn":"","type":"conclusion"}
        ]
        """

        let result = try DNSLeakPayloadParser.parse(data: Data(payload.utf8))

        XCTAssertEqual(result.assessment, .possibleLeak)
        XCTAssertEqual(result.resolvers.count, 1)
    }

    func testClassifiesKnownDoHUpstreamsSeparatelyFromLeak() throws {
        let payload = """
        [
          {"ip":"162.159.109.88","country":"jp","country_name":"Japan","asn":"AS13335 Cloudflare Inc","type":"dns"},
          {"ip":"172.217.109.210","country":"us","country_name":"United States","asn":"AS15169 Google LLC","type":"dns"},
          {"ip":"DNS may be leaking.","country":"","country_name":"","asn":"","type":"conclusion"}
        ]
        """

        let result = try DNSLeakPayloadParser.parse(data: Data(payload.utf8))

        XCTAssertEqual(result.assessment, .trustedUpstream)
        XCTAssertEqual(
            Set(result.resolvers.compactMap(\.publicProviderName)),
            ["Cloudflare", "Google"]
        )
    }

    func testParsesAndAssessesWebRTCCandidates() {
        let lines = [
            "candidate:1 1 UDP 2122260223 192.168.1.4 54555 typ host",
            "candidate:2 1 UDP 1686052607 198.51.100.22 54556 typ srflx raddr 192.168.1.4 rport 54555",
            "candidate:3 1 TCP 1677734911 203.0.113.44 9 typ relay"
        ]

        let candidates = WebRTCCandidateParser.parse(lines: lines)

        XCTAssertEqual(candidates.count, 3)
        XCTAssertTrue(candidates[0].isPrivateAddress)
        XCTAssertTrue(candidates[1].isPublicAddress)
        XCTAssertEqual(
            WebRTCCandidateParser.assess(candidates: candidates, expectedPublicIPs: ["198.51.100.22"]),
            .possibleLeak
        )
        XCTAssertEqual(
            WebRTCCandidateParser.assess(
                candidates: [candidates[1]],
                expectedPublicIPs: ["198.51.100.22"]
            ),
            .noLeak
        )
        XCTAssertEqual(
            WebRTCCandidateParser.assess(candidates: [candidates[1]], expectedPublicIPs: []),
            .unknown
        )
    }

    func testIgnoresObfuscatedWebRTCHostCandidates() {
        let candidates = WebRTCCandidateParser.parse(
            lines: ["candidate:1 1 UDP 1 abc123.local 54555 typ host"]
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates[0].isObfuscatedAddress)
        XCTAssertEqual(
            WebRTCCandidateParser.assess(candidates: candidates, expectedPublicIPs: []),
            .unknown
        )
    }

    func testParsesSTUNXORMappedAddress() throws {
        let transactionID = Data((1...12).map(UInt8.init))
        let expectedIP: [UInt8] = [203, 0, 113, 5]
        let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
        let expectedPort: UInt16 = 54_321
        let encodedPort = expectedPort ^ 0x2112

        var attribute: [UInt8] = [
            0x00, 0x20, 0x00, 0x08,
            0x00, 0x01,
            UInt8(encodedPort >> 8), UInt8(encodedPort & 0xff)
        ]
        attribute.append(contentsOf: zip(expectedIP, cookie).map { $0 ^ $1 })

        var response: [UInt8] = [
            0x01, 0x01,
            0x00, UInt8(attribute.count),
            0x21, 0x12, 0xA4, 0x42
        ]
        response.append(contentsOf: transactionID)
        response.append(contentsOf: attribute)

        let mapped = try STUNMessageCodec.parseBindingResponse(
            Data(response),
            transactionID: transactionID
        )

        XCTAssertEqual(mapped.address, "203.0.113.5")
        XCTAssertEqual(mapped.port, expectedPort)
    }
}
