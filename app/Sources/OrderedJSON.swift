// A small JSON value type that keeps object key order and number spelling, so editing
// ~/.claude/settings.json changes only the hooks Claude Chimes owns. Foundation's
// JSONSerialization returns unordered dictionaries, which would reshuffle the whole file.

import Foundation

indirect enum JSON: Equatable {
    case object([(String, JSON)])
    case array([JSON])
    case string(String)
    case number(String)   // kept as written, e.g. "5" or "1.0e3"
    case bool(Bool)
    case null

    static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case let (.object(x), .object(y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.array(x), .array(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.bool(x), .bool(y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    // MARK: Access

    subscript(key: String) -> JSON? {
        if case let .object(pairs) = self { return pairs.last { $0.0 == key }?.1 }
        return nil
    }
    var pairs: [(String, JSON)]? { if case let .object(p) = self { return p }; return nil }
    var array: [JSON]? { if case let .array(a) = self { return a }; return nil }
    var string: String? { if case let .string(s) = self { return s }; return nil }
    var bool: Bool? { if case let .bool(b) = self { return b }; return nil }

    /// Replaces `key` in place, appends it if missing, or removes it when `value` is nil.
    func setting(_ key: String, to value: JSON?) -> JSON {
        guard case var .object(p) = self else { return self }
        if let i = p.firstIndex(where: { $0.0 == key }) {
            if let value { p[i].1 = value } else { p.remove(at: i) }
        } else if let value {
            p.append((key, value))
        }
        return .object(p)
    }

    // MARK: Parse

    struct ParseError: LocalizedError {
        let offset: Int
        let reason: String
        var errorDescription: String? { "\(reason) at byte \(offset)" }
    }

    static func parse(_ data: Data) throws -> JSON {
        var p = Parser(bytes: [UInt8](data))
        p.skipWhitespace()
        let value = try p.value()
        p.skipWhitespace()
        guard p.i == p.bytes.count else { throw ParseError(offset: p.i, reason: "Unexpected trailing content") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func skipWhitespace() {
            while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 }
        }

        func fail(_ reason: String) -> ParseError { ParseError(offset: i, reason: reason) }

        mutating func expect(_ literal: String) throws {
            let l = Array(literal.utf8)
            guard i + l.count <= bytes.count, Array(bytes[i..<i + l.count]) == l else { throw fail("Expected \(literal)") }
            i += l.count
        }

        mutating func value() throws -> JSON {
            guard i < bytes.count else { throw fail("Unexpected end of input") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return try number()
            }
        }

        mutating func object() throws -> JSON {
            i += 1
            var pairs: [(String, JSON)] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("Expected a key") }
                let key = try string()
                skipWhitespace()
                try expect(":")
                skipWhitespace()
                pairs.append((key, try value()))
                skipWhitespace()
                guard i < bytes.count else { throw fail("Unterminated object") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
                throw fail("Expected , or }")
            }
        }

        mutating func array() throws -> JSON {
            i += 1
            var items: [JSON] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try value())
                skipWhitespace()
                guard i < bytes.count else { throw fail("Unterminated array") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw fail("Expected , or ]")
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count, let s = String(bytes: bytes[i..<i + 4], encoding: .ascii),
                  let v = UInt32(s, radix: 16) else { throw fail("Bad \\u escape") }
            i += 4
            return v
        }

        mutating func string() throws -> String {
            i += 1
            var out = [UInt8]()
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") { i += 1; return String(decoding: out, as: UTF8.self) }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { break }
                    let e = bytes[i]; i += 1
                    switch e {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if (0xD800...0xDBFF).contains(code), i + 1 < bytes.count,
                           bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                            i += 2
                            let low = try hex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        out.append(contentsOf: Array(String(Character(Unicode.Scalar(code) ?? "\u{FFFD}")).utf8))
                    default: throw fail("Bad escape")
                    }
                    continue
                }
                out.append(c); i += 1
            }
            throw fail("Unterminated string")
        }

        mutating func number() throws -> JSON {
            let start = i
            while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
            guard i > start, let s = String(bytes: bytes[start..<i], encoding: .ascii), Double(s) != nil
            else { throw fail("Unexpected character") }
            return .number(s)
        }
    }

    // MARK: Serialize (2-space indent, like `json.dump(indent=2)`)

    func serialized(_ level: Int = 0) -> String {
        let pad = String(repeating: "  ", count: level), inner = String(repeating: "  ", count: level + 1)
        switch self {
        case let .object(p):
            if p.isEmpty { return "{}" }
            return "{\n" + p.map { "\(inner)\(JSON.quote($0.0)): \($0.1.serialized(level + 1))" }.joined(separator: ",\n") + "\n\(pad)}"
        case let .array(a):
            if a.isEmpty { return "[]" }
            return "[\n" + a.map { inner + $0.serialized(level + 1) }.joined(separator: ",\n") + "\n\(pad)]"
        case let .string(s): return JSON.quote(s)
        case let .number(n): return n
        case let .bool(b): return b ? "true" : "false"
        case .null: return "null"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}
