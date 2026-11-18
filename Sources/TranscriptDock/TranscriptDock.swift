import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An async client for the Transcript Dock API.
///
/// Responses are `[String: JSONValue]` dictionaries that keep every field the API
/// returns. Requests are never retried automatically and redirects are never
/// followed, so a submission is sent at most once per call.
///
/// ```swift
/// let client = try TranscriptDock(apiKey: apiKey)
/// let job = try await client.createJob(
///     ["source": ["url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"],
///      "mode": "captions_only", "max_credits": 1],
///     idempotencyKey: UUID().uuidString)
/// ```
public final class TranscriptDock: Sendable {
    /// The library version, sent in the `User-Agent` header.
    public static let version = "0.1.0"
    /// The production API origin.
    public static let defaultBaseURL = "https://www.transcriptdock.com"

    /// The default timeout in seconds for each request.
    public let timeout: TimeInterval
    private let apiKey: String
    private let baseURL: String
    private let transport: Transport

    private static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
    private static let keyedSubmissions: Set<String> = ["/v1/jobs", "/v1/batches", "/v1/video-discoveries", "/v1/language-discoveries"]
    private static let terminalStatuses: Set<String> = ["succeeded", "failed", "cancelled"]
    private static let exportFormats: Set<String> = ["json", "txt", "srt", "vtt"]

