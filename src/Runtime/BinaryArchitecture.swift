import Foundation

/// Reads executable headers without loading or executing the inspected binary.
enum BinaryArchitecture {
  private static func word(_ data: Data, _ offset: Int, bytes: Int, bigEndian: Bool = false) -> UInt64? {
    guard offset >= 0, bytes > 0, offset <= data.count - bytes else { return nil }

    var value: UInt64 = 0
    for index in 0..<bytes {
      let shift = bigEndian ? 8 * (bytes - index - 1) : 8 * index
      value |= UInt64(data[offset + index]) << shift
    }

    return value
  }

  private static func header(_ file: URL, count: Int = 4096) throws -> Data {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }

    return try handle.read(upToCount: count) ?? Data()
  }

  static func containsMachO(_ file: URL, architecture: RuntimeArchitecture) throws -> Bool {
    let data = try header(file)

    // Thin Mach-O files store the CPU type directly after their magic value.
    if word(data, 0, bytes: 4) == 0xFEEDFACF {
      return word(data, 4, bytes: 4) == architecture.machCPU
    }

    // Universal binaries have a big-endian table of architecture records.
    let magic = word(data, 0, bytes: 4, bigEndian: true)
    guard magic == 0xCAFEBABE || magic == 0xCAFEBABF,
      let count = word(data, 4, bytes: 4, bigEndian: true), count <= 64 else { return false }

    let stride = magic == 0xCAFEBABF ? 32 : 20
    for index in 0..<Int(count) {
      if word(data, 8 + index * stride, bytes: 4, bigEndian: true) == architecture.machCPU { return true }
    }

    return false
  }

  static func peMachine(_ file: URL) throws -> UInt64? {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }

    // The DOS header points to the PE signature and COFF machine field.
    let dos = try handle.read(upToCount: 64) ?? Data()
    guard dos.prefix(2) == Data([0x4D, 0x5A]), let offset = word(dos, 60, bytes: 4) else { return nil }

    try handle.seek(toOffset: offset)
    let pe = try handle.read(upToCount: 6) ?? Data()
    guard pe.prefix(4) == Data([0x50, 0x45, 0, 0]) else { return nil }

    return word(pe, 4, bytes: 2)
  }
}
