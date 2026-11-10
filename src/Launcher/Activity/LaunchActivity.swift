import Foundation

/// One operation in the setup and update history.
struct LaunchActivity: Equatable {
  enum Kind: Hashable {
    case runtime, userData, framework, optimization, update

    var title: String {
      switch self {
      case .runtime:
        return "Installing Wine runtime"
      case .userData:
        return "Configuring MTGO user data"
      case .framework:
        return "Installing .NET Framework"
      case .optimization:
        return "Optimizing .NET Framework"
      case .update:
        return "Updating MTGO"
      }
    }
  }

  enum Status {
    case running, completed, warning, failed, cancelled
  }

  let id: Kind
  let startedAt: TimeInterval
  var finishedAt: TimeInterval?
  var status: Status = .running
  var details: [String] = []
  var message: String?

  var summary: String? {
    guard id == .optimization, !details.isEmpty else { return nil }

    return "\(details.count) \(details.count == 1 ? "assembly" : "assemblies")"
  }

  func elapsed() -> String {
    let seconds = Int(max(0, (finishedAt ?? ProcessInfo.processInfo.systemUptime) - startedAt))

    return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
  }
}
