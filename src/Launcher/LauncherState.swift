import Foundation

/// MTGO session states, including periods when the launcher window is hidden.
enum LauncherState: Equatable {
  case idle
  case preparing(String)
  case launching(LaunchProgress?)
  case running
  case closing
  case existingSession(Int32)
  case stopping
  case stopFailed(String)
  case stopped
  case ended
  case failed(String)

  var isBusy: Bool {
    switch self {
    case .preparing, .launching, .running, .closing, .stopping, .stopFailed:
      return true
    case .idle, .existingSession, .stopped, .ended, .failed:
      return false
    }
  }

  var failure: String? {
    switch self {
    case .failed(let message), .stopFailed(let message):
      return message
    case .launching(let progress) where progress?.stage == .failed:
      return progress?.message ?? progress?.title
    default:
      return nil
    }
  }

  var needsWindow: Bool {
    switch self {
    case .preparing, .launching, .failed, .stopFailed:
      return true
    default:
      return false
    }
  }

  var title: String {
    switch self {
    case .idle:
      return "Ready to play"
    case .preparing(let message):
      return message
    case .launching(let progress):
      return progress?.title ?? "Checking for MTGO updates…"
    case .running:
      return "MTGO is running."
    case .closing:
      return "Waiting for MTGO to finish closing…"
    case .existingSession:
      return "MTGO is already running."
    case .stopping:
      return "Stopping the MTGO session…"
    case .stopFailed:
      return "Could not stop MTGO"
    case .stopped:
      return "Session stopped."
    case .ended:
      return "Session ended."
    case .failed:
      return "Unable to start MTGO"
    }
  }
}
