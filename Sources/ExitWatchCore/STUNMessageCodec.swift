import Foundation
import Network

public struct STUNBindingRequest: Sendable, Hashable {
    public let data: Data
    public let transactionID: Data

    public init(data: Data, transactionID: Data) {
        self.data = data
        self.transactionID = transactionID
    }
}

public struct STUNMappedAddress: Sendable, Hashable {
    public let address: String
    public let port: UInt16

    public init(address: String, port: UInt16) {
        self.address = address
        self.port = port
    }
}

public enum STUNMessageError: LocalizedError, Sendable, Equatable {
    case truncatedMessage
    case invalidMessageType(UInt16)
    case invalidMagicCookie
    case transactionMismatch
    case malformedAttribute
    case missingMappedAddress
    case unsupportedAddressFamily(UInt8)

    public var errorDescription: String? {
        switch self {
        case .truncatedMessage: return "STUN 响应长度不足"
        case .invalidMessageType(let type): return "STUN 响应类型无效（\(type)）"
        case .invalidMagicCookie: return "STUN 响应的 magic cookie 无效"
        case .transactionMismatch: return "STUN 响应事务不匹配"
        case .malformedAttribute: return "STUN 响应属性格式无效"
        case .missingMappedAddress: return "STUN 响应没有公网映射地址"
        case .unsupportedAddressFamily(let family): return "STUN 地址族不受支持（\(family)）"
        }
    }
}

/// Minimal RFC 5389 codec used by the UDP/STUN privacy probe.
public enum STUNMessageCodec {
    private static let bindingRequestType: UInt16 = 0x0001
    private static let bindingSuccessType: UInt16 = 0x0101
    private static let magicCookie: UInt32 = 0x2112A442
    private static let mappedAddressType: UInt16 = 0x0001
    private static let xorMappedAddressType: UInt16 = 0x0020

    public static func makeBindingRequest() -> STUNBindingRequest {
        var generator = SystemRandomNumberGenerator()
        let transactionBytes = (0..<12).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let transactionID = Data(transactionBytes)

        var bytes: [UInt8] = []
        append(bindingRequestType, to: &bytes)
        append(UInt16(0), to: &bytes)
        append(magicCookie, to: &bytes)
        bytes.append(contentsOf: transactionBytes)
        return STUNBindingRequest(data: Data(bytes), transactionID: transactionID)
    }

    public static func parseBindingResponse(
        _ data: Data,
        transactionID: Data
    ) throws -> STUNMappedAddress {
        let bytes = Array(data)
        guard bytes.count >= 20 else { throw STUNMessageError.truncatedMessage }

        let messageType = readUInt16(bytes, at: 0)
        guard messageType == bindingSuccessType else {
            throw STUNMessageError.invalidMessageType(messageType)
        }
        guard readUInt32(bytes, at: 4) == magicCookie else {
            throw STUNMessageError.invalidMagicCookie
        }
        guard transactionID.count == 12,
              Data(bytes[8..<20]) == transactionID else {
            throw STUNMessageError.transactionMismatch
        }

        let messageLength = Int(readUInt16(bytes, at: 2))
        let messageEnd = 20 + messageLength
        guard messageEnd <= bytes.count else { throw STUNMessageError.truncatedMessage }

        var offset = 20
        var mappedFallback: STUNMappedAddress?
        while offset + 4 <= messageEnd {
            let attributeType = readUInt16(bytes, at: offset)
            let attributeLength = Int(readUInt16(bytes, at: offset + 2))
            let valueStart = offset + 4
            let valueEnd = valueStart + attributeLength
            guard valueEnd <= messageEnd else { throw STUNMessageError.malformedAttribute }

            if attributeType == xorMappedAddressType {
                return try parseAddress(
                    Array(bytes[valueStart..<valueEnd]),
                    transactionID: Array(transactionID),
                    xorEncoded: true
                )
            }
            if attributeType == mappedAddressType {
                mappedFallback = try parseAddress(
                    Array(bytes[valueStart..<valueEnd]),
                    transactionID: Array(transactionID),
                    xorEncoded: false
                )
            }

            let padding = (4 - (attributeLength % 4)) % 4
            offset = valueEnd + padding
        }

        if let mappedFallback { return mappedFallback }
        throw STUNMessageError.missingMappedAddress
    }

    private static func parseAddress(
        _ value: [UInt8],
        transactionID: [UInt8],
        xorEncoded: Bool
    ) throws -> STUNMappedAddress {
        guard value.count >= 4 else { throw STUNMessageError.malformedAttribute }
        let family = value[1]
        var port = readUInt16(value, at: 2)
        if xorEncoded {
            port ^= UInt16(magicCookie >> 16)
        }

        let cookieBytes: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
        switch family {
        case 0x01:
            guard value.count >= 8 else { throw STUNMessageError.malformedAttribute }
            var addressBytes = Array(value[4..<8])
            if xorEncoded {
                for index in addressBytes.indices {
                    addressBytes[index] ^= cookieBytes[index]
                }
            }
            guard let address = IPv4Address(Data(addressBytes)) else {
                throw STUNMessageError.malformedAttribute
            }
            return STUNMappedAddress(address: address.debugDescription, port: port)

        case 0x02:
            guard value.count >= 20, transactionID.count == 12 else {
                throw STUNMessageError.malformedAttribute
            }
            var addressBytes = Array(value[4..<20])
            if xorEncoded {
                let mask = cookieBytes + transactionID
                for index in addressBytes.indices {
                    addressBytes[index] ^= mask[index]
                }
            }
            guard let address = IPv6Address(Data(addressBytes)) else {
                throw STUNMessageError.malformedAttribute
            }
            return STUNMappedAddress(address: address.debugDescription, port: port)

        default:
            throw STUNMessageError.unsupportedAddressFamily(family)
        }
    }

    private static func append(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
    }

    private static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8((value >> 24) & 0xff))
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) |
            (UInt32(bytes[offset + 1]) << 16) |
            (UInt32(bytes[offset + 2]) << 8) |
            UInt32(bytes[offset + 3])
    }
}
