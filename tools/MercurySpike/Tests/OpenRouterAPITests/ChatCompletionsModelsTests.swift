import XCTest
@testable import OpenRouterAPI

final class ChatCompletionsModelsTests: XCTestCase {

    func testRequestEncodesMinimalShape() throws {
        let req = ChatCompletionRequest(
            model: "inception/mercury-coder",
            messages: [.init(role: "user", content: "hello")]
        )
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "inception/mercury-coder")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "hello")
    }

    func testRequestEncodesResponseFormat() throws {
        let req = ChatCompletionRequest(
            model: "x/y",
            messages: [.init(role: "user", content: "hi")],
            responseFormat: .jsonObject
        )
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rf = try XCTUnwrap(json["response_format"] as? [String: Any])
        XCTAssertEqual(rf["type"] as? String, "json_object")
    }

    func testResponseDecodesOpenRouterShape() throws {
        let json = Data("""
        {
          "id": "gen-123",
          "model": "inception/mercury-coder",
          "choices": [
            { "index": 0,
              "message": { "role": "assistant", "content": "hi back" },
              "finish_reason": "stop" }
          ],
          "usage": { "prompt_tokens": 12, "completion_tokens": 4, "total_tokens": 16 }
        }
        """.utf8)
        let resp = try JSONDecoder().decode(ChatCompletion.self, from: json)
        XCTAssertEqual(resp.id, "gen-123")
        XCTAssertEqual(resp.choices.first?.message.content, "hi back")
        XCTAssertEqual(resp.usage?.totalTokens, 16)
    }
}
