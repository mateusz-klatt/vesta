import Foundation
import XCTest
@testable import Vesta

final class EventStreamTests: XCTestCase {
    func testHTTP401YieldsUnauthorizedAndTerminates() async {
        await assertDenial(from: UnauthorizedEventURLProtocol.self, expected: .unauthorized)
    }

    func testHTTP403YieldsForbiddenAndTerminates() async {
        await assertDenial(from: ForbiddenEventURLProtocol.self, expected: .forbidden)
    }

    private func assertDenial(from urlProtocol: URLProtocol.Type, expected: EventStream.Event) async {
        let configuration = HTTPSession.configuration
        configuration.protocolClasses = [urlProtocol]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let terminated = expectation(description: "The event stream terminates")
        let read = Task {
            var events: [EventStream.Event] = []
            for await event in EventStream.changes(session: session) { events.append(event) }
            terminated.fulfill()
            return events
        }
        await fulfillment(of: [terminated], timeout: 5)
        read.cancel()
        let events = await read.value
        XCTAssertEqual(events, [expected])
    }
}

private class EventDenialURLProtocol: URLProtocol, @unchecked Sendable {
    class var status: Int { 500 }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: type(of: self).status,
                                             httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class UnauthorizedEventURLProtocol: EventDenialURLProtocol, @unchecked Sendable {
    override class var status: Int { 401 }
}

private final class ForbiddenEventURLProtocol: EventDenialURLProtocol, @unchecked Sendable {
    override class var status: Int { 403 }
}
