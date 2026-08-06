import Foundation

struct StrictJSONScanner {
    private let bytes: [UInt8]
    private let maximumContainerDepth: Int
    private var index = 0

    init(data: Data, maximumContainerDepth: Int) {
        bytes = Array(data)
        self.maximumContainerDepth = maximumContainerDepth
    }

    mutating func validate() throws {
        skipWhitespace()
        try parseValue(containerDepth: 1)
        skipWhitespace()
        guard index == bytes.count else { throw PricingCatalogLoadingError.invalidJSON }
    }

    private mutating func parseValue(containerDepth: Int) throws {
        skipWhitespace()
        guard let byte = currentByte else { throw PricingCatalogLoadingError.invalidJSON }
        switch byte {
        case 0x7B:
            try parseObject(depth: containerDepth)
        case 0x5B:
            try parseArray(depth: containerDepth)
        case 0x22:
            _ = try parseString()
        case 0x74:
            try parseLiteral(Array("true".utf8))
        case 0x66:
            try parseLiteral(Array("false".utf8))
        case 0x6E:
            try parseLiteral(Array("null".utf8))
        case 0x2D, 0x30...0x39:
            try parseNumber()
        default:
            throw PricingCatalogLoadingError.invalidJSON
        }
    }

    private mutating func parseObject(depth: Int) throws {
        guard depth <= maximumContainerDepth else {
            throw PricingCatalogLoadingError.documentTooDeep
        }
        index += 1
        skipWhitespace()
        if consume(0x7D) { return }

        var keys = Set<String>()
        while true {
            guard currentByte == 0x22 else { throw PricingCatalogLoadingError.invalidJSON }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw PricingCatalogLoadingError.duplicateObjectMember(key)
            }
            skipWhitespace()
            guard consume(0x3A) else { throw PricingCatalogLoadingError.invalidJSON }
            try parseValue(containerDepth: depth + 1)
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw PricingCatalogLoadingError.invalidJSON }
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) throws {
        guard depth <= maximumContainerDepth else {
            throw PricingCatalogLoadingError.documentTooDeep
        }
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }

        while true {
            try parseValue(containerDepth: depth + 1)
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw PricingCatalogLoadingError.invalidJSON }
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        guard consume(0x22) else { throw PricingCatalogLoadingError.invalidJSON }
        while let byte = currentByte {
            switch byte {
            case 0x22:
                index += 1
                let encoded = Data(bytes[start..<index])
                guard let decoded = try? JSONDecoder().decode(String.self, from: encoded) else {
                    throw PricingCatalogLoadingError.invalidJSON
                }
                return decoded
            case 0x5C:
                index += 1
                guard let escape = currentByte else { throw PricingCatalogLoadingError.invalidJSON }
                switch escape {
                case 0x22, 0x2F, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    index += 1
                case 0x75:
                    index += 1
                    for _ in 0..<4 {
                        guard let hex = currentByte, Self.isHexDigit(hex) else {
                            throw PricingCatalogLoadingError.invalidJSON
                        }
                        index += 1
                    }
                default:
                    throw PricingCatalogLoadingError.invalidJSON
                }
            case 0x00...0x1F:
                throw PricingCatalogLoadingError.invalidJSON
            default:
                index += 1
            }
        }
        throw PricingCatalogLoadingError.invalidJSON
    }

    private mutating func parseLiteral(_ literal: [UInt8]) throws {
        guard index + literal.count <= bytes.count,
              Array(bytes[index..<(index + literal.count)]) == literal else {
            throw PricingCatalogLoadingError.invalidJSON
        }
        index += literal.count
    }

    private mutating func parseNumber() throws {
        if consume(0x2D), currentByte == nil {
            throw PricingCatalogLoadingError.invalidJSON
        }
        if consume(0x30) {
            if let byte = currentByte, Self.isDigit(byte) {
                throw PricingCatalogLoadingError.invalidJSON
            }
        } else {
            guard let byte = currentByte, (0x31...0x39).contains(byte) else {
                throw PricingCatalogLoadingError.invalidJSON
            }
            index += 1
            while let byte = currentByte, Self.isDigit(byte) { index += 1 }
        }

        if consume(0x2E) {
            guard let byte = currentByte, Self.isDigit(byte) else {
                throw PricingCatalogLoadingError.invalidJSON
            }
            while let byte = currentByte, Self.isDigit(byte) { index += 1 }
        }

        if currentByte == 0x65 || currentByte == 0x45 {
            index += 1
            if currentByte == 0x2B || currentByte == 0x2D { index += 1 }
            guard let byte = currentByte, Self.isDigit(byte) else {
                throw PricingCatalogLoadingError.invalidJSON
            }
            while let byte = currentByte, Self.isDigit(byte) { index += 1 }
        }
    }

    private mutating func skipWhitespace() {
        while let byte = currentByte, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard currentByte == byte else { return false }
        index += 1
        return true
    }

    private var currentByte: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}
