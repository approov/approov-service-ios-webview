import Foundation

/// Stops URLSession from following redirects automatically while preserving
/// the request Foundation proposed for the next hop.
///
/// The request executor consumes that proposal after it has ingested the
/// redirect response's Set-Cookie headers. It can then rebuild the Cookie
/// header from the isolated jar before starting the next protected task.
package final class ApproovWebViewRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable {
    private let lock = NSLock()
    private var proposedRequests: [Int: URLRequest] = [:]

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
