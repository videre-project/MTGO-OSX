import AppKit
import CoreGraphics
import Darwin

@MainActor
private final class SessionPeers {
  var gamePID: pid_t?
  var mainWindowSize: CGSize?
  var processes = Set<pid_t>()
}

// Observe real app roles while the Win32 observer checks MTGO's window and CLR.
@main
enum LauncherObserver {
  @MainActor
  static func main() {
    let arguments = CommandLine.arguments
    if arguments.count == 3, arguments[1] == "--launcher", let pid = Int32(arguments[2]) {
      observeLauncher(pid: pid)
      return
    }
    guard (5...6).contains(arguments.count), let pid = Int32(arguments[1]) else { exit(2) }
    let expectProgress = arguments.count == 5
    let complete = URL(fileURLWithPath: arguments[2])
    let launch = arguments[3]
    let runtime = URL(fileURLWithPath: arguments[4]).appendingPathComponent("MTGO.app").resolvingSymlinksInPath()
    let timeout = Double(ProcessInfo.processInfo.environment["MTGO_STARTUP_TIMEOUT"] ?? "600") ?? 600
    let deadline = Date().addingTimeInterval(timeout + 120)
    let peers = SessionPeers()
    let registration = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("WineAppDockProxyReady"), object: String(pid), queue: .main
    ) { notification in
      guard let peerPID = (notification.userInfo?["pid"] as? NSNumber)?.int32Value,
        let name = notification.userInfo?["processName"] as? String else { return }
      let reportedSize: CGSize?
      if let frame = notification.userInfo?["frame"] as? [String: NSNumber],
        let width = frame["width"], let height = frame["height"] {
        reportedSize = CGSize(width: width.doubleValue, height: height.doubleValue)
      } else {
        reportedSize = nil
      }
      Task { @MainActor in
        peers.processes.insert(peerPID)
        if name.caseInsensitiveCompare("MTGO.exe") == .orderedSame {
          peers.gamePID = peerPID
          if let reportedSize { peers.mainWindowSize = reportedSize }
        }
      }
    }
    defer { DistributedNotificationCenter.default().removeObserver(registration) }
    var sawWindow = false
    var sawDockIcon = false
    var checkedLaunchIcon = false
    var firstDockTime: TimeInterval?
    var firstWindowTime: TimeInterval?
    let started = ProcessInfo.processInfo.systemUptime
    var readyDeadline: Date?

