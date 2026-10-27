import Foundation
import XCTest
@testable import ApproovServiceWebView
@testable import ApproovServiceWebViewCore

@MainActor private final class EmptyCookieStore: ApproovWebViewCookieStoreAdapter {
    var reads = 0
    var cookies: [HTTPCookie] = []
    func allCookies() async -> [HTTPCookie] { reads += 1; return cookies }
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
    func testSameSiteCrossOriginIncludeSendsCookie() async throws {
        let store=EmptyCookieStore()
        store.cookies=[HTTPCookie(properties:[.name:"session",.value:"synthetic",.domain:".example.com",.path:"/",.secure:"TRUE"])!]
        let executor=try executor(store:store) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField:"Cookie"), "session=synthetic")
            return (Data(),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,
                headerFields:["Access-Control-Allow-Origin":"https://page.example.com", "Access-Control-Allow-Credentials":"true"])!,nil)
        }
        _ = try await executor.execute(request(credentials:"include"), context:context)
    }
    func testCrossSiteIncludeIsRejectedBeforeNetwork() async throws {
        let executor=try executor(store:EmptyCookieStore()) { _ in
            XCTFail("Cross-site credentialed request must not be sent")
            throw URLError(.cancelled)
        }
        let foreign=ApproovWebViewRequestContext(frameURL:URL(string:"https://other.test/")!,
            frameOrigin:"https://other.test",mainDocumentURL:URL(string:"https://other.test/")!,isMainFrame:true)
        do { _ = try await executor.execute(request(credentials:"include"),context:foreign); XCTFail("Expected rejection") }
        catch { XCTAssertTrue(error is ApproovWebViewBrowserPolicyError) }
    }

    func testSignerCannotChangeDestinationOutsideProtectedEndpoints() async throws {
        let config = ApproovWebViewConfiguration(approovConfig:"fixture", protectedEndpoints:[.init(host:"api.example.com", pathPrefix:"/")], allowedOrigins:["https://page.example.com"])
        let transport=ApproovWebViewRequestExecutor.TestTransport(bootstrap:{}, signer:{ request in
            var result=request
            result.url=URL(string:"https://other.test/")!
            result.setValue("synthetic",forHTTPHeaderField:"approov-token")
            return result
        },send:{ _ in XCTFail("Invalid signer destination must not be sent"); throw URLError(.cancelled) })
        let executor=try ApproovWebViewRequestExecutor(configuration:config,
            cookieBridge:ApproovWebViewCookieBridge(storeAdapter:EmptyCookieStore()), testTransport:transport)
        do { _ = try await executor.execute(request(),context:context); XCTFail("Expected destination rejection") }
        catch { XCTAssertTrue(error is ApproovWebViewBridgeError) }
    }

    func testRedirectPreflightUsesHeadersRemainingAfterSanitization() async throws {
        let config=ApproovWebViewConfiguration(approovConfig:"fixture",protectedEndpoints:[
            .init(host:"api.example.com",pathPrefix:"/"), .init(host:"other.example.com",pathPrefix:"/")], allowedOrigins:["https://page.example.com"])
        let transport=ApproovWebViewRequestExecutor.TestTransport(bootstrap:{},signer:{ request in
            var request=request; request.setValue("synthetic",forHTTPHeaderField:"approov-token"); return request
        },send:{ request in
            let headers=["Access-Control-Allow-Origin":"https://page.example.com", "Access-Control-Allow-Headers":"x-custom"]
            let response=HTTPURLResponse(url:request.url!,statusCode:request.url!.host == "api.example.com" && request.httpMethod != "OPTIONS" ? 302 : 200,httpVersion:nil,headerFields:headers)!
            if request.url!.host == "other.example.com" {
                XCTAssertNotEqual(request.httpMethod,"OPTIONS")
                XCTAssertNil(request.value(forHTTPHeaderField:"X-Custom"))
                return (Data(),response,nil)
            }
            if request.httpMethod == "OPTIONS" { return (Data(),response,nil) }
            var next=URLRequest(url:URL(string:"https://other.example.com/next")!)
            next.setValue("page value",forHTTPHeaderField:"X-Custom")
            return (Data(),response,next)
        })
        let executor=try ApproovWebViewRequestExecutor(configuration:config,cookieBridge:ApproovWebViewCookieBridge(storeAdapter:EmptyCookieStore()),testTransport:transport)
        _ = try await executor.execute(request(headers:["X-Custom":"page value"]),context:context)
    }

}
