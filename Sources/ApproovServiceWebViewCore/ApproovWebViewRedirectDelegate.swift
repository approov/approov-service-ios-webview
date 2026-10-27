import Foundation

/// Stops URLSession from following redirects automatically while preserving
/// the request Foundation proposed for the next hop.
///
/// The request executor consumes that proposal after it has ingested the
/// redirect response's Set-Cookie headers. It can then rebuild the Cookie
/// header from the isolated jar before starting the next protected task.
package final class ApproovWebViewRedirectDelegate:
    NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable {
    private let lock = NSLock()
    private var proposedRequests: [Int: URLRequest] = [:]
    private struct Pending {
        var data = Data()
        var response: URLResponse?
        var limitExceeded = false
        let maximumBytes: Int
        let completion: (Result<(Data, URLResponse, URLRequest?), Error>) -> Void
    }
    private var pending: [Int: Pending] = [:]

    package func register(taskID: Int, maximumBytes: Int,
                          completion: @escaping (Result<(Data, URLResponse, URLRequest?), Error>) -> Void) {
        lock.lock()
        pending[taskID] = Pending(maximumBytes: max(0, maximumBytes), completion: completion)
        lock.unlock()
    }

    package func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                            didReceive response: URLResponse,
                            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        if var item = pending[dataTask.taskIdentifier] {
            item.response = response
            pending[dataTask.taskIdentifier] = item
        }
        lock.unlock()
        completionHandler(.allow)
    }

    package func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var shouldCancel = false
        if var item = pending[dataTask.taskIdentifier] {
            if data.count > item.maximumBytes - item.data.count {
                item.limitExceeded = true
                shouldCancel = true
            } else if !item.limitExceeded {
                item.data.append(data)
            }
            pending[dataTask.taskIdentifier] = item
        }
        lock.unlock()
        if shouldCancel { dataTask.cancel() }
    }

    package func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let item = pending.removeValue(forKey: task.taskIdentifier)
        let redirect = proposedRequests.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let item else { return }
        if item.limitExceeded { item.completion(.failure(URLError(.dataLengthExceedsMaximum))); return }
        if let error { item.completion(.failure(error)); return }
        guard let response = item.response ?? task.response else {
            item.completion(.failure(URLError(.badServerResponse))); return
        }
        item.completion(.success((item.data, response, redirect)))
    }

    package func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        proposedRequests[task.taskIdentifier] = request
        lock.unlock()

        // URLSession owns this callback and may perform synchronous work in
        // response. Never invoke external code while holding our state lock.
        completionHandler(nil)
    }

    package func takeProposedRequest(
        for taskIdentifier: Int
    ) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return proposedRequests.removeValue(forKey: taskIdentifier)
    }
}
