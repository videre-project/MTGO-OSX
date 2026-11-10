import Combine
import Foundation

/// Starts and stops MTGO and reports installation and launch progress.
@MainActor
final class LauncherSession: ObservableObject {
  @Published private(set) var state: LauncherState = .idle
  @Published private(set) var activities: [LaunchActivity] = []
  @Published private(set) var deploymentVersion: String?
  @Published private(set) var latestVersion: String?
  @Published private(set) var isCheckingVersion = true
  @Published private(set) var requiresProgressWindow = false
  @Published private(set) var progress: StartupProgress?

  let settings: LauncherSettings
  private(set) var logURL: URL?

  private var downloadStart: (time: TimeInterval, bytes: Int64, total: Int64)?
  private var gameStarted = false
  private var launchTask: Task<Void, Never>?
  private var stopTask: Task<Void, Never>?
  private var activeRuntime: WineRuntime?
  private var launchSettings: (runtimeFolder: URL, softwareRendering: Bool, icon: URL?, userData: URL?)?
  private var sessionLock: SessionLock?
  private var activity: NSObjectProtocol?
  private let defaults: UserDefaults

  init(settings: LauncherSettings, defaults: UserDefaults = .standard) {
    self.settings = settings
    self.defaults = defaults
    latestVersion = defaults.string(forKey: "mtgoManifestVersion")
  }

  var gameExecutableURL: URL? { activeRuntime?.wineLoader.resolvingSymlinksInPath() }
  var isBusy: Bool { state.isBusy }
  var isRunning: Bool { state == .running }
  var failure: String? { state.failure }

  var requiresRestart: Bool {
    guard isBusy, let runtime = activeRuntime, let launchSettings else { return false }

    return settings.runtimeFolder?.standardizedFileURL.path != launchSettings.runtimeFolder.standardizedFileURL.path
      || settings.prefixFolder.standardizedFileURL.path != runtime.prefix.standardizedFileURL.path
      || settings.softwareRendering != launchSettings.softwareRendering
      || settings.iconURL != launchSettings.icon
      || settings.userDataFolder?.standardizedFileURL.path != launchSettings.userData?.standardizedFileURL.path
  }

  var versionLabel: String {
    if let version = deploymentVersion ?? latestVersion { return "Version \(version)" }

    return isCheckingVersion ? "Checking version…" : "Version unavailable"
  }

  var progressPercentage: Int? { progress?.fraction.map { Int($0 * 100) } }

  var downloadTimeRemaining: String? {
    guard let start = downloadStart, case .download(let bytes, _) = progress,
      bytes > start.bytes, bytes < start.total else { return nil }

    // Average over this transfer; allow a short warmup before estimating.
    let elapsed = ProcessInfo.processInfo.systemUptime - start.time
    guard elapsed >= 2 else { return nil }

    let remaining = Double(start.total - bytes) * elapsed / Double(bytes - start.bytes)
    if remaining < 5 { return "Less than 5s remaining" }

    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = remaining >= 3600 ? [.hour, .minute] : [.minute, .second]
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 2
    guard let duration = formatter.string(from: ceil(remaining / 5) * 5) else { return nil }

    return "About \(duration) remaining"
  }

  func refreshVersion() async {
    _ = await latestManifest()
  }

  private func latestManifest() async -> MTGOManifest? {
    isCheckingVersion = true
    defer { isCheckingVersion = false }

    do {
      let manifest = try await MTGOManifest.fetch()
      try Task.checkCancellation()

      // A cancelled session must not publish a late version response.
      latestVersion = manifest.version
      defaults.set(manifest.version, forKey: "mtgoManifestVersion")

      return manifest
    } catch {
      guard !Task.isCancelled else { return nil }

      NSLog("Could not retrieve the Videre manifest: %@", error.localizedDescription)
      return nil
    }
  }

