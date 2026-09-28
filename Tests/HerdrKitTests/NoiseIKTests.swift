import Crypto
import Foundation
import XCTest
@testable import HerdrKit

/// A cacophony-format Noise test vector.
struct NoiseVector: Decodable {
    struct Message: Decodable {
        let payload: String
        let ciphertext: String
    }

    let protocolName: String
    let initPrologue: String
    let initStatic: String
    let initEphemeral: String
    let initRemoteStatic: String
    let respStatic: String
    let respEphemeral: String
    let handshakeHash: String?
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case messages
        case protocolName = "protocol_name"
        case initPrologue = "init_prologue"
        case initStatic = "init_static"
        case initEphemeral = "init_ephemeral"
        case initRemoteStatic = "init_remote_static"
        case respStatic = "resp_static"
        case respEphemeral = "resp_ephemeral"
        case handshakeHash = "handshake_hash"
    }

    static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    static func published() throws -> [(source: String, vector: NoiseVector)] {
        struct File: Decodable {
            struct Entry: Decodable {
                let source: String
                let vector: NoiseVector
            }
            let vectors: [Entry]
        }
        return try JSONDecoder().decode(File.self, from: fixture("noise_ik_published_vectors.json"))
            .vectors.map { ($0.source, $0.vector) }
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// The IK responder, written from the spec for tests only: it plays the host so the
/// initiator can be exercised end to end.
struct TestIKResponder {
    private var state = NoiseIK.SymmetricState(protocolName: NoiseIK.protocolName)
    let staticKey: Curve25519.KeyAgreement.PrivateKey
    let ephemeralKey: Curve25519.KeyAgreement.PrivateKey
    private(set) var remoteStatic = Data()
    private var remoteEphemeral = Data()

    init(prologue: Data, staticKey: Curve25519.KeyAgreement.PrivateKey,
         ephemeral: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()) {
        self.staticKey = staticKey
        self.ephemeralKey = ephemeral
        state.mixHash(prologue)
        state.mixHash(staticKey.publicKey.rawRepresentation)
    }

    mutating func readMessage1(_ message: Data) throws -> Data {
        let bytes = [UInt8](message)
        guard bytes.count >= 80 else { throw NoiseIK.Failure.truncated }
        remoteEphemeral = Data(bytes[0..<32])
        state.mixHash(remoteEphemeral)
        state.mixKey(try NoiseIK.dh(staticKey, remoteEphemeral))
        remoteStatic = try state.decryptAndHash(Data(bytes[32..<80]))
        state.mixKey(try NoiseIK.dh(staticKey, remoteStatic))
        return try state.decryptAndHash(Data(bytes[80...]))
    }

    /// Returns message 2 and the responder's (send, receive) ciphers.
    mutating func writeMessage2(_ payload: Data) throws -> (Data, TestResponderTransport) {
        let e = ephemeralKey.publicKey.rawRepresentation
        state.mixHash(e)
        state.mixKey(try NoiseIK.dh(ephemeralKey, remoteEphemeral))
        state.mixKey(try NoiseIK.dh(ephemeralKey, remoteStatic))
        let message = e + (try state.encryptAndHash(payload))
        let (initiatorToResponder, responderToInitiator) = state.split()
        return (message, TestResponderTransport(send: responderToInitiator, receive: initiatorToResponder))
    }
}

struct TestResponderTransport {
    var send: NoiseIK.CipherState
    var receive: NoiseIK.CipherState

    mutating func encrypt(_ plaintext: Data) throws -> Data {
        try send.encrypt(ad: Data(), plaintext: plaintext)
    }

    mutating func decrypt(_ message: Data) throws -> Data {
        try receive.decrypt(ad: Data(), ciphertext: message)
    }
}

final class NoiseIKTests: XCTestCase {
    /// Replays a vector through the initiator: every initiator message must be byte-identical
    /// and every responder message must decrypt to the recorded payload.
    func replay(_ vector: NoiseVector, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(vector.protocolName, NoiseIK.protocolName, file: file, line: line)
        var initiator = try NoiseIK.Initiator(
            prologue: Data(hex: vector.initPrologue),
            staticKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: vector.initStatic)),
            remoteStatic: Data(hex: vector.initRemoteStatic),
            ephemeral: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: vector.initEphemeral)))
        let messages = vector.messages
        XCTAssertGreaterThanOrEqual(messages.count, 3, "a vector must reach transport messages", file: file, line: line)

        let message1 = try initiator.writeMessage1(payload: Data(hex: messages[0].payload))
        XCTAssertEqual(message1.hex, messages[0].ciphertext, "message 1", file: file, line: line)

        var (payload, transport) = try initiator.readMessage2(Data(hex: messages[1].ciphertext))
        XCTAssertEqual(payload.hex, messages[1].payload, "message 2 payload", file: file, line: line)
        if let hash = vector.handshakeHash {
            XCTAssertEqual(transport.handshakeHash.hex, hash, "handshake hash", file: file, line: line)
        }

        for (index, message) in messages.enumerated().dropFirst(2) {
            if index % 2 == 0 {
                let sent = try transport.encrypt(Data(hex: message.payload))
                XCTAssertEqual(sent.hex, message.ciphertext, "transport message \(index)", file: file, line: line)
            } else {
                let received = try transport.decrypt(Data(hex: message.ciphertext))
                XCTAssertEqual(received.hex, message.payload, "transport message \(index)", file: file, line: line)
            }
        }
    }

    func testPublishedVectors() throws {
        let vectors = try NoiseVector.published()
        XCTAssertEqual(vectors.count, 2)
        for (source, vector) in vectors {
            XCTAssertNoThrow(try replay(vector), source)
        }
    }

    /// The transcript `snow` produced for the herdr daemon's responder: the Swift
    /// initiator and the Rust responder must agree byte for byte.
    func testSnowGeneratedHerdrFixture() throws {
        let vector = try JSONDecoder().decode(NoiseVector.self, from: NoiseVector.fixture("noise_ik_vector.json"))
        XCTAssertTrue(String(decoding: Data(hex: vector.initPrologue), as: UTF8.self).hasPrefix("herdr-guest/1:"))
        try replay(vector)
    }

    private func handshake(
        prologue: Data = Data("p".utf8),
        responderPrologue: Data? = nil,
        responderStatic: Curve25519.KeyAgreement.PrivateKey = .init(),
        initiatorBelievesStatic: Data? = nil
    ) throws -> (NoiseIK.Transport, TestResponderTransport) {
        var initiator = try NoiseIK.Initiator(
            prologue: prologue, staticKey: .init(),
            remoteStatic: initiatorBelievesStatic ?? responderStatic.publicKey.rawRepresentation)
        var responder = TestIKResponder(prologue: responderPrologue ?? prologue, staticKey: responderStatic)
        _ = try responder.readMessage1(try initiator.writeMessage1(payload: Data("hello".utf8)))
        let (message2, responderTransport) = try responder.writeMessage2(Data("ok".utf8))
        let (_, transport) = try initiator.readMessage2(message2)
        return (transport, responderTransport)
    }

    /// A guest that pinned the wrong host key must not complete a handshake with
    /// whoever answers: message 1 is sealed to the pinned key, so an impostor cannot
    /// even read it.
    func testImpostorHostCannotReadMessage1() throws {
        let pinned = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        XCTAssertThrowsError(try handshake(initiatorBelievesStatic: pinned)) { error in
            XCTAssertEqual(error as? NoiseIK.Failure, .decryptFailed)
        }
    }

    /// The prologue carries the host id, so a session cannot be replayed against
    /// another host's relay slot.
    func testPrologueMismatchFailsHandshake() throws {
        XCTAssertThrowsError(try handshake(prologue: Data("herdr-guest/1:A".utf8),
                                           responderPrologue: Data("herdr-guest/1:B".utf8))) { error in
            XCTAssertEqual(error as? NoiseIK.Failure, .decryptFailed)
        }
    }

    func testTamperedMessage2IsRejected() throws {
        let hostKey = Curve25519.KeyAgreement.PrivateKey()
        var initiator = try NoiseIK.Initiator(
            prologue: Data(), staticKey: .init(), remoteStatic: hostKey.publicKey.rawRepresentation)
        var responder = TestIKResponder(prologue: Data(), staticKey: hostKey)
        _ = try responder.readMessage1(try initiator.writeMessage1(payload: Data()))
        var (message2, _) = try responder.writeMessage2(Data(#"{"ok":true}"#.utf8))
        message2[message2.count - 1] ^= 0x01
        XCTAssertThrowsError(try initiator.readMessage2(message2)) { error in
            XCTAssertEqual(error as? NoiseIK.Failure, .decryptFailed)
        }
        XCTAssertThrowsError(try initiator.readMessage2(Data(count: 47))) { error in
            XCTAssertEqual(error as? NoiseIK.Failure, .truncated)
        }
    }

    /// A forged transport message fails without advancing the nonce, so the genuine
    /// next message still decrypts; and replaying an old message fails.
    func testForgedAndReplayedTransportMessages() throws {
        var (guest, host) = try handshake()
        let first = try host.encrypt(Data("line 1\n".utf8))
        let second = try host.encrypt(Data("line 2\n".utf8))

        var forged = second
        forged[0] ^= 0xff
        XCTAssertThrowsError(try guest.decrypt(forged))
        XCTAssertThrowsError(try guest.decrypt(second), "out of order: nonce 0 expected")
        XCTAssertEqual(try guest.decrypt(first), Data("line 1\n".utf8))
        XCTAssertThrowsError(try guest.decrypt(first), "replay")
        XCTAssertEqual(try guest.decrypt(second), Data("line 2\n".utf8))
    }

    func testChunkingRespectsTheNoiseCeiling() throws {
        var (guest, host) = try handshake()
        let big = Data((0..<(NoiseIK.maxPlaintextBytes * 2 + 7)).map { UInt8(truncatingIfNeeded: $0) })
        let messages = try guest.encryptChunked(big)
        XCTAssertEqual(messages.map(\.count), [NoiseIK.maxMessageBytes, NoiseIK.maxMessageBytes, 7 + 16])
        var reassembled = Data()
        for message in messages { reassembled += try host.decrypt(message) }
        XCTAssertEqual(reassembled, big)

        XCTAssertThrowsError(try guest.encrypt(Data(count: NoiseIK.maxPlaintextBytes + 1))) { error in
            XCTAssertEqual(error as? NoiseIK.Failure, .messageTooLarge(NoiseIK.maxMessageBytes + 1))
        }
    }

    func testHandshakeStepsMustRunInOrder() throws {
        var initiator = try NoiseIK.Initiator(
            prologue: Data(), staticKey: .init(),
            remoteStatic: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
        XCTAssertThrowsError(try initiator.readMessage2(Data(count: 64))) { error in
            XCTAssertEqual(error as? NoiseIK.Failure, .outOfOrder)
        }
        _ = try initiator.writeMessage1(payload: Data())
        XCTAssertThrowsError(try initiator.writeMessage1(payload: Data())) { error in
            XCTAssertEqual(error as? NoiseIK.Failure, .outOfOrder)
        }
        XCTAssertThrowsError(try NoiseIK.Initiator(prologue: Data(), staticKey: .init(), remoteStatic: Data(count: 31)))
    }
}
