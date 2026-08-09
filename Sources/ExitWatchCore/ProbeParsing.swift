import Foundation

public struct ParsedProbePayload: Sendable, Hashable {
    public let ip: String
    public let trace: TraceMetadata?

    public init(ip: String, trace: TraceMetadata? = nil) {
        self.ip = ip
        self.trace = trace
    }
}

public enum ProbeParsingError: LocalizedError, Sendable, Equatable {
    case invalidPayload
    case missingIP
    case unsupportedStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidPayload: return "探针返回的数据无法解析"
        case .missingIP: return "探针没有返回 IP 地址"
        case .unsupportedStatus(let code): return "探针返回 HTTP \(code)"
        }
    }
}

public enum ProbePayloadParser {
    public static func parse(data: Data, parser: ProbeParser, statusCode: Int = 200) throws -> ParsedProbePayload {
        guard (200..<400).contains(statusCode) else {
            throw ProbeParsingError.unsupportedStatus(statusCode)
        }

        switch parser {
        case .ipifyJSON:
            if let payload = try? JSONDecoder().decode(IPifyPayload.self, from: data),
               let ip = payload.ip?.trimmedNonEmpty {
                return ParsedProbePayload(ip: ip)
            }

            // A few public IP services return plain text even when the caller
            // requested JSON. Keeping this fallback makes the probe resilient.
            guard let text = String(data: data, encoding: .utf8)?.trimmedNonEmpty else {
                throw ProbeParsingError.invalidPayload
            }
            return ParsedProbePayload(ip: text)

        case .cloudflareTrace:
            guard let text = String(data: data, encoding: .utf8) else {
                throw ProbeParsingError.invalidPayload
            }

            var values: [String: String] = [:]
            for rawLine in text.split(whereSeparator: \.isNewline) {
                let line = String(rawLine)
                guard let separator = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                values[key] = value
            }

            guard let ip = values["ip"]?.trimmedNonEmpty else {
                throw ProbeParsingError.missingIP
            }

            let trace = TraceMetadata(
                colo: values["colo"]?.trimmedNonEmpty,
                reportedCountry: values["loc"]?.trimmedNonEmpty,
                visitScheme: values["visit_scheme"]?.trimmedNonEmpty
            )
            return ParsedProbePayload(ip: ip, trace: trace)
        }
    }
}

private struct IPifyPayload: Decodable {
    let ip: String?
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
