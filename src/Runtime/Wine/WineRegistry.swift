import Foundation

/// Encodes registry imports for Wine, including Framework component values.
struct WineRegistry {
  struct Entry {
    let name: String
    let value: Value
  }

  enum Value {
    case string(String)
    case dword(UInt32)
    case binary(Data)
    case expandableString(String)
    case strings([String])

    init(componentType: String, value: String) throws {
      switch componentType {
      case "REG_SZ":
        self = .string(value)
      case "REG_DWORD":
        let integer = value.hasPrefix("0x")
          ? UInt32(value.dropFirst(2), radix: 16) : UInt32(value)
        guard let integer else {
          throw ApplicationError(message: "Invalid DWORD value: \(value)")
        }

        self = .dword(integer)
      case "REG_BINARY":
        self = .binary(try Self.parseHex(value))
      case "REG_EXPAND_SZ":
        self = .expandableString(value)
      case "REG_MULTI_SZ":
        self = .strings(try Self.parseStrings(value))
      default:
        throw ApplicationError(message: "Unsupported registry type: \(componentType)")
      }
    }

    fileprivate var encoded: String {
      switch self {
      case .string(let value):
        return WineRegistry.quote(value)
      case .dword(let value):
        return String(format: "dword:%08x", value)
      case .binary(let value):
        return "hex:" + Self.hex(value)
      case .expandableString(let value):
        return "hex(2):" + Self.hex(WineRegistry.utf16(value + "\0"))
      case .strings(let values):
        // REG_MULTI_SZ ends each UTF-16 string with NUL and the list with another NUL.
        return "hex(7):" + Self.hex(WineRegistry.utf16(values.joined(separator: "\0") + "\0\0"))
      }
    }

    private static func hex(_ data: Data) -> String {
      data.map { String(format: "%02x", $0) }.joined(separator: ",")
    }

    private static func parseHex(_ value: String) throws -> Data {
      let text = value.filter { !$0.isWhitespace }
      guard text.count.isMultiple(of: 2) else {
        throw ApplicationError(message: "Invalid binary registry value.")
      }

      var data = Data()
      var index = text.startIndex
      while index < text.endIndex {
        let end = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<end], radix: 16) else {
          throw ApplicationError(message: "Invalid binary registry value.")
        }

        data.append(byte)
        index = end
      }

      return data
    }

    private static func parseStrings(_ value: String) throws -> [String] {
      var entries: [String] = []
      var current = ""
      var inQuotes = false
      var iterator = value.makeIterator()
      var next = iterator.next()

      while let character = next {
        next = iterator.next()
        if character == "\"" {
          // A doubled quote inside a quoted value represents a literal quote.
          if inQuotes && next == "\"" {
            current.append("\"")
            next = iterator.next()
          } else {
            inQuotes.toggle()
          }
        } else if character == "," && !inQuotes {
          entries.append(current)
          current = ""
        } else {
          current.append(character)
        }
      }

      guard !inQuotes else {
        throw ApplicationError(message: "Unterminated quoted registry value.")
      }

      entries.append(current)
      return entries
    }
  }

  private var lines = ["Windows Registry Editor Version 5.00", ""]

  mutating func addKey(_ name: String, values: [Entry]) {
    lines.append("[\(name)]")
    for entry in values {
      let name = entry.name.isEmpty ? "@" : Self.quote(entry.name)
      lines.append("\(name)=\(entry.value.encoded)")
    }

    lines.append("")
  }

  var data: Data {
    // Registry imports use UTF-16LE with a byte-order mark and CRLF line endings.
    var data = Data([0xFF, 0xFE])
    data.append(Self.utf16(lines.joined(separator: "\r\n")))

    return data
  }

  private static func quote(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }

  private static func utf16(_ value: String) -> Data {
    Data(value.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] })
  }
}
