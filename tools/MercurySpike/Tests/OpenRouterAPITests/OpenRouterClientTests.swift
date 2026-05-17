import XCTest
@testable import OpenRouterAPI

final class OpenRouterClientTests: XCTestCase {

    override class func setUp() {
        URLProtocol.registerClass(MockURLProtocol.self)
    }
    override class func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
    }
    override func setUp() {
        MockURLProtocol.requestHandler = nil
    }

    func testClientPostsToCorrectEndpointWithAuth() async throws {
        let captured = ExpectationBox<URLRequest>()
        MockURLProtocol.requestHandler = { req in
            captured.value = req
            let body = Data("""
            {"id":"x","model":"m","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}
            """.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = OpenRouterClient(apiKey: "sk-test", session: Self.mockSession())
        _ = try await client.chatCompletion(request: ChatCompletionRequest(
            model: "inception/mercury-2",
            messages: [.init(role: "user", content: "hi")]
        ))
        let req = try XCTUnwrap(captured.value)
        XCTAssertEqual(req.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Title"), "AgentNotch")
    }

    func testClientThrowsOnNon2xx() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!,
             Data("rate limited".utf8))
        }
        let client = OpenRouterClient(apiKey: "sk", session: Self.mockSession())
        do {
            _ = try await client.chatCompletion(request: ChatCompletionRequest(
                model: "m", messages: [.init(role: "user", content: "x")]))
            XCTFail("expected throw")
        } catch let error as OpenRouterError {
            guard case .httpStatus(let code, _) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(code, 429)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // helpers
    static func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - Test infra (kept inside the test target)

final class ExpectationBox<T> {
    var value: T?
}

final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
