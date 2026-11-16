import Foundation

nonisolated enum ACPJSON: Codable, Sendable, Equatable {
    case object([String: ACPJSON]), array([ACPJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let x = try? value.decode(Bool.self) { self = .bool(x) }
        else if let x = try? value.decode(String.self) { self = .string(x) }
        else if let x = try? value.decode(Double.self) { self = .number(x) }
        else if let x = try? value.decode([ACPJSON].self) { self = .array(x) }
        else { self = .object(try value.decode([String: ACPJSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let x): try value.encode(x)
        case .array(let x): try value.encode(x)
        case .string(let x): try value.encode(x)
        case .number(let x): try value.encode(x)
        case .bool(let x): try value.encode(x)
        case .null: try value.encodeNil()
        }
    }

    subscript(_ key: String) -> ACPJSON { object?[key] ?? .null }
    var object: [String: ACPJSON]? { if case .object(let x) = self { x } else { nil } }
    var array: [ACPJSON] { if case .array(let x) = self { x } else { [] } }
    var string: String? { if case .string(let x) = self { x } else { nil } }
    var integer: Int? {
        if case .number(let x) = self, x.isFinite, x >= Double(Int.min), x < Double(Int.max) { return Int(x) }
        return nil
    }
    var boolean: Bool { if case .bool(let x) = self { x } else { false } }
    var requestKey: String? {
        switch self {
        case .string(let x): "s:\(x)"
        case .number(let x): "n:\(x)"
        default: nil
        }
    }
}

nonisolated enum ACPError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

/// Byte framing preserves UTF-8 split across reads and LF inside CRLF graphemes.
nonisolated struct ACPLineDecoder {
    private var buffer = Data()
    let maximumFrameBytes: Int
    init(maximumFrameBytes: Int = 16 * 1_048_576) { self.maximumFrameBytes = maximumFrameBytes }

    mutating func append(_ data: Data) throws -> [ACPJSON] {
        buffer.append(data)
        var messages: [ACPJSON] = []
        while let end = buffer.firstIndex(of: 0x0A) {
            guard buffer.distance(from: buffer.startIndex, to: end) <= maximumFrameBytes else {
                throw ACPError.message("The agent sent an oversized protocol frame.")
            }
            let frame = buffer[..<end]
            if !frame.allSatisfy({ $0 == 0x0D || $0 == 0x20 || $0 == 0x09 }) {
                let message = try JSONDecoder().decode(ACPJSON.self, from: frame)
                guard message.object != nil else { throw ACPError.message("Invalid ACP message envelope.") }
                messages.append(message)
            }
            buffer.removeSubrange(...end)
        }
        guard buffer.count <= maximumFrameBytes else { throw ACPError.message("The agent sent an oversized protocol frame.") }
        return messages
    }

    func finish() throws {
        guard buffer.allSatisfy({ $0 == 0x0D || $0 == 0x20 || $0 == 0x09 }) else {
            throw ACPError.message("The agent closed its connection in the middle of a message.")
        }
    }
}
