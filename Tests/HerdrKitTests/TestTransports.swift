import Foundation
import XCTest
@testable import HerdrKit

/// The shared request/reply stand-in for `HerdrTransport`: keeps every request line and
/// answers each `roundTrip` from a closure given the request's method and params.
/// `stream` finishes at once — a test that needs a live stream, a scripted call order,
/// or held replies keeps its own transport.
final class RecordingTransport: HerdrTransport, @unchecked Sendable {
    typealias Answer = (_ method: String, _ params: [String: Any]) throws -> String

    /// The reply a stub gives for a method it has nothing specific to say about.
    static let emptyResult = #"{"id":"x","result":{}}"#

    /// The daemon's plain acknowledgement.
    static let okResult = #"{"id":"x","result":{"type":"ok"}}"#

    private let lock = NSLock()
    private var lines: [String] = []
    private let answer: Answer

    init(answer: @escaping Answer) {
        self.answer = answer
    }

    /// Answers every request with the same line.
    convenience init(reply: String = RecordingTransport.emptyResult) {
        self.init { _, _ in reply }
    }

    /// Answers by exact method name, and with `otherwise` for any other method.
    convenience init(replies: [String: String], otherwise: String = RecordingTransport.emptyResult) {
        self.init { method, _ in replies[method] ?? otherwise }
    }

    /// A daemon error envelope, the line herdr answers a refused request with.
    static func errorReply(code: String, message: String) -> String {
        #"{"id":"x","error":{"code":"\#(code)","message":"\#(message)"}}"#
    }

    /// A transport that refuses every request with the same daemon error.
    static func error(code: String, message: String) -> RecordingTransport {
        RecordingTransport(reply: errorReply(code: code, message: message))
    }

    /// Every request line sent, oldest first.
    var requestLines: [String] { lock.withLock { lines } }

    /// The last request line sent, or "" before the first request.
    var lastRequest: String { requestLines.last ?? "" }

    /// Every request parsed into its method and params, oldest first.
    var requests: [(method: String, params: [String: Any])] {
        requestLines.map(Self.parse)
    }

    /// The last request's method and params, parsed rather than substring-matched so a
    /// stray key or a wrong value type cannot hide.
    func last() throws -> (method: String, params: [String: Any]) {
        let line = try XCTUnwrap(requestLines.last)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        return (try XCTUnwrap(object["method"] as? String),
                try XCTUnwrap(object["params"] as? [String: Any]))
    }

    func roundTrip(_ requestLine: String) async throws -> String {
        lock.withLock { lines.append(requestLine) }
        let (method, params) = Self.parse(requestLine)
        return try answer(method, params)
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    private static func parse(_ line: String) -> (method: String, params: [String: Any]) {
        let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        return (object?["method"] as? String ?? "", object?["params"] as? [String: Any] ?? [:])
    }
}
