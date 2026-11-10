import Darwin
import Foundation

/// Reserves one Wine prefix for the lifetime of its native session.
final class SessionLock {
  enum Claim {
    case acquired(SessionLock)
    case existing(pid_t)
  }

  private let descriptor: Int32

  private init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit { close(descriptor) }

  static func acquire(prefix: URL) throws -> Claim {
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    let path = prefix.appendingPathComponent(".mtgo-session.lock").path

    // Keep the lock file open until the session ends; child processes must not inherit it.
    let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    guard descriptor >= 0 else { throw failure(errno) }
    let session = SessionLock(descriptor: descriptor)

    while true {
      var lock = flock()
      lock.l_type = Int16(F_WRLCK)
      lock.l_whence = Int16(SEEK_SET)
      if fcntl(descriptor, F_SETLK, &lock) == 0 { return .acquired(session) }

      let error = errno
      guard error == EAGAIN || error == EACCES else { throw failure(error) }
      guard fcntl(descriptor, F_GETLK, &lock) == 0 else { throw failure(errno) }

      // The process holding the lock may have exited before F_GETLK returned.
      if lock.l_type == Int16(F_UNLCK) { continue }
      guard lock.l_pid > 0 else { throw failure(EIO) }

      return .existing(lock.l_pid)
    }
  }

  private static func failure(_ error: Int32) -> ApplicationError {
    ApplicationError(message: "Could not reserve the Wine prefix: \(String(cString: strerror(error))).")
  }
}
