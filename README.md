# Transcript Dock for Swift

An async client for the [Transcript Dock API](https://www.transcriptdock.com/docs).
Swift 5.9 or newer on macOS 12, iOS 15, tvOS 15, watchOS 8, visionOS 1 and Linux.
No dependencies.

Add the package with Swift Package Manager:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/TranscriptDock/transcriptdock-swift.git", from: "0.1.0"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "TranscriptDock", package: "transcriptdock-swift"),
    ]),
]
```

In Xcode, choose File, Add Package Dependencies, and enter
`https://github.com/TranscriptDock/transcriptdock-swift.git`.

## Submit and read a transcript

Read `TRANSCRIPTDOCK_API_KEY` from your environment or a secure store. Keep it out
of source control and out of apps you ship to other people.

```swift
import Foundation
import TranscriptDock

let client = try TranscriptDock(apiKey: ProcessInfo.processInfo.environment["TRANSCRIPTDOCK_API_KEY"] ?? "")
print(try await client.capabilities())

// Generate once per intended operation. Save this key and the returned job ID.
// Reuse the same key and exact body if a submission's response is lost.
let submissionKey = UUID().uuidString
var job = try await client.createJob(
    ["source": ["url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"],
     "mode": "captions_only", "max_credits": 1],
    idempotencyKey: submissionKey
)
do {
    job = try await client.waitForJob(job["id"]?.stringValue ?? "", timeout: 120)
    if job["status"]?.stringValue == "succeeded", let resultId = job["result_id"]?.stringValue {
        print(try await client.getTranscript(resultId))
        print(try await client.exportTranscript(resultId, format: "srt"))
    } else {
        print(job["status"] ?? .null, job["error"] ?? .null)
    }
} catch let error as JobTimeoutError {
    print("Still running", error.job ?? [:])
}
```

Creating a job can spend credits. This example caps the request at one credit
and requests captions only. It does not enable AI fallback. Check capabilities
and your plan before selecting other modes. Never blindly resubmit after a
network failure: check the job ID or replay the same body with the same
idempotency key. The client does not retry requests automatically.

## Supported operations

All methods are `async throws`. Responses are `[String: JSONValue]` dictionaries
retaining the API's fields, so fields added later are never lost. Read values
with subscripts such as `job["status"]?.stringValue`. Request bodies use the
API's exact field names with literal syntax; the server validates supported
options. See the [OpenAPI definition](https://www.transcriptdock.com/docs/openapi.yaml)
for bodies.

* `capabilities()`, `usage()`
* `createJob(_:idempotencyKey:)`, `getJob(_:wait:)`, `listJobs(limit:cursor:)`,
  `cancelJob(_:)`, `retryJob(_:idempotencyKey:maxCredits:)`,
  `waitForJob(_:timeout:pollInterval:)`
* `getTranscript(_:)`, `exportTranscript(_:format:)`, `deleteTranscript(_:)`
* `createBatch(_:idempotencyKey:)`, `getBatch(_:)`
* `createVideoDiscovery(_:idempotencyKey:)`, `getVideoDiscovery(_:)`
* `createLanguageDiscovery(_:idempotencyKey:)`, `getLanguageDiscovery(_:)`
* `createUpload(_:)`, `completeUpload(_:)`
* `listWebhookEndpoints()`, `createWebhookEndpoint(_:)`, `deleteWebhookEndpoint(_:)`

`exportTranscript` returns a `String` for `json`, `txt`, `srt` and `vtt`,
preserving the export response. `getTranscript` preserves raw timing fields
without converting units. `waitForJob` returns succeeded, failed or cancelled
jobs; inspect `status` before using `result_id`. Timeout leaves the job running
and throws `JobTimeoutError`, whose `job` holds the last observed response (or
`nil` if no poll was possible).

`createUpload` creates an upload slot only. Transfer bytes to the returned signed
upload URL separately following the API instructions, without sending your
Transcript Dock API key to the storage host. Then call `completeUpload`.
Webhook secrets are sensitive; store them privately and verify callback
signatures in your receiver according to the API documentation.

`request(_:_:body:query:idempotencyKey:timeout:)` and `requestText(...)` support
public endpoints added later. They take uppercase methods and `/v1/` paths, and
reject absolute URLs, traversal paths and redirects. Custom API origins must use
HTTPS, except loopback HTTP for local development. The default origin is
`https://www.transcriptdock.com`; the apex domain redirects.

The client is `Sendable`, so one instance can be shared across tasks.
Cancelling a task cancels its request with `CancellationError`.

## Errors

```swift
do {
    let jobs = try await client.listJobs(limit: 10)
    print(jobs)
} catch let error as ApiError {
    print(error.code, error.status ?? 0, error.requestId ?? "")
    // retryable and retryAfterSeconds describe the API response.
    // Decide whether to retry using the operation's idempotency rules.
} catch TranscriptDockError.invalidArgument(let message) {
    print(message) // Nothing was sent.
}
```

Transport failures and timeouts use `NETWORK_ERROR`; malformed responses use
`INVALID_RESPONSE`. A redirect is an `ApiError` with its 3xx status. API messages
redact bearer tokens. Error responses do not expose raw HTML pages.

## Development and release

```sh
swift build
swift test
python3 .ci/check.py
```

`.ci/check.py` starts a loopback fixture server and runs the `ClientCheck`
contract program with `swift run ClientCheck`. Tests spend no credits and never
contact production. `ClientCheck` is not part of the library product.

Swift Package Manager installs straight from git tags, so a release is an
annotated semver tag such as `0.1.0` on a commit whose checks passed. There is
no registry upload. The package is listed on the
[Swift Package Index](https://swiftpackageindex.com), which builds the DocC
documentation configured in `.spi.yml`. CocoaPods trunk is read only, so there is
no podspec. Never put API credentials in this directory.
