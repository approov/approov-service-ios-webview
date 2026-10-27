import Foundation
import XCTest
@testable import ApproovServiceWebView

final class ApproovWebViewBootstrapTests: XCTestCase {
    final class FakeService: @unchecked Sendable {
        var events: [String] = []
        var initialized = false
        var enabled = false
        var header = "Approov-Token"
        var failHook = false
        var service: ApproovWebViewBootstrap.Service {
            .init(isInitialized:{ self.initialized }, isEnabled:{ self.enabled }, tokenHeader:{ self.header },
                  initialize:{ _ in self.events.append("initialize"); self.initialized=true; self.enabled=true },
                  setHeader:{ header, _ in self.events.append("header"); self.header=header },
                  setDevKey:{ _ in self.events.append("key") })
        }
        func install(_ bootstrap: ApproovWebViewBootstrap, _ config: ApproovWebViewBootstrap.Configuration) throws {
            try bootstrap.install(config, service:service, configure:{
                self.events.append("hook")
                if self.failHook { self.failHook=false; throw URLError(.unknown) }
            }, installScope:{ self.events.append("scope") })
        }
    }
    private func config(_ value: String = "test", existing: Bool = false) -> ApproovWebViewBootstrap.Configuration {
        .init(config:value,header:"Approov-Token",prefix:"",developmentKey:"fixture",usesExisting:existing)
    }
    func testFirstAndSecondScopeKeepBootstrapOrderWithoutReset() throws {
        let bootstrap=ApproovWebViewBootstrap(), service=FakeService()
        try service.install(bootstrap,config()); try service.install(bootstrap,config())
        XCTAssertEqual(service.events,["initialize","header","key","hook","scope","scope"])
    }
    func testConflictingConfigurationIsRejectedBeforeMutation() throws {
        let bootstrap=ApproovWebViewBootstrap(), service=FakeService()
        try service.install(bootstrap,config())
        XCTAssertThrowsError(try service.install(bootstrap,config("different")))
        XCTAssertEqual(service.events,["initialize","header","key","hook","scope"])
    }
    func testExternallyOwnedServiceIsPreserved() throws {
        let bootstrap=ApproovWebViewBootstrap(), service=FakeService()
        service.initialized=true; service.enabled=true
        try service.install(bootstrap,config(existing:true))
        XCTAssertEqual(service.events,["scope"])
    }
    func testHookFailureRetriesWithoutReinitializing() throws {
        let bootstrap=ApproovWebViewBootstrap(), service=FakeService()
        service.failHook=true
        XCTAssertThrowsError(try service.install(bootstrap,config()))
        try service.install(bootstrap,config())
        XCTAssertEqual(service.events,["initialize","header","key","hook","hook","scope"])
    }
    func testConcurrentCallsInitializeOnceAndInstallEveryScope() {
        let bootstrap=ApproovWebViewBootstrap(), service=FakeService(), requested=config()
        let queue=DispatchQueue(label:"bootstrap-test",attributes:.concurrent)
        let group=DispatchGroup()
        for _ in 0..<20 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do { try service.install(bootstrap, requested) }
                catch { XCTFail("Concurrent bootstrap failed: \(error)") }
            }
        }
        XCTAssertEqual(group.wait(timeout:.now()+5),.success)
        XCTAssertEqual(service.events.filter { $0 == "initialize" }.count,1)
        XCTAssertEqual(service.events.filter { $0 == "hook" }.count,1)
        XCTAssertEqual(service.events.filter { $0 == "scope" }.count,20)
    }
}
