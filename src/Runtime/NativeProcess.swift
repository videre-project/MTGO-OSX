import Darwin
import Foundation

/// Reads stdout without waiting for Wine descendants to close inherited pipe handles.
private final class ProcessOutput {
  let pipe = Pipe()
  private let log: FileHandle
  private let onLine: (@MainActor @Sendable (String) -> Void)?
  private let queue = DispatchQueue(label: "MTGO.process-output")
  private let source: DispatchSourceRead
  private var pending = Data()
  private var finished = false
  private var reachedEOF = false
  private var failure: Error?

  init(log: FileHandle, onLine: (@MainActor @Sendable (String) -> Void)?) throws {
    self.log = log
    self.onLine = onLine

    // Wine children can outlive this process while retaining its stdout handle.
    let input = pipe.fileHandleForReading
    let flags = fcntl(input.fileDescriptor, F_GETFL)
    guard flags >= 0, fcntl(input.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    source = DispatchSource.makeReadSource(fileDescriptor: input.fileDescriptor, queue: queue)
    source.setEventHandler { [weak self] in self?.drain() }
    source.setCancelHandler { try? input.close() }
    source.resume()
  }

  private func drain() {
    guard !finished, !reachedEOF else { return }

    var bytes = [UInt8](repeating: 0, count: 8192)
    while true {
      let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
      if count < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK { break }
        failure = failure ?? POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }

      if count <= 0 {
        reachedEOF = true
        source.cancel()
        break
      }

      let data = Data(bytes.prefix(count))
      do {
        try log.write(contentsOf: data)
      } catch {
        failure = failure ?? error
      }

      // Persist all output, but send only complete stdout lines to the progress handler.
      guard onLine != nil else { continue }

      pending.append(data)
      while let newline = pending.firstIndex(of: 10) {
        let line = String(decoding: pending[..<newline], as: UTF8.self)
          .trimmingCharacters(in: .newlines)
        pending.removeSubrange(...newline)
        deliver(line)
      }

      // Diagnostic output is unbounded; only retain a bounded partial progress record.
      if pending.count > 65_536 { pending.removeAll(keepingCapacity: true) }
    }
  }

  private func deliver(_ line: String) {
    guard let onLine else { return }

    DispatchQueue.main.async { onLine(line) }
  }

  func finish(_ completion: @escaping @Sendable (Error?) -> Void) {
    queue.async {
      self.drain()
      if !self.pending.isEmpty {
        self.deliver(String(decoding: self.pending, as: UTF8.self))
      }

      self.finished = true
      self.source.cancel()
      do {
        try self.log.close()
      } catch {
        self.failure = self.failure ?? error
      }

      let failure = self.failure
      // Deliver final progress before the awaiting session handles process completion.
      DispatchQueue.main.async { completion(failure) }
    }
  }
}

/// Runs a native tool with session logging and optional launcher progress records.
enum NativeProcess {
  /// Checks cancellation before launch and after exit.
  /// LauncherSession.stop terminates the session's Wine processes.
  static func run(
    _ executable: URL,
    _ arguments: [String],
    environment: [String: String]? = nil,
    log: URL,
    onOutput: (@MainActor @Sendable (String) -> Void)? = nil
  ) async throws {
    try Task.checkCancellation()

    let exitStatus = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
      do {
        let descriptor = Darwin.open(log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let reader = try ProcessOutput(log: output, onLine: onOutput)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = reader.pipe
        process.standardError = output
        process.standardInput = FileHandle.nullDevice

        process.terminationHandler = { process in
          reader.finish { error in
            if let error {
              continuation.resume(throwing: error)
            } else {
              continuation.resume(returning: process.terminationStatus)
            }
          }
        }

        do {
          try process.run()

          // Close the parent's write handle; ProcessOutput closes the read handle when finished.
          try? reader.pipe.fileHandleForWriting.close()
        } catch {
          try? reader.pipe.fileHandleForWriting.close()
          reader.finish { _ in continuation.resume(throwing: error) }
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }

    try Task.checkCancellation()
    guard exitStatus == 0 else {
      throw ApplicationError(message: "\(executable.lastPathComponent) exited with status \(exitStatus). See the session log.")
    }
  }
}
