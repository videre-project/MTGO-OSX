import Foundation

/// Native binary formats and Framework layout for one runtime architecture.
enum RuntimeArchitecture: String, Decodable {
  case arm64, x86_64

  static var native: RuntimeArchitecture {
    #if arch(arm64)
    return .arm64
    #else
    return .x86_64
    #endif
  }

  var machCPU: UInt64 { self == .arm64 ? 0x0100000C : 0x01000007 }
  var peMachine: UInt64 { self == .arm64 ? 0xAA64 : 0x8664 }
  var frameworkFolder: String { self == .arm64 ? "FrameworkArm64" : "Framework64" }
  var componentName: String { self == .arm64 ? "arm64" : "amd64" }
  var gacFolder: String { self == .arm64 ? "GAC_ARM64" : "GAC_64" }
}
