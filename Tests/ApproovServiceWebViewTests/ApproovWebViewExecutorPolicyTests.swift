import Foundation
import XCTest
@testable import ApproovServiceWebView
@testable import ApproovServiceWebViewCore

@MainActor private final class EmptyCookieStore: ApproovWebViewCookieStoreAdapter {
    var reads = 0
    func allCookies() async -> [HTTPCookie] { reads += 1; return [] }
    func setCookie(_ cookie: HTTPCookie) async {}
    func deleteCookie(_ cookie: HTTPCookie) async {}
}

@MainActor final class ApproovWebViewExecutorPolicyTests: XCTestCase {
    private func request(headers: [String: String] = [:], credentials: String = "omit", redirect: String = "follow") throws -> ApproovWebViewProxyRequest {
        let payload: [String: Any] = ["url":"https://api.example.com/data", "method":"GET", "headers":headers,
            "responseHandling":"response", "requestSource":"fetch", "credentials":credentials, "redirect":redirect]
        return try JSONDecoder().decode(ApproovWebViewProxyRequest.self, from: JSONSerialization.data(withJSONObject: payload))
    }
    private var context: ApproovWebViewRequestContext {
        ApproovWebViewRequestContext(frameURL: URL(string:"https://page.example.com/path?secret=1")!,
            frameOrigin:"https://page.example.com", mainDocumentURL:URL(string:"https://page.example.com/")!, isMainFrame:true)
    }
    private func executor(store: EmptyCookieStore, send: @escaping (URLRequest) async throws -> (Data,URLResponse,URLRequest?)) throws -> ApproovWebViewRequestExecutor {
        let config = ApproovWebViewConfiguration(approovConfig:"fixture", protectedEndpoints:[.init(host:"api.example.com", pathPrefix:"/")], allowedOrigins:["https://page.example.com"])
        return try ApproovWebViewRequestExecutor(configuration:config, cookieBridge: ApproovWebViewCookieBridge(storeAdapter:store), testTransport:.init(bootstrap:{}, signer:{ request in
            var request=request; request.setValue("synthetic",forHTTPHeaderField:"approov-token"); return request
        }, send:send))
    }
    func testCORSPreflightReferrerAndOmittedCredentials() async throws {
        let store=EmptyCookieStore()
        let executor=try executor(store:store) { request in
            XCTAssertNil(request.value(forHTTPHeaderField:"Cookie"))
            let headers: [String:String] = ["Access-Control-Allow-Origin":"https://page.example.com", "Access-Control-Allow-Headers":"x-custom"]
            if request.httpMethod == "OPTIONS" {
                XCTAssertEqual(request.value(forHTTPHeaderField:"Access-Control-Request-Headers"),"x-custom")
            } else {
                XCTAssertEqual(request.value(forHTTPHeaderField:"Referer"),"https://page.example.com/")
            }
            return (Data(), HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:headers)!, nil)
        }
        _ = try await executor.execute(request(headers:["X-Custom":"value"]), context:context)
        XCTAssertEqual(store.reads,0)
    }
    func testRejectsCORSResponseWithoutPermission() async throws {
        let executor=try executor(store:EmptyCookieStore()) { request in
            (Data("secret".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:[:])!,nil)
        }
        do { _ = try await executor.execute(request(),context:context); XCTFail("Expected CORS rejection") }
        catch { XCTAssertTrue(error is ApproovWebViewBrowserPolicyError) }
    }
    func testRejectsRedirectWhenRedirectModeIsError() async throws {
        let executor=try executor(store:EmptyCookieStore()) { request in
            let response=HTTPURLResponse(url:request.url!,statusCode:302,httpVersion:nil,headerFields:["Access-Control-Allow-Origin":"https://page.example.com"])!
            return (Data(),response,URLRequest(url:URL(string:"https://api.example.com/next")!))
        }
        do { _ = try await executor.execute(request(redirect:"error"),context:context); XCTFail("Expected redirect rejection") }
        catch { XCTAssertTrue(error is URLError) }
    }
}
