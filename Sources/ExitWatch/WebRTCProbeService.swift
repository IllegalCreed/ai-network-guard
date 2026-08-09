import ExitWatchCore
import Foundation
import Network

/// Result of the UDP/STUN path used by WebRTC. A successful STUN mapping is
/// represented as a server-reflexive ICE candidate so the shared candidate
/// parser and assessment logic can compare it with the HTTPS egress IPs.
struct WebRTCProbePayload: Sendable {
    let supported: Bool
    let candidateLines: [String]
    let errorMessage: String?

    init(supported: Bool, candidateLines: [String] = [], errorMessage: String? = nil) {
        self.supported = supported
        self.candidateLines = candidateLines
        self.errorMessage = errorMessage
    }
}

/// Sends a minimal RFC 5389 Binding request over UDP. A different public IP
/// here than the HTTPS probes is the common WebRTC leak pattern: browser media
/// traffic can leave directly even while HTTPS traffic uses a proxy.
actor WebRTCProbeService {
    private let host = NWEndpoint.Host("stun.l.google.com")
    private let port = NWEndpoint.Port(rawValue: 19_302)!
    private var isChecking = false

    func check(timeout: TimeInterval = 8) async -> WebRTCProbePayload {
        guard !isChecking else {
            return WebRTCProbePayload(
                supported: false,
                errorMessage: "WebRTC/STUN 检测正在进行"
            )
        }

        isChecking = true
        defer { isChecking = false }

        let request = STUNMessageCodec.makeBindingRequest()
        do {
            let mapped = try await STUNDatagramProbe.run(
                host: host,
                port: port,
                request: request,
                timeout: timeout
            )
            let candidate = "candidate:exitwatch 1 UDP 1 \(mapped.address) \(mapped.port) typ srflx"
            return WebRTCProbePayload(supported: true, candidateLines: [candidate])
        } catch {
            return WebRTCProbePayload(
                supported: false,
                errorMessage: friendlyMessage(for: error)
            )
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return "WebRTC/STUN 检测失败：\(error.localizedDescription)"
    }
}

private enum STUNProbeError: LocalizedError, Sendable {
    case timeout
    case noResponse

    var errorDescription: String? {
        switch self {
        case .timeout: return "WebRTC/STUN 检测超时，UDP 可能被代理或防火墙阻断"
        case .noResponse: return "STUN 服务没有返回有效数据"
        }
    }
}

private enum STUNDatagramProbe {
    private static let queue = DispatchQueue(label: "com.illegalcreed.exitwatch.stun", qos: .utility)

    static func run(
        host: NWEndpoint.Host,
        port: NWEndpoint.Port,
        request: STUNBindingRequest,
        timeout: TimeInterval
    ) async throws -> STUNMappedAddress {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(host: host, port: port, using: .udp)
            let attempt = STUNAttempt(connection: connection, continuation: continuation)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: request.data, completion: .contentProcessed { error in
                        if let error {
                            attempt.complete(.failure(error))
                            return
                        }

                        connection.receiveMessage { data, _, _, error in
                            if let error {
                                attempt.complete(.failure(error))
                                return
                            }
                            guard let data, !data.isEmpty else {
                                attempt.complete(.failure(STUNProbeError.noResponse))
                                return
                            }

                            do {
                                let mapped = try STUNMessageCodec.parseBindingResponse(
                                    data,
                                    transactionID: request.transactionID
                                )
                                attempt.complete(.success(mapped))
                            } catch {
                                attempt.complete(.failure(error))
                            }
                        }
                    })

                case .failed(let error):
                    attempt.complete(.failure(error))
                default:
                    break
                }
            }

            attempt.scheduleTimeout(after: max(timeout, 2), on: queue)
            connection.start(queue: queue)
        }
    }
}

private final class STUNAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var isComplete = false
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<STUNMappedAddress, Error>?
    private var timeoutItem: DispatchWorkItem?

    init(
        connection: NWConnection,
        continuation: CheckedContinuation<STUNMappedAddress, Error>
    ) {
        self.connection = connection
        self.continuation = continuation
    }

    func scheduleTimeout(after interval: TimeInterval, on queue: DispatchQueue) {
        let item = DispatchWorkItem { [weak self] in
            self?.complete(.failure(STUNProbeError.timeout))
        }

        lock.lock()
        if isComplete {
            lock.unlock()
            return
        }
        timeoutItem = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }

    func complete(_ result: Result<STUNMappedAddress, Error>) {
        lock.lock()
        guard !isComplete else {
            lock.unlock()
            return
        }
        isComplete = true
        let connection = self.connection
        let continuation = self.continuation
        let timeoutItem = self.timeoutItem
        self.connection = nil
        self.continuation = nil
        self.timeoutItem = nil
        lock.unlock()

        timeoutItem?.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        continuation?.resume(with: result)
    }
}
