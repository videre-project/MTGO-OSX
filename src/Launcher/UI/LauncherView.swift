import AppKit
import SwiftUI

/// Startup and update progress, dismissed when MTGO's main window is ready.
struct LauncherView: View {
  static let size = CGSize(width: 600, height: 360)

  @ObservedObject private var session: LauncherSession
  @ObservedObject private var settings: LauncherSettings
  private let showSettings: () -> Void
  private let showLogs: () -> Void
  private let cancelLaunch: () -> Void

  init(
    session: LauncherSession, showSettings: @escaping () -> Void, showLogs: @escaping () -> Void,
    cancelLaunch: @escaping () -> Void
  ) {
    self.session = session
    settings = session.settings
    self.showSettings = showSettings
    self.showLogs = showLogs
    self.cancelLaunch = cancelLaunch
  }

  private var updating: Bool { session.isBusy && !session.isRunning }

  var body: some View {
    ZStack {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 24) {
          header
          progress
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        recentActivity
        controls
      }
      .padding(.horizontal, 32)
      .padding(.top, 32)
      .padding(.bottom, 20)

      closeControl
    }
    .frame(width: Self.size.width, height: Self.size.height)
    .clipped()
    .tint(LauncherTheme.accent)
    .preferredColorScheme(.dark)
  }

  private var header: some View {
    HStack(spacing: 16) {
      if let icon = LauncherTheme.gameIcon {
        Image(nsImage: icon)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .frame(width: 48, height: 52)
          .accessibilityHidden(true)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("MTGO")
          .font(LauncherTheme.titleFont)
          .foregroundColor(.white)
        Text("Magic: The Gathering Online")
          .font(LauncherTheme.bodyFont)
          .foregroundColor(.white.opacity(0.65))
      }
      Spacer()
    }
  }

  private var progress: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(status)
          .font(LauncherTheme.statusFont)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 12)
        if updating, let percentage = session.progressPercentage {
          Text("\(percentage)%")
            .font(LauncherTheme.controlFont)
            .monospacedDigit()
        }
      }

      if updating {
        StartupProgressBar(fraction: session.progress?.fraction)
        HStack(alignment: .firstTextBaseline) {
          Text(session.progress?.detail ?? " ")
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 12)
          if let remaining = session.downloadTimeRemaining { Text(remaining) }
        }
        .font(LauncherTheme.bodyFont)
        .monospacedDigit()
        .foregroundColor(.white.opacity(0.70))
      }

      if let failure = session.failure {
        Text(failure)
          .font(LauncherTheme.bodyFont)
          .lineLimit(2)
          .foregroundColor(.white.opacity(0.75))
          .textSelection(.enabled)
      }
    }
    .foregroundColor(.white)
    .frame(minHeight: 60, alignment: .topLeading)
  }

  private var recentActivity: some View {
    ActivityView(operations: session.activities)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.black.opacity(0.25))
      .overlay(Rectangle().strokeBorder(.white.opacity(0.09), lineWidth: 1))
  }

  private var controls: some View {
    HStack(spacing: 14) {
      Text(session.versionLabel)
        .font(LauncherTheme.bodyFont)
        .foregroundColor(.white.opacity(0.60))
      Spacer()

      Button(action: showLogs) { Image(systemName: "doc.text") }
        .help("Show session log")
        .accessibilityLabel("Show session log")
      Button(action: showSettings) { Image(systemName: "gearshape") }
        .help("Settings")
        .accessibilityLabel("Settings")

      launchControl
    }
    .font(LauncherTheme.bodyFont)
    .buttonStyle(.plain)
    .foregroundColor(.white.opacity(0.70))
  }

  private var launchControl: some View {
    Button(action: session.isBusy ? cancelLaunch : session.launch) {
      Text(session.isBusy ? "Cancel" : (session.failure == nil ? "Play" : "Try again"))
        .font(LauncherTheme.controlFont)
        .padding(.horizontal, 18)
        .frame(height: 34)
        .background(session.isBusy ? LauncherTheme.secondary : LauncherTheme.accent, in: Rectangle())
        .overlay(Rectangle().strokeBorder(
          session.isBusy ? LauncherTheme.border.opacity(0.65) : LauncherTheme.accent.opacity(0.8)
        ))
        .foregroundColor(session.isBusy ? .white : LauncherTheme.background)
    }
    .keyboardShortcut(session.isBusy ? .cancelAction : .defaultAction)
  }

  private var closeControl: some View {
    VStack {
      HStack {
        Spacer()
        Button { NSApplication.shared.terminate(nil) } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.8))
            .frame(width: 28, height: 28)
            .background(.black.opacity(0.2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close")
        .accessibilityLabel("Close MTGO")
      }
      Spacer()
    }
    .padding(14)
  }

  private var status: String {
    if session.failure != nil || session.isBusy { return session.state.title }

    return "Ready to play"
  }
}
