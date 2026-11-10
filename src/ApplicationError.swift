import Foundation

/// A user-facing failure shared by application and runtime code.
struct ApplicationError: LocalizedError {
  let message: String

  var errorDescription: String? { message }
}