    while true {
      guard Date() < deadline else { fail("Native launcher observation timed out.") }
      guard kill(pid, 0) == 0 else { fail("Native Dock owner exited before MTGO was ready.") }
      guard let owner = NSRunningApplication(processIdentifier: pid) else {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        continue
      }
      guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
        fail("Could not observe native windows.")
      }
      let nativeWindows = windows.filter {
        ($0[kCGWindowOwnerPID as String] as? Int32) == pid
          && ($0[kCGWindowLayer as String] as? Int) == 0
          && (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0
      }
      let nativeWindowVisible = !nativeWindows.isEmpty
      if !expectProgress, nativeWindowVisible { fail("A routine launch displayed progress despite its preference.") }
      sawWindow = sawWindow || nativeWindowVisible
      if nativeWindowVisible && firstWindowTime == nil {
        firstWindowTime = ProcessInfo.processInfo.systemUptime - started
      }
      if owner.activationPolicy == .regular {
        sawDockIcon = true
        if firstDockTime == nil { firstDockTime = ProcessInfo.processInfo.systemUptime - started }
        if !checkedLaunchIcon {
          guard let app = owner.bundleURL, let bundle = Bundle(url: app),
            bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "GameIcon",
            let resources = bundle.resourceURL,
            NSImage(contentsOf: resources.appendingPathComponent("GameIcon.icns")) != nil else {
            fail("Installed-app launch did not advertise MTGO's game icon.")
          }
          checkedLaunchIcon = true
        }
      } else if sawDockIcon {
        fail("The native app removed its Dock entry during the session.")
      }
      for peer in peers.processes {
        guard NSRunningApplication(processIdentifier: peer)?.activationPolicy != .regular else {
          fail("A Wine UI process created an additional Dock entry.")
        }
      }
      if FileManager.default.fileExists(atPath: complete.path) {
        let end = readyDeadline ?? Date().addingTimeInterval(5)
        readyDeadline = end
        if !nativeWindowVisible, owner.isFinishedLaunching,
          let gamePID = peers.gamePID, let size = peers.mainWindowSize,
          let game = NSRunningApplication(processIdentifier: gamePID),
          windows.contains(where: {
            ($0[kCGWindowOwnerPID as String] as? Int32) == gamePID
              && ($0[kCGWindowLayer as String] as? Int) == 0
              && windowSize($0) == size
              && (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0
          }) {
          guard let app = owner.bundleURL else { fail("Native Dock owner has no app bundle.") }
          guard let icon = try? Data(contentsOf: app.appendingPathComponent("Contents/Resources/GameIcon.icns")),
            let gameIcon = try? Data(contentsOf: runtime.appendingPathComponent("Contents/Resources/GameIcon.icns")),
            icon == gameIcon else { fail("Launcher and downloaded runtime have different game icons.") }
          guard game.activationPolicy == .accessory else {
            fail("MTGO's helper must be an accessory app; policy was \(game.activationPolicy.rawValue).")
          }
          guard game.localizedName == "MTGO", game.bundleIdentifier == "org.videreproject.MTGOOSX.Runtime" else {
            fail("MTGO helper identity: name=\(game.localizedName ?? "nil"), bundle=\(game.bundleIdentifier ?? "nil").")
          }
          let executable = game.executableURL?.resolvingSymlinksInPath()
          // Resolve after installation; Foundation normalizes /private aliases only for existing paths.
          let expected = runtime.appendingPathComponent("Contents/MacOS/wine").resolvingSymlinksInPath()
          guard executable == expected else {
            fail("MTGO helper executable was \(executable?.path ?? "nil"); expected \(expected.path).")
          }
          print("PASS: the same native process remained the sole Dock owner; MTGO's visible UI stayed in an accessory helper.")
          break
        }
        guard Date() < end else {
          fail("The launcher did not hand off to MTGO's visible UI helper: nativeVisible=\(nativeWindowVisible), "
            + "gamePID=\(String(describing: peers.gamePID)), frame=\(String(describing: peers.mainWindowSize)), "
            + "nativeFinished=\(owner.isFinishedLaunching), nativeWindows=\(nativeWindows), "
            + "gameWindows=\(windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == peers.gamePID }).")
        }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    guard sawDockIcon, checkedLaunchIcon else { fail("MTGO did not show its game icon throughout startup.") }
    print(String(format: "PASS: startup Dock icon appeared after %.2f seconds and stayed with the same process.", firstDockTime ?? 0))
    if expectProgress {
      guard sawWindow, let firstWindowTime else { fail("MTGO did not present its native startup window.") }
      print(String(format: "PASS: %@ presented its launcher after %.2f seconds and dismissed it when MTGO was ready.", launch, firstWindowTime))
    } else {
      print("PASS: routine startup kept the progress window hidden while retaining the Dock entry.")
    }
  }

  @MainActor
  private static func observeLauncher(pid: pid_t) {
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
      guard kill(pid, 0) == 0 else { fail("Native launcher exited before presenting its window.") }
      let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
      let window = windows.first {
        ($0[kCGWindowOwnerPID as String] as? Int32) == pid
          && ($0[kCGWindowLayer as String] as? Int) == 0
          && (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0
      }
      if let window, let bounds = window[kCGWindowBounds as String] as? [String: NSNumber],
        let x = bounds["X"], let y = bounds["Y"],
        let width = bounds["Width"], let height = bounds["Height"],
        let primary = NSScreen.screens.first,
        let app = NSRunningApplication(processIdentifier: pid), app.isFinishedLaunching {
        let frame = NSRect(x: x.doubleValue, y: primary.frame.maxY - y.doubleValue - height.doubleValue,
          width: width.doubleValue, height: height.doubleValue)
        guard NSScreen.screens.contains(where: { $0.visibleFrame.contains(frame) }) else {
          fail("Native launcher extends beyond its display's usable area: window=\(frame), "
            + "displays=\(NSScreen.screens.map { $0.visibleFrame }).")
        }
        guard app.activationPolicy == .regular else { fail("Native launcher has no Dock entry.") }
        print("PASS: native launcher presented an on-screen window with its Dock entry.")
        return
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    fail("Native launcher did not present its window.")
  }

  private static func windowSize(_ window: [String: Any]) -> CGSize? {
    guard let bounds = window[kCGWindowBounds as String] as? [String: NSNumber],
      let width = bounds["Width"], let height = bounds["Height"] else { return nil }
    return CGSize(width: width.doubleValue, height: height.doubleValue)
  }

  private static func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}