  /// Starts a session, or identifies the process already using this prefix.
  func launch() {
    guard !isBusy else { return }

    // Clear the previous session before validation can present another failure.
    resetActivity()
    gameStarted = false
    requiresProgressWindow = false
    deploymentVersion = nil
    logURL = nil

    do {
      // Lock the prefix before downloading so another invocation can find this session.
      let prefix = settings.prefixFolder
      switch try SessionLock.acquire(prefix: prefix) {
      case .acquired(let lock): sessionLock = lock
      case .existing(let pid):
        state = .existingSession(pid)
        return
      }

      let log = try createLog()
      let customRuntime = settings.usesCustomRuntime ? settings.runtimeFolder : nil
      let softwareRendering = settings.softwareRendering
      let icon = settings.iconURL
      let userData = settings.userDataFolder
      logURL = log
      activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .idleSystemSleepDisabled], reason: "MTGO session"
      )

      state = .preparing("Preparing MTGO…")
      launchTask = Task {
        await run(
          prefix: prefix, customRuntime: customRuntime, softwareRendering: softwareRendering,
          icon: icon, userData: userData, log: log
        )
      }
    } catch {
      NSLog("Could not start MTGO: %@", error.localizedDescription)
      finish(with: .failed(error.localizedDescription))
    }
  }

  func mainWindowClosed() {
    guard isRunning else { return }

    state = .closing
  }

  func prepareForRelaunch() {
    guard isRunning || state == .closing else { return }

    resetActivity()
  }

  private func resetActivity() {
    activities = []
    resetProgress()
  }

  private func resetProgress() {
    progress = nil
    downloadStart = nil
  }

  /// Cancels preparation or closes every Wine process using this session's prefix.
  func stop() {
    guard isBusy, state != .stopping, stopTask == nil else { return }

    launchTask?.cancel()
    resetProgress()
    state = .stopping

    // A cancelled runtime download has no Wine process tree to stop.
    guard let runtime = activeRuntime, let log = logURL else { return }

    stopTask = Task {
      defer { stopTask = nil }

      do {
        // Stop only this session's prefix, including Wine's child processes.
        try await NativeProcess.run(runtime.wineserver, ["-k"], environment: runtime.environment, log: log)
      } catch {
        guard isBusy else { return }

        state = .stopFailed("Could not stop MTGO: \(error.localizedDescription)")
      }
    }
  }

  private func run(
    prefix: URL, customRuntime: URL?, softwareRendering: Bool,
    icon: URL?, userData: URL?, log: URL
  ) async {
    let result: LauncherState

    do {
      // Fetch the version while preparing the prefix, rather than adding a serial wait.
      async let manifest = latestManifest()
      let root: URL
      if let customRuntime {
        root = customRuntime
      } else {
        guard let catalog = settings.runtimeCatalog else {
          throw ApplicationError(message: "The runtime catalog is missing from this app.")
        }

        let package = try RuntimePackage.load(catalog: catalog)
        let installer = RuntimeInstaller(
          package: package, directory: settings.runtimeDirectory, cache: settings.packageCache, log: log
        ) { self.reportRuntimePreparation($0) }
        root = try await installer.installIfNeeded(prefix: prefix)
        settings.installedRuntime(root)
      }
      try Task.checkCancellation()

      let runtime = try WineRuntime.load(root: root, prefix: prefix)
      activeRuntime = runtime
      launchSettings = (root, softwareRendering, icon, userData)
      let changedData = try await WineUserData(prefix: prefix).prepare(folder: userData) {
        self.requiresProgressWindow = true
        self.resetProgress()
        self.state = .preparing("Preparing MTGO user data…")
        self.updateActivity(.userData)
      }
      if changedData { updateActivity(.userData, status: .completed) }
      try Task.checkCancellation()
      let registry = runtime.startupRegistry(softwareRendering: softwareRendering, icon: icon)
      let installer = FrameworkInstaller(runtime: runtime, cache: settings.packageCache, log: log) { progress in
        self.reportPreparation(progress)
      }
      try await installer.installIfNeeded(bootstrapRegistry: registry)
      try Task.checkCancellation()

      resetProgress()
      state = .launching(nil)
      let launcher = try launcherExecutable()
      updateActivity(.update)

      // Without a manifest, let the SDK perform its normal ClickOnce update check.
      var arguments = [launcher.path, "--progress-json", "--start-and-wait"]
      if let latest = await manifest { arguments += ["--expected-version", latest.version] }
      try await NativeProcess.run(runtime.wine, arguments, environment: runtime.environment, log: log) {
        self.receiveProgress($0)
      }

      guard isRunning || state == .closing else {
        throw ApplicationError(message: failure
          ?? "The MTGO launcher exited without confirming that MTGO started.")
      }

      // Launcher.exe retains MTGO's process handle until the game exits.
      result = .ended
    } catch {
      if Task.isCancelled {
        result = gameStarted ? .ended : .stopped
      } else {
        NSLog("Could not start MTGO: %@", error.localizedDescription)
        result = .failed(failure ?? error.localizedDescription)
      }
    }

    // Keep the prefix reserved until every stop attempt has completed.
    while let stopTask { await stopTask.value }

    if case .stopFailed(let message) = state {
      finish(with: .failed(message))
    } else {
      finish(with: result)
    }
  }

  private func reportRuntimePreparation(_ progress: RuntimeInstaller.Progress) {
    guard launchTask?.isCancelled == false else { return }

    switch progress {
    case .downloading:
      resetProgress()
      requiresProgressWindow = true
      state = .preparing("Downloading Wine runtime…")
      updateActivity(.runtime, detail: "Downloading native macOS components")
    case .transferring(let bytes, let total):
      recordDownload(bytes: bytes, total: total)
    case .installing(let completed, let total):
      requiresProgressWindow = true
      downloadStart = nil
      self.progress = .steps(completed: completed, total: total)
      state = .preparing("Installing Wine runtime…")
      updateActivity(.runtime, detail: "Extracting and verifying runtime")
    case .installed:
      resetProgress()
      updateActivity(.runtime, status: .completed)
    }
  }

  private func recordDownload(bytes: Int64, total: Int64) {
    guard bytes >= 0 else { return }

    progress = .download(bytes: bytes, total: total)
    guard bytes < total else { return }

    // Start a new estimate when the transfer changes or its byte counter resets.
    if downloadStart?.total != total || bytes < (downloadStart?.bytes ?? 0) {
      downloadStart = (ProcessInfo.processInfo.systemUptime, bytes, total)
    }
  }

  private func reportPreparation(_ progress: FrameworkInstaller.Progress) {
    guard launchTask?.isCancelled == false else { return }

    // Framework reports are emitted only when setup or native-image work is needed.
    requiresProgressWindow = true

    // Each phase has separate units and a separate download estimate.
    switch progress {
    case .transferring, .components, .assembly:
      break
    default:
      resetProgress()
    }

    switch progress {
    case .preparing:
      state = .preparing("Preparing MTGO…")
      updateActivity(.framework, detail: "Preparing runtime environment")
    case .downloading:
      state = .preparing("Downloading .NET Framework…")
      updateActivity(.framework, detail: "Downloading Framework package")
    case .transferring(let bytes, let total):
      recordDownload(bytes: bytes, total: total)
    case .unpacking:
      state = .preparing("Unpacking .NET Framework…")
      updateActivity(.framework, detail: "Extracting .NET Framework components")
    case .installing:
      state = .preparing("Installing .NET Framework…")
      updateActivity(.framework, detail: "Installing runtime and activation libraries")
    case .components(let completed, let total):
      self.progress = .components(completed: completed, total: total)
    case .configuring:
      state = .preparing("Finishing .NET Framework setup…")
      updateActivity(.framework, detail: "Configuring and validating .NET Framework")
    case .installed:
      updateActivity(.framework, status: .completed)
    case .optimizing:
      state = .preparing("Optimizing .NET Framework startup…")
      updateActivity(.optimization)
    case .assembly(let name):
      self.progress = .assembly(name)
      updateActivity(.optimization, detail: name)
    case .optimized:
      updateActivity(.optimization, status: .completed)
    case .optimizationFailed(let message):
      updateActivity(.optimization, status: .warning, message: message)
    }
  }

  private func receiveProgress(_ line: String) {
    guard launchTask?.isCancelled == false, state != .closing,
      let progress = LaunchProgress.decode(line) else { return }

    if let version = progress.version { deploymentVersion = version }
    if progress.stage == .verifyingRequirements || progress.stage == .downloading || progress.stage == .failed {
      requiresProgressWindow = true
    }

    if progress.stage == .downloading, let bytes = progress.bytesDownloaded, let total = progress.totalBytes {
      recordDownload(bytes: bytes, total: total)
    } else {
      resetProgress()
    }

    switch progress.stage {
    case .checkingForUpdates:
      updateActivity(.update, status: progress.version == nil ? .running : .completed,
        detail: progress.version == nil ? nil : "Installed version is current")
    case .verifyingRequirements:
      updateActivity(.update, detail: "Reading deployment manifest")
      updateActivity(.update, detail: "Checking application requirements")
    case .downloading:
      break
    case .updateCompleted:
      updateActivity(.update, status: .completed)
    case .starting:
      // The SDK can activate the installed client after an unsuccessful update.
      if activities.contains(where: { $0.id == .update && $0.status == .running }) {
        updateActivity(.update, status: .warning, message: "Update did not complete; using the installed client.")
      }
    case .started:
      gameStarted = true
    case .failed:
      finishActivities(status: .failed, message: progress.message)
    }

    state = progress.stage == .started ? .running : .launching(progress)
  }

  private func updateActivity(
    _ kind: LaunchActivity.Kind, status: LaunchActivity.Status = .running,
    detail: String? = nil, message: String? = nil
  ) {
    let index = activities.firstIndex { $0.id == kind }
    var activity = index.map { activities[$0] }
      ?? LaunchActivity(id: kind, startedAt: ProcessInfo.processInfo.systemUptime)

    // Late progress must not reopen a completed operation.
    guard activity.status == .running else { return }

    if let detail, !activity.details.contains(detail) { activity.details.append(detail) }
    activity.status = status
    activity.message = message
    if status != .running { activity.finishedAt = ProcessInfo.processInfo.systemUptime }

    if let index {
      activities[index] = activity
    } else {
      activities.append(activity)
    }
  }

  private func finishActivities(status: LaunchActivity.Status, message: String? = nil) {
    for activity in activities where activity.status == .running {
      updateActivity(activity.id, status: status, message: message)
    }
  }

  private func createLog() throws -> URL {
    let files = FileManager.default
    try files.createDirectory(at: settings.logsFolder, withIntermediateDirectories: true)

    let url = settings.logsFolder.appendingPathComponent("session-\(UUID().uuidString).log")
    guard files.createFile(atPath: url.path, contents: Data()) else {
      throw ApplicationError(message: "Could not create a session log at \(url.path).")
    }

    return url
  }

  private func launcherExecutable() throws -> URL {
    guard let launcher = Bundle.main.resourceURL?.appendingPathComponent("Launcher/Launcher.exe"),
      FileManager.default.fileExists(atPath: launcher.path) else {
      throw ApplicationError(message: "The MTGO launcher is missing from this app.")
    }

    return launcher
  }

  private func finish(with result: LauncherState) {
    switch result {
    case .failed(let message):
      finishActivities(status: .failed, message: message)
    case .stopped:
      finishActivities(status: .cancelled)
    default:
      break
    }

    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil
    activeRuntime = nil
    launchSettings = nil
    sessionLock = nil
    launchTask = nil
    resetProgress()

    // Terminal state observers may relaunch immediately; release the prefix first.
    state = result
  }
}
