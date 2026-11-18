import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends one request at a time per task through a session delegate.
///
/// Delegate driven data tasks behave the same on Apple platforms and Linux:
/// the redirect callback is honoured, so a 3xx response is returned as is and
/// the bearer credential never leaves the configured origin. A timer enforces
/// the per request deadline precisely, because some platforms round
/// `URLRequest.timeoutInterval` to whole seconds.
final class Transport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        let task: URLSessionTask
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
        var data = Data()
    }

    /// Tracks a task identifier so cancellation can find it, even before it starts.
    private final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var id: Int?
        private var cancelled = false

        func start(_ id: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            self.id = id
            return !cancelled
        }

        func cancel() -> Int? {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            return id
        }
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession?

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Lets the session release this delegate once running tasks finish.
    func invalidate() {
        session?.finishTasksAndInvalidate()
    }

    func send(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        guard let session else { throw URLError(.cancelled) }
        let ticket = Ticket()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let id = task.taskIdentifier
                self.lock.lock()
                self.pending[id] = Pending(task: task, continuation: continuation)
                self.lock.unlock()
                guard ticket.start(id) else {
                    self.finish(id) { _ in .failure(CancellationError()) }
                    return
                }
                task.resume()
                // Clamp so very long timeouts cannot overflow the dispatch clock.
                let delay = min(timeout, 31_536_000)
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.finish(id) { _ in .failure(URLError(.timedOut)) }
                }
            }
        } onCancel: {
            if let id = ticket.cancel() {
                self.finish(id) { _ in .failure(CancellationError()) }
            }
        }
    }

    /// Resumes the waiting caller once; later events for the same task are ignored.
    private func finish(_ id: Int, _ result: (Data) -> Result<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        let entry = pending.removeValue(forKey: id)
        lock.unlock()
        guard let entry else { return }
        let outcome = result(entry.data)
        if case .failure = outcome {
            entry.task.cancel()
        }
        entry.continuation.resume(with: outcome)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never follow redirects, including for GET requests.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        pending[dataTask.taskIdentifier]?.data.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let response = task.response as? HTTPURLResponse
        finish(task.taskIdentifier) { data in
            if let error { return .failure(error) }
            guard let response else { return .failure(URLError(.badServerResponse)) }
            return .success((data, response))
        }
    }
}
