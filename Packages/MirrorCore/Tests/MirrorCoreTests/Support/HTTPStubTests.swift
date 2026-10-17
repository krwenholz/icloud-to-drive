import Foundation
import Testing

struct HTTPStubTests {
  @Test func servesQueuedResponsesAndRecordsBodies() async throws {
    let stub = HTTPStub()
    stub.enqueue(.json(201, #"{"ok":true}"#))
    var request = URLRequest(url: URL(string: "https://example.test/upload?x=1")!)
    request.httpMethod = "POST"
    request.httpBody = Data("hello".utf8)

    let (data, response) = try await stub.session.data(for: request)

    #expect((response as? HTTPURLResponse)?.statusCode == 201)
    #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)
    #expect(stub.requests.map(\.body) == [Data("hello".utf8)])
    #expect(stub.requests.first?.query == ["x": "1"])
    #expect(stub.requests.first?.header("X-HTTP-Stub-ID") == nil)
  }
}
