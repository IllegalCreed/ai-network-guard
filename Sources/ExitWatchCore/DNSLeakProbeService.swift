import Foundation

/// Performs an on-demand DNS leak test using bash.ws' unique-hostname
/// technique. The test deliberately sends only synthetic hostnames such as
/// `1.<token>.bash.ws`; no browsing history or user-provided domain is sent.
public actor DNSLeakProbeService {
    private let session: URLSession
    private let host = "bash.ws"
    private let requestTimeout: TimeInterval

    public init(requestTimeout: TimeInterval = 6) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout + 2
        configuration.waitsForConnectivity = false
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        self.session = URLSession(configuration: configuration)
        self.requestTimeout = requestTimeout
    }

    public func check() async -> DNSLeakResult {
        let checkedAt = Date()
        do {
            let testID = try await fetchTestID()
            await triggerLookups(for: testID)

            var lastError: Error?
            for attempt in 0..<5 {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                }

                do {
                    let data = try await fetchResultData(for: testID)
                    return try DNSLeakPayloadParser.parse(
                        data: data,
                        testID: testID,
                        checkedAt: checkedAt
                    )
                } catch {
                    lastError = error
                }
            }

            throw lastError ?? DNSLeakParsingError.noResults
        } catch {
            return DNSLeakResult(
                errorMessage: friendlyMessage(for: error),
                checkedAt: checkedAt
            )
        }
    }

    private func fetchTestID() async throws -> String {
        let url = URL(string: "https://\(host)/id")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("ExitWatch/\(ProductInfo.version) (+https://github.com/IllegalCreed/ai-network-guard)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        try validate(response)
        guard let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw DNSLeakParsingError.invalidPayload
        }
        return value
    }

    private func triggerLookups(for testID: String) async {
        let session = self.session
        let timeout = self.requestTimeout
        let host = self.host

        await withTaskGroup(of: Void.self) { group in
            for index in 1...10 {
                group.addTask {
                    guard let url = URL(string: "https://\(index).\(testID).\(host)/") else {
                        return
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.timeoutInterval = timeout
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.setValue("ExitWatch/\(ProductInfo.version) DNS probe", forHTTPHeaderField: "User-Agent")
                    _ = try? await session.data(for: request)
                }
            }

            for await _ in group {
                // The TLS/HTTP request is expected to fail for a synthetic
                // hostname. Its purpose here is to force a fresh DNS lookup.
            }
        }
    }

    private func fetchResultData(for testID: String) async throws -> Data {
        let url = URL(string: "https://\(host)/dnsleak/test/\(testID)?json")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("ExitWatch/\(ProductInfo.version) (+https://github.com/IllegalCreed/ai-network-guard)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        try validate(response)
        return data
    }

    private func validate(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<400).contains(status) else {
            throw DNSLeakHTTPError.unsupportedStatus(status)
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "网络请求失败（\(nsError.code)）"
        }
        return "DNS 检测失败：\(error.localizedDescription)"
    }
}

private enum DNSLeakHTTPError: LocalizedError, Sendable {
    case unsupportedStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedStatus(let status):
            return "DNS 探针返回 HTTP \(status)"
        }
    }
}
