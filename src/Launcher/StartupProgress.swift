import Foundation

/// Measured work in the current setup or download phase.
enum StartupProgress: Equatable {
  case download(bytes: Int64, total: Int64)
  case components(completed: Int, total: Int)
  case steps(completed: Int, total: Int)
  case assembly(String)

  var fraction: Double? {
    let completed: Double
    let total: Double
    switch self {
    case .download(let bytes, let size):
      completed = Double(bytes)
      total = Double(size)
    case .components(let count, let size), .steps(let count, let size):
      completed = Double(count)
      total = Double(size)
    case .assembly:
      return nil
    }

    guard total > 0 else { return nil }
    return min(1, max(0, completed / total))
  }

  var detail: String {
    switch self {
    case .download(let bytes, let total):
      let received = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
      guard total > 0 else { return received }
      return "\(received) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    case .components(let completed, let total):
      return "\(completed) of \(total) components"
    case .steps(let completed, let total):
      return "\(completed) of \(total) steps"
    case .assembly(let name):
      return name
    }
  }
}