    /// Creates a client.
    ///
    /// - Parameters:
    ///   - apiKey: Your Transcript Dock API key. Printable ASCII without spaces.
    ///   - baseURL: The API origin. HTTPS, or HTTP on loopback for local development.
    ///     No credentials, path, query or fragment.
    ///   - timeout: The default timeout in seconds for each request.
    /// - Throws: ``TranscriptDockError/invalidArgument(_:)`` for an invalid key, origin or timeout.
    public init(apiKey: String, baseURL: String = TranscriptDock.defaultBaseURL, timeout: TimeInterval = 30) throws {
        guard !apiKey.isEmpty, apiKey.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw TranscriptDockError.invalidArgument("Provide an API key without whitespace or control characters.")
        }
        guard let origin = URLComponents(string: baseURL),
              let scheme = origin.scheme?.lowercased(),
              let host = origin.host.map(Self.normalizedHost), !host.isEmpty,
              scheme == "https" || (scheme == "http" && Self.isLoopback(host)) else {
            throw TranscriptDockError.invalidArgument("Use an HTTPS origin, or HTTP on loopback for local development.")
        }
        guard origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              origin.path == "" || origin.path == "/" else {
            throw TranscriptDockError.invalidArgument("The API origin cannot contain credentials, a path, query or fragment.")
        }
        if let port = origin.port, !(0...65535).contains(port) {
            throw TranscriptDockError.invalidArgument("The API origin has an invalid port.")
        }
        var trimmed = baseURL
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.apiKey = apiKey
        self.baseURL = trimmed
        self.timeout = try Self.positive(timeout, "timeout")
        self.transport = Transport()
    }

    deinit {
        transport.invalidate()
    }

    // MARK: Generic requests

    /// Calls a public `/v1/` endpoint and returns its JSON object.
    ///
    /// Use this for endpoints added after this version. Redirects are not followed
    /// and nothing is retried automatically.
    ///
    /// - Parameters:
    ///   - method: An uppercase HTTP method: GET, POST, PUT, PATCH, DELETE, HEAD or OPTIONS.
    ///   - path: A path starting with `/v1/`. Pass query parameters through `query`.
    ///   - body: An optional JSON body.
    ///   - query: Query parameters. `null` values are skipped.
    ///   - idempotencyKey: 8 to 128 printable ASCII characters. Required for
    ///     submissions such as `POST /v1/jobs` and `POST .../retry`.
    ///   - timeout: Seconds allowed for this request. Defaults to ``timeout``.
    /// - Throws: ``ApiError`` for API and transport failures,
    ///   ``TranscriptDockError/invalidArgument(_:)`` before anything is sent.
    public func request(_ method: String, _ path: String, body: [String: JSONValue]? = nil,
                        query: [String: JSONValue] = [:], idempotencyKey: String? = nil,
                        timeout: TimeInterval? = nil) async throws -> [String: JSONValue] {
        let text = try await requestText(method, path, body: body, query: query,
                                         idempotencyKey: idempotencyKey, timeout: timeout)
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        } catch {
            throw ApiError(code: "INVALID_RESPONSE", message: "The API did not return JSON.")
        }
        guard case .object(let object) = value else {
            throw ApiError(code: "INVALID_RESPONSE", message: "The API did not return a JSON object.")
        }
        return object
    }

    /// Calls a public `/v1/` endpoint and returns the response body as text.
    ///
    /// Takes the same arguments as ``request(_:_:body:query:idempotencyKey:timeout:)``.
    public func requestText(_ method: String, _ path: String, body: [String: JSONValue]? = nil,
                            query: [String: JSONValue] = [:], idempotencyKey: String? = nil,
                            timeout: TimeInterval? = nil) async throws -> String {
        guard Self.methods.contains(method) else {
            throw TranscriptDockError.invalidArgument("Provide a supported HTTP method in uppercase.")
        }
        guard path.hasPrefix("/v1/"), !path.contains(where: { $0 == "?" || $0 == "#" || $0 == "\\" }) else {
            throw TranscriptDockError.invalidArgument("Use a /v1/ path and pass query parameters separately.")
        }
        let decoded = path.removingPercentEncoding ?? path
        if decoded.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) {
            throw TranscriptDockError.invalidArgument("API paths cannot contain traversal segments.")
        }
        let needsKey = method == "POST" && (Self.keyedSubmissions.contains(path) || path.hasSuffix("/retry"))
        if needsKey && idempotencyKey == nil {
            throw TranscriptDockError.invalidArgument("Provide an idempotency key for this submission.")
        }
        if let key = idempotencyKey,
           !((8...128).contains(key.unicodeScalars.count) && key.unicodeScalars.allSatisfy({ (32...126).contains($0.value) })) {
            throw TranscriptDockError.invalidArgument("Idempotency keys must contain 8 to 128 printable ASCII characters.")
        }
        let seconds = try Self.positive(timeout ?? self.timeout, "timeout")

        var address = baseURL + path
        let pairs = try Self.queryPairs(query)
        if !pairs.isEmpty { address += "?" + pairs.joined(separator: "&") }
        guard let url = URL(string: address) else {
            throw TranscriptDockError.invalidArgument("Use a /v1/ path and pass query parameters separately.")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: seconds.rounded(.up))
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("transcriptdock-swift/\(Self.version)", forHTTPHeaderField: "User-Agent")
        if let key = idempotencyKey { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        if let body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            do {
                request.httpBody = try encoder.encode(body)
            } catch {
                throw TranscriptDockError.invalidArgument("Request bodies must be JSON without NaN or infinite numbers.")
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let result: (Data, HTTPURLResponse)
        do {
            result = try await transport.send(request, timeout: seconds)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw ApiError(code: "NETWORK_ERROR",
                           message: "Could not reach the API. Check the job before retrying a submission.",
                           retryable: true)
        }
        let (data, response) = result
        guard (200..<300).contains(response.statusCode) else {
            throw apiError(status: response.statusCode, data: data)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ApiError(code: "INVALID_RESPONSE", message: "The API response is not UTF-8 text.")
        }
        return text
    }

    // MARK: Account

    /// Reads supported platforms, modes and pricing. `GET /v1/capabilities`.
    public func capabilities() async throws -> [String: JSONValue] {
        try await request("GET", "/v1/capabilities")
    }

    /// Reads credit balance and usage. `GET /v1/usage`.
    public func usage() async throws -> [String: JSONValue] {
        try await request("GET", "/v1/usage")
    }

    // MARK: Jobs

    /// Submits a transcription job. `POST /v1/jobs`. This can spend credits.
    ///
    /// - Parameters:
    ///   - body: The job body using the API's field names.
    ///   - idempotencyKey: Generate once per intended job and save it. Reuse the
    ///     same key and exact body if a response is lost.
    public func createJob(_ body: [String: JSONValue], idempotencyKey: String) async throws -> [String: JSONValue] {
        try await request("POST", "/v1/jobs", body: body, idempotencyKey: idempotencyKey)
    }

    /// Reads a job. `GET /v1/jobs/{id}`.
    ///
    /// - Parameter wait: Seconds the API may hold the request until the job finishes.
    public func getJob(_ id: String, wait: Int = 0) async throws -> [String: JSONValue] {
        try await request("GET", "/v1/jobs/\(Self.encodeID(id))", query: ["wait": .integer(Int64(wait))])
    }

    /// Lists jobs, newest first. `GET /v1/jobs`.
    public func listJobs(limit: Int = 20, cursor: String? = nil) async throws -> [String: JSONValue] {
        try await request("GET", "/v1/jobs",
                          query: ["limit": .integer(Int64(limit)), "cursor": cursor.map(JSONValue.string) ?? .null])
    }

    /// Cancels a job that has not finished. `POST /v1/jobs/{id}/cancel`.
    public func cancelJob(_ id: String) async throws -> [String: JSONValue] {
        try await request("POST", "/v1/jobs/\(Self.encodeID(id))/cancel")
    }

    /// Retries a failed job. `POST /v1/jobs/{id}/retry`. This can spend credits.
    ///
    /// - Parameter maxCredits: An optional new credit ceiling.
    public func retryJob(_ id: String, idempotencyKey: String, maxCredits: Int? = nil) async throws -> [String: JSONValue] {
        let body: [String: JSONValue] = maxCredits.map { ["max_credits": .integer(Int64($0))] } ?? [:]
        return try await request("POST", "/v1/jobs/\(Self.encodeID(id))/retry", body: body, idempotencyKey: idempotencyKey)
    }

    /// Polls a job until it succeeds, fails or is cancelled.
    ///
    /// Inspect `status` before using `result_id`.
    ///
    /// - Parameters:
    ///   - timeout: Seconds to keep polling.
    ///   - pollInterval: Seconds between polls.
    /// - Throws: ``JobTimeoutError`` carrying the last job when the deadline passes.
    ///   The job keeps running.
    public func waitForJob(_ id: String, timeout: TimeInterval = 120, pollInterval: TimeInterval = 3) async throws -> [String: JSONValue] {
        let total = try Self.positive(timeout, "timeout")
        let interval = try Self.positive(pollInterval, "pollInterval")
        let path = try "/v1/jobs/" + Self.encodeID(id)
        let deadline = Self.now() + total
        var job: [String: JSONValue]?
        while true {
            var remaining = deadline - Self.now()
            if remaining <= 0 { throw JobTimeoutError(job: job) }
            let current = try await request("GET", path, timeout: min(self.timeout, remaining))
            job = current
            if let status = current["status"]?.stringValue, Self.terminalStatuses.contains(status) {
                return current
            }
            remaining = deadline - Self.now()
            if remaining <= 0 { throw JobTimeoutError(job: current) }
            try await Task.sleep(nanoseconds: UInt64(min(interval, remaining, 1e9) * 1_000_000_000))
        }
    }

    // MARK: Transcripts

    /// Reads a transcript with raw timing fields. `GET /v1/transcripts/{id}`.
    public func getTranscript(_ id: String) async throws -> [String: JSONValue] {
        try await request("GET", "/v1/transcripts/\(Self.encodeID(id))")
    }

    /// Exports a transcript as text. `GET /v1/transcripts/{id}/export`.
    ///
    /// - Parameter format: `json`, `txt`, `srt` or `vtt`. The body is returned unchanged.
    public func exportTranscript(_ id: String, format: String = "txt") async throws -> String {
        guard Self.exportFormats.contains(format) else {
            throw TranscriptDockError.invalidArgument("Choose json, txt, srt or vtt.")
        }
        return try await requestText("GET", "/v1/transcripts/\(Self.encodeID(id))/export", query: ["format": .string(format)])
    }

    /// Deletes a transcript. `DELETE /v1/transcripts/{id}`.
    public func deleteTranscript(_ id: String) async throws -> [String: JSONValue] {
        try await request("DELETE", "/v1/transcripts/\(Self.encodeID(id))")
    }

    // MARK: Batches and discovery

    /// Submits a batch of jobs. `POST /v1/batches`. This can spend credits.
    public func createBatch(_ body: [String: JSONValue], idempotencyKey: String) async throws -> [String: JSONValue] {
        try await request("POST", "/v1/batches", body: body, idempotencyKey: idempotencyKey)
    }

    /// Reads a batch. `GET /v1/batches/{id}`.
    public func getBatch(_ id: String) async throws -> [String: JSONValue] {
        try await request("GET", "/v1/batches/\(Self.encodeID(id))")
    }

    /// Starts listing the videos of a channel or profile. `POST /v1/video-discoveries`.
    public func createVideoDiscovery(_ body: [String: JSONValue], idempotencyKey: String) async throws -> [String: JSONValue] {
        try await request("POST", "/v1/video-discoveries", body: body, idempotencyKey: idempotencyKey)
    }

    /// Reads a video discovery. `GET /v1/video-discoveries/{id}`.
    public func getVideoDiscovery(_ id: String) async throws -> [String: JSONValue] {
        try await request("GET", "/v1/video-discoveries/\(Self.encodeID(id))")
    }

    /// Starts detecting the caption languages of a video. `POST /v1/language-discoveries`.
    public func createLanguageDiscovery(_ body: [String: JSONValue], idempotencyKey: String) async throws -> [String: JSONValue] {
        try await request("POST", "/v1/language-discoveries", body: body, idempotencyKey: idempotencyKey)
    }

    /// Reads a language discovery. `GET /v1/language-discoveries/{id}`.
    public func getLanguageDiscovery(_ id: String) async throws -> [String: JSONValue] {
        try await request("GET", "/v1/language-discoveries/\(Self.encodeID(id))")
    }

    // MARK: Uploads

    /// Requests an upload slot. `POST /v1/uploads`.
    ///
    /// Send the file bytes to the returned signed URL yourself, without your
    /// Transcript Dock API key, then call ``completeUpload(_:)``.
    public func createUpload(_ body: [String: JSONValue]) async throws -> [String: JSONValue] {
        try await request("POST", "/v1/uploads", body: body)
    }

    /// Marks an upload as transferred. `POST /v1/uploads/{id}/complete`.
    public func completeUpload(_ id: String) async throws -> [String: JSONValue] {
        try await request("POST", "/v1/uploads/\(Self.encodeID(id))/complete")
    }

    // MARK: Webhooks

    /// Lists webhook endpoints. `GET /v1/webhook-endpoints`.
    public func listWebhookEndpoints() async throws -> [String: JSONValue] {
        try await request("GET", "/v1/webhook-endpoints")
    }

    /// Creates a webhook endpoint. `POST /v1/webhook-endpoints`.
    ///
    /// The response includes the signing secret. Store it privately.
    public func createWebhookEndpoint(_ body: [String: JSONValue]) async throws -> [String: JSONValue] {
        try await request("POST", "/v1/webhook-endpoints", body: body)
    }

    /// Deletes a webhook endpoint. `DELETE /v1/webhook-endpoints/{id}`.
    public func deleteWebhookEndpoint(_ id: String) async throws -> [String: JSONValue] {
        try await request("DELETE", "/v1/webhook-endpoints/\(Self.encodeID(id))")
    }

    // MARK: Helpers

    private func apiError(status: Int, data: Data) -> ApiError {
        let envelope = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue ?? [:]
        let error = envelope["error"]?.objectValue ?? [:]
        let message = Self.plainText(error["message"]).flatMap { $0.isEmpty ? nil : $0 }
            ?? "Request failed with status \(status)."
        let requestId = Self.plainText(envelope["request_id"]).flatMap { $0.isEmpty ? nil : redact($0) }
        return ApiError(code: redact(Self.plainText(error["code"]) ?? "HTTP_ERROR"),
                        message: redact(message),
                        status: status,
                        retryable: error["retryable"]?.boolValue ?? (status == 429 || status >= 500),
                        requestId: requestId,
                        retryAfterSeconds: error["retry_after_seconds"]?.doubleValue)
    }

    private func redact(_ value: String) -> String {
        let withoutKey = value.replacingOccurrences(of: apiKey, with: "[REDACTED]")
        guard let pattern = try? NSRegularExpression(pattern: "td_live_[A-Za-z0-9_-]+|Bearer\\s+\\S+",
                                                     options: [.caseInsensitive]) else { return withoutKey }
        let range = NSRange(withoutKey.startIndex..., in: withoutKey)
        return pattern.stringByReplacingMatches(in: withoutKey, range: range, withTemplate: "[REDACTED]")
    }

    private static func plainText(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let text)?: return text
        case .integer(let number)?: return String(number)
        case .number(let number)?: return String(number)
        case .bool(let flag)?: return flag ? "true" : "false"
        default: return nil
        }
    }

    private static func positive(_ value: TimeInterval, _ name: String) throws -> TimeInterval {
        guard value.isFinite, value > 0 else {
            throw TranscriptDockError.invalidArgument("\(name) must be a finite positive number.")
        }
        return value
    }

    private static func encodeID(_ id: String) throws -> String {
        guard !id.isEmpty, id != ".", id != ".." else {
            throw TranscriptDockError.invalidArgument("Provide a nonempty ID.")
        }
        return percentEncode(id, spaceAsPlus: false)
    }

    private static func queryPairs(_ query: [String: JSONValue]) throws -> [String] {
        var pairs: [String] = []
        for name in query.keys.sorted() {
            let text: String
            switch query[name] ?? .null {
            case .null: continue
            case .string(let value): text = value
            case .integer(let value): text = String(value)
            case .number(let value):
                guard value.isFinite else {
                    throw TranscriptDockError.invalidArgument("Query numbers must be finite.")
                }
                text = value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
            case .bool(let value): text = value ? "true" : "false"
            case .array, .object:
                throw TranscriptDockError.invalidArgument("Query values must be strings, numbers or booleans.")
            }
            pairs.append(percentEncode(name, spaceAsPlus: true) + "=" + percentEncode(text, spaceAsPlus: true))
        }
        return pairs
    }

    /// Percent encodes everything except ASCII letters, digits and `-._~`.
    private static func percentEncode(_ value: String, spaceAsPlus: Bool) -> String {
        let hex = Array("0123456789ABCDEF")
        var output = ""
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."),
                 UInt8(ascii: "_"), UInt8(ascii: "~"):
                output.append(Character(Unicode.Scalar(byte)))
            case UInt8(ascii: " ") where spaceAsPlus:
                output.append("+")
            default:
                output.append("%")
                output.append(hex[Int(byte >> 4)])
                output.append(hex[Int(byte & 0x0F)])
            }
        }
        return output
    }

    private static func normalizedHost(_ host: String) -> String {
        var value = host.lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4, octets.allSatisfy({ part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCIIDigit)
                && (part == "0" || !part.hasPrefix("0")) && Int(part)! <= 255
        }) {
            return octets[0] == "127"
        }
        return isLoopbackIPv6(host)
    }

    /// True for `::1` in any valid spelling, such as `0:0:0:0:0:0:0:1`.
    private static func isLoopbackIPv6(_ host: String) -> Bool {
        let halves = host.components(separatedBy: "::")
        guard halves.count <= 2 else { return false }
        func groups(_ text: String) -> [UInt16]? {
            if text.isEmpty { return [] }
            var values: [UInt16] = []
            for part in text.split(separator: ":", omittingEmptySubsequences: false) {
                guard (1...4).contains(part.count), let value = UInt16(part, radix: 16) else { return nil }
                values.append(value)
            }
            return values
        }
        guard let head = groups(halves[0]) else { return false }
        var all = head
        if halves.count == 2 {
            guard let tail = groups(halves[1]), head.count + tail.count < 8 else { return false }
            all += Array(repeating: 0, count: 8 - head.count - tail.count) + tail
        }
        guard all.count == 8 else { return false }
        return all.dropLast().allSatisfy { $0 == 0 } && all.last == 1
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
