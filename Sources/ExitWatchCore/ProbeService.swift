import Foundation

/// Network client used by the monitor. The service deliberately uses an
/// ephemeral URLSession and a short cache: only the egress IPs are sent to the
/// geolocation provider, and repeated checks do not continuously re-submit the
/// same address.
public actor IPProbeService {
    private struct CachedGeo: Sendable {
        let value: GeoInfo
        let storedAt: Date
    }

    private let session: URLSession
    private let geoCacheTTL: TimeInterval
    private var geoCache: [String: CachedGeo] = [:]

    public init(geoCacheTTL: TimeInterval = 600) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        self.session = URLSession(configuration: configuration)
        self.geoCacheTTL = geoCacheTTL
    }

    public func check(_ definitions: [ProbeDefinition]) async -> [ProbeResult] {
        await withTaskGroup(of: ProbeResult.self, returning: [ProbeResult].self) { group in
            for definition in definitions {
                group.addTask { await self.check(definition) }
            }

            var values: [ProbeResult] = []
            for await value in group {
                values.append(value)
            }
            return values.sorted { left, right in
                let leftIndex = definitions.firstIndex(of: left.definition) ?? 0
                let rightIndex = definitions.firstIndex(of: right.definition) ?? 0
                return leftIndex < rightIndex
            }
        }
    }

    private func check(_ definition: ProbeDefinition) async -> ProbeResult {
        let startedAt = Date()
        do {
            var request = URLRequest(url: definition.url)
            request.httpMethod = "GET"
            request.timeoutInterval = 8
            request.setValue("ExitWatch/0.1 (+https://github.com/IllegalCreed/exitwatch-macos)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
            let payload = try ProbePayloadParser.parse(data: data, parser: definition.parser, statusCode: statusCode)
            let elapsed = max(1, Int(Date().timeIntervalSince(startedAt) * 1_000))

            do {
                let geo = try await lookupGeo(for: payload.ip)
                return ProbeResult(
                    definition: definition,
                    ip: payload.ip,
                    geo: geo,
                    trace: payload.trace,
                    latencyMilliseconds: elapsed,
                    checkedAt: Date()
                )
            } catch {
                // Keep the IP visible even when the metadata provider is
                // unavailable. The UI can then distinguish “IP obtained,
                // location unknown” from a completely failed probe.
                return ProbeResult(
                    definition: definition,
                    ip: payload.ip,
                    trace: payload.trace,
                    latencyMilliseconds: elapsed,
                    errorMessage: "地理信息查询失败：\(friendlyMessage(for: error))",
                    checkedAt: Date()
                )
            }
        } catch {
            let elapsed = max(1, Int(Date().timeIntervalSince(startedAt) * 1_000))
            return ProbeResult(
                definition: definition,
                latencyMilliseconds: elapsed,
                errorMessage: friendlyMessage(for: error),
                checkedAt: Date()
            )
        }
    }

    private func lookupGeo(for ip: String) async throws -> GeoInfo {
        if let cached = geoCache[ip], Date().timeIntervalSince(cached.storedAt) < geoCacheTTL {
            return cached.value
        }

        var components = URLComponents(string: "https://api.ipapi.is/")!
        components.queryItems = [URLQueryItem(name: "q", value: ip)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("ExitWatch/0.1 (+https://github.com/IllegalCreed/exitwatch-macos)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<400).contains(statusCode) else {
            throw ProbeParsingError.unsupportedStatus(statusCode)
        }

        let decoded = try JSONDecoder().decode(IPAPIResponse.self, from: data)
        let value = try decoded.makeGeoInfo(fallbackIP: ip)
        geoCache[ip] = CachedGeo(value: value, storedAt: Date())
        return value
    }

    private func friendlyMessage(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "网络请求失败（\(nsError.code)）"
        }
        return "检查失败：\(error.localizedDescription)"
    }
}
