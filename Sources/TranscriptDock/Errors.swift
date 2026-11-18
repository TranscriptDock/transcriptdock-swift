import Foundation

/// An API or transport failure. Requests are never retried automatically.
///
/// Transport failures and timeouts use the code `NETWORK_ERROR`. Bodies that are
/// not a JSON object use `INVALID_RESPONSE`. A redirect is never followed and
/// surfaces here with its 3xx status. Messages have bearer tokens redacted.
public struct ApiError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// The API error code, such as `RATE_LIMITED` or `NETWORK_ERROR`.
    public let code: String
    /// A human readable message with credentials redacted.
    public let message: String
    /// The HTTP status, or `nil` when no response arrived.
    public let status: Int?
    /// Whether the API says the same request may succeed later.
    public let retryable: Bool
    /// The API request ID, useful when contacting support.
    public let requestId: String?
    /// How long the API asks you to wait before trying again.
    public let retryAfterSeconds: Double?

    public init(code: String, message: String, status: Int? = nil, retryable: Bool = false,
                requestId: String? = nil, retryAfterSeconds: Double? = nil) {
        self.code = code
        self.message = message
        self.status = status
        self.retryable = retryable
        self.requestId = requestId
        self.retryAfterSeconds = retryAfterSeconds
    }

    public var description: String { "\(code): \(message)" }
    public var errorDescription: String? { description }
}

/// Polling stopped at the deadline while the job was still running.
///
/// The job keeps running. Check it again later with its ID.
public struct JobTimeoutError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// The last job response observed, or `nil` if no poll completed.
    public let job: [String: JSONValue]?

    public init(job: [String: JSONValue]?) {
        self.job = job
    }

    public var message: String { "The job is still running. Check it again using its ID." }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// A problem with the arguments passed to the client. Nothing was sent.
public enum TranscriptDockError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .invalidArgument(let message): return message
        }
    }

    public var errorDescription: String? { description }
}
