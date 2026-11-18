import Foundation
import XCTest
import TranscriptDock

/// Offline tests. Every call here fails validation before a request is sent.
final class ValidationTests: XCTestCase {
    private let origin = "http://127.0.0.1:9"

    private func makeClient() throws -> TranscriptDock {
        try TranscriptDock(apiKey: "td_live_unit_only", baseURL: origin)
    }

    private func assertInvalid(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("Expected an invalid argument", file: file, line: line)
        } catch is TranscriptDockError {
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    func testAcceptsHTTPSAndLoopbackOrigins() throws {
        for url in ["https://www.transcriptdock.com", "https://example.com/", "HTTPS://example.com:8443",
                    "http://127.0.0.1:3000", "http://127.1.2.3", "http://localhost:8080", "http://[::1]:8000"] {
            XCTAssertNoThrow(try TranscriptDock(apiKey: "key", baseURL: url), url)
        }
    }

    func testRejectsUnsafeOrigins() async {
        for url in ["http://example.com", "http://127.0.0.1.example.com", "http://[::2]", "ftp://example.com",
                    "https://user:pass@example.com", "https://example.com/path", "https://example.com?x=1",
                    "https://example.com#top", "not a url", "https://"] {
            await assertInvalid { _ = try TranscriptDock(apiKey: "key", baseURL: url) }
        }
    }

    func testRejectsBadKeysAndTimeouts() async {
        for key in ["", "bad key", "bad\nkey", "caf\u{e9}"] {
            await assertInvalid { _ = try TranscriptDock(apiKey: key) }
        }
        for timeout in [0, -1, Double.nan, Double.infinity] {
            await assertInvalid { _ = try TranscriptDock(apiKey: "key", timeout: timeout) }
        }
    }

    func testRejectsUnsafeRequests() async throws {
        let client = try makeClient()
        await assertInvalid { _ = try await client.request("get", "/v1/jobs") }
        await assertInvalid { _ = try await client.request("TRACE", "/v1/jobs") }
        for path in ["/v2/jobs", "https://example.com/v1/jobs", "/v1/jobs?limit=1", "/v1/jobs#x",
                     "/v1/a\\b", "/v1/../secret", "/v1/%2e%2e/secret", "/v1/jobs/%2E/x"] {
            await assertInvalid { _ = try await client.request("GET", path) }
        }
        await assertInvalid { _ = try await client.request("GET", "/v1/jobs", query: ["x": ["nested": true]]) }
        await assertInvalid { _ = try await client.request("GET", "/v1/jobs", timeout: 0) }
        await assertInvalid { _ = try await client.request("POST", "/v1/webhook-endpoints", body: ["x": .number(.nan)]) }
    }

    func testRequiresValidIdempotencyKeys() async throws {
        let client = try makeClient()
        for path in ["/v1/jobs", "/v1/batches", "/v1/video-discoveries", "/v1/language-discoveries", "/v1/jobs/abc/retry"] {
            await assertInvalid { _ = try await client.request("POST", path, body: [:]) }
        }
        for key in ["short", String(repeating: "k", count: 129), "bad\nreplay", "caf\u{e9}-replay"] {
            await assertInvalid { _ = try await client.createJob([:], idempotencyKey: key) }
        }
    }

    func testRejectsBadIDsFormatsAndPolling() async throws {
        let client = try makeClient()
        for id in ["", ".", ".."] {
            await assertInvalid { _ = try await client.getJob(id) }
        }
        await assertInvalid { _ = try await client.exportTranscript("fixture", format: "pdf") }
        await assertInvalid { _ = try await client.waitForJob("fixture", timeout: .nan) }
        await assertInvalid { _ = try await client.waitForJob("fixture", pollInterval: 0) }
    }
}

final class JSONValueTests: XCTestCase {
    func testDecodesEveryKindAndKeepsIntegers() throws {
        let data = Data(#"{"n":null,"b":true,"i":9007199254740993,"d":1.5,"s":"Café","a":[1,"x"],"o":{"k":false}}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value["n"], .null)
        XCTAssertEqual(value["b"]?.boolValue, true)
        XCTAssertEqual(value["i"], .integer(9_007_199_254_740_993))
        XCTAssertEqual(value["d"]?.doubleValue, 1.5)
        XCTAssertEqual(value["s"]?.stringValue, "Café")
        XCTAssertEqual(value["a"]?[1]?.stringValue, "x")
        XCTAssertNil(value["a"]?[5])
        XCTAssertEqual(value["o"]?["k"], .bool(false))
        XCTAssertTrue(value["n"]?.isNull == true)
    }

    func testBooleansAreNotNumbers() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("[true, 1, 0]".utf8))
        XCTAssertEqual(value, [.bool(true), .integer(1), .integer(0)])
        XCTAssertNil(value[0]?.intValue)
        XCTAssertNil(value[1]?.boolValue)
    }

    func testLiteralsAndNumericEquality() {
        let body: [String: JSONValue] = ["source": ["url": "https://example.com"], "max_credits": 1, "ratio": 0.5,
                                         "tags": ["a", nil], "ai": false]
        XCTAssertEqual(body["source"]?["url"]?.stringValue, "https://example.com")
        XCTAssertEqual(body["max_credits"], .number(1.0))
        XCTAssertEqual(body["max_credits"]?.intValue, 1)
        XCTAssertEqual(body["tags"], .array([.string("a"), .null]))
        XCTAssertNotEqual(JSONValue.integer(1), JSONValue.bool(true))
        XCTAssertNil(JSONValue.number(1.5).intValue)
    }

    func testRoundTripsThroughJSON() throws {
        let original: JSONValue = ["id": "job", "count": 3, "ratio": 0.25, "ok": true, "none": nil, "list": [1, 2]]
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), original)
    }
}
