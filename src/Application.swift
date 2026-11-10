import AppKit

@main
enum MTGOApplication {
  @MainActor
  static func main() {
    let application = NSApplication.shared
    let delegate = AppDelegate(session: LauncherSession(settings: LauncherSettings()))
    application.delegate = delegate

    // NSApplication does not retain its delegate.
    withExtendedLifetime(delegate) { application.run() }
  }
}
