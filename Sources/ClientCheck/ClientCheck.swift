// Contract checks shared by every Transcript Dock SDK.
// Run through `python3 .ci/check.py`, which starts the loopback fixture and sets
// TRANSCRIPTDOCK_TEST_BASE_URL. Never point this at production.
import Foundation
import TranscriptDock

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func check(_ value: Bool, _ message: String) throws {
    if !value { throw CheckFailure(description: message) }
}

func raises<E: Error>(_ type: E.Type, _ body: () async throws -> Void) async throws -> E {
    do {
        try await body()
    } catch let error as E {
        return error
    }
    throw CheckFailure(description: "Expected \(type)")
}

@main
struct ClientCheck {
    static func main() async throws {
        guard let base = ProcessInfo.processInfo.environment["TRANSCRIPTDOCK_TEST_BASE_URL"] else {
            throw CheckFailure(description: "Set TRANSCRIPTDOCK_TEST_BASE_URL to the loopback fixture.")
        }
        let client = try TranscriptDock(apiKey: "td_live_fixture_only", baseURL: base)
        let body: [String: JSONValue] = ["source": ["url": "https://example.com/video"], "mode": "captions_only", "max_credits": 1]
        for _ in 0..<2 {
            let out = try await client.createJob(body, idempotencyKey: "fixture-replay-01")
            try check(out["future_field"]?.intValue == 42, "future response field lost")
            try check(out["request"]?["body"] == .object(body), "request body changed")
            try check(out["request"]?["idempotency_key"]?.stringValue == "fixture-replay-01" && out["request"]?["authorized"]?.boolValue == true, "headers changed")
        }
        var out = try await client.request("GET", "/v1/jobs", query: ["cursor": "a/b?c&d", "limit": 7])
        try check(out["request"]?["query"]?["cursor"] == .array([.string("a/b?c&d")]), "cursor encoding changed")
        out = try await client.getJob("id/other?x")
        try check(out["request"]?["path"]?.stringValue?.hasSuffix("id%2Fother%3Fx") == true, "ID path encoding changed")
        out = try await client.getTranscript("fixture")
        try check(out["words"]?[0]?["start_ms"]?.intValue == 123, "timing unit changed")
        let export = try await client.exportTranscript("fixture", format: "srt")
        try check(export.contains("fixture"), "export lost")
        for status in ["succeeded", "failed", "cancelled"] {
            let job = try await client.waitForJob(status)
            try check(job["status"]?.stringValue == status, "terminal status lost")
        }
        let timeout = try await raises(JobTimeoutError.self) {
            _ = try await client.waitForJob("processing", timeout: 0.15, pollInterval: 1)
        }
        try check(timeout.job?["status"]?.stringValue == "processing", "timeout lost last job")
        var error = try await raises(ApiError.self) { _ = try await client.request("GET", "/v1/rate-limit") }
        try check(error.status == 429 && error.retryable && error.retryAfterSeconds == 4 && error.requestId == "fixture-request", "API error fields lost")
        try check(!error.message.contains("td_live_fixture_only"), "key in error")
        error = try await raises(ApiError.self) { _ = try await client.request("GET", "/v1/redirect") }
        try check(error.status == 302, "redirect followed")
        for path in ["gateway", "error-shape", "malformed", "array"] {
            _ = try await raises(ApiError.self) { _ = try await client.request("GET", "/v1/\(path)") }
        }
        for path in ["/v1/batches", "/v1/video-discoveries", "/v1/language-discoveries"] {
            _ = try await raises(TranscriptDockError.self) { _ = try await client.request("POST", path, body: [:]) }
            out = try await client.request("POST", path, body: ["fixture": true], idempotencyKey: "fixture-generic-01")
            try check(out["request"]?["method"]?.stringValue == "POST", "generic submission failed")
        }
        out = try await client.request("DELETE", "/v1/transcripts/fixture")
        try check(out["request"]?["method"]?.stringValue == "DELETE", "delete dispatch failed")
        for url in ["http://example.com", "https://user:pass@example.com", "https://example.com/path", "https://example.com?x=1"] {
            _ = try await raises(TranscriptDockError.self) { _ = try TranscriptDock(apiKey: "fixture-key", baseURL: url) }
        }
        _ = try await raises(TranscriptDockError.self) { _ = try TranscriptDock(apiKey: "bad\nkey") }
        _ = try await raises(TranscriptDockError.self) { _ = try await client.createJob([:], idempotencyKey: "bad\nreplay") }
        _ = try await raises(TranscriptDockError.self) { _ = try await client.request("GET", "/v1/../secret") }
        _ = try await raises(TranscriptDockError.self) { _ = try await client.waitForJob("fixture", timeout: .nan) }
        error = try await raises(ApiError.self) { _ = try await client.request("GET", "/v1/slow", timeout: 0.03) }
        try check(error.code == "NETWORK_ERROR", "transport timeout not handled")
        _ = try await raises(TranscriptDockError.self) { _ = try await client.request("post", "/v1/jobs", body: [:]) }
        _ = try await raises(TranscriptDockError.self) { _ = try await client.request("GET", "/v1/%2e%2e/secret") }
        let rejections: [(String, Int, String)] = [("budget", 402, "BUDGET_EXCEEDED"), ("conflict", 409, "IDEMPOTENCY_CONFLICT"), ("jobs/not-owned", 404, "NOT_FOUND")]
        for (path, status, code) in rejections {
            error = try await raises(ApiError.self) { _ = try await client.request("GET", "/v1/\(path)") }
            try check(error.status == status && error.code == code && !error.retryable, "budget, replay conflict or inaccessible job error lost")
        }
        print("Swift client checks passed")
    }
}
