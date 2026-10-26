import Foundation
import XCTest
@testable import HerdrKit

/// herdrup#538: the avatar descriptor, the photo rules, the sha256-keyed cache and the
/// `agent.avatar.*` client calls.
final class AgentAvatarTests: XCTestCase {
    private func agent(_ avatar: Any?) throws -> AgentInfo {
        var object: [String: Any] = ["pane_id": "w1:p1", "terminal_id": "t-1", "name": "scout"]
        if let avatar { object["avatar"] = avatar }
        return try JSONDecoder().decode(AgentInfo.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private let sha = String(repeating: "ab", count: 32)

    // MARK: descriptor

    func testMascotDescriptorDecodes() throws {
        let info = try agent(["style": "mascot", "mascot": "bot", "sha256": NSNull(), "updated_unix_ms": 1_761_000_000_000])
        XCTAssertEqual(info.avatar, AgentAvatarDescriptor(style: .mascot, mascot: "bot", updatedUnixMs: 1_761_000_000_000))
        XCTAssertEqual(AgentAvatarAppearance.resolve(info.avatar), .mascot(.bot))
        XCTAssertEqual(AgentAvatarAppearance.resolve(info.avatar).identifierSuffix, "bot")
    }

    func testImageDescriptorDecodes() throws {
        let info = try agent(["style": "image", "mascot": NSNull(), "sha256": sha.uppercased(), "updated_unix_ms": 5])
        XCTAssertEqual(info.avatar?.style, .image)
        XCTAssertEqual(info.avatar?.sha256, sha, "the content address is normalised to lowercase")
        XCTAssertEqual(AgentAvatarAppearance.resolve(info.avatar), .image(sha256: sha))
    }

    func testAbsentOrNullAvatarIsHerdy() throws {
        XCTAssertNil(try agent(nil).avatar)
        XCTAssertNil(try agent(NSNull()).avatar)
        XCTAssertEqual(AgentAvatarAppearance.resolve(nil), .mascot(.herdy))
        XCTAssertEqual(AgentMascot.default, .herdy)
    }

    func testUnknownStyleAndMalformedValuesFallBackToTheDefault() throws {
        XCTAssertEqual(AgentAvatarAppearance.resolve(try agent(["style": "hologram", "mascot": "bot"]).avatar), .mascot(.herdy))
        XCTAssertEqual(try agent("bot").avatar?.style, .unrecognised, "a non-object never fails the list")
        XCTAssertEqual(AgentAvatarAppearance.resolve(try agent([1, 2]).avatar), .mascot(.herdy))
        XCTAssertEqual(AgentAvatarAppearance.resolve(try agent(["style": "image", "sha256": "../etc"]).avatar), .mascot(.herdy),
                       "an image without a valid content address cannot be fetched")
        XCTAssertEqual(AgentAvatarAppearance.resolve(try agent(["style": "mascot"]).avatar), .mascot(.herdy))
        XCTAssertEqual(AgentAvatarAppearance.resolve(try agent(["style": 7]).avatar), .mascot(.herdy))
    }

    func testAMascotThisBuildDoesNotShipStaysDistinctFromTheDefault() throws {
        let appearance = AgentAvatarAppearance.resolve(try agent(["style": "mascot", "mascot": "nova-2"]).avatar)
        XCTAssertEqual(appearance, .unknownMascot("nova-2"))
        XCTAssertEqual(appearance.identifierSuffix, "unknown")
    }

    func testTheBundledSetIsTheApprovedTwelveInPickerOrder() {
        XCTAssertEqual(AgentMascot.allCases.map(\.rawValue),
                       ["herdy", "bot", "blip", "tri", "squib", "zag", "cub", "dome", "pip", "prism", "nib", "drop"])
        XCTAssertEqual(AgentMascot.bot.displayName, "Bot")
        // Every id must satisfy the server's grammar.
        for mascot in AgentMascot.allCases {
            XCTAssertNotNil(mascot.rawValue.range(of: "^[a-z0-9-]{1,32}$", options: .regularExpression))
        }
    }

    func testCapabilityDecodesAndDefaultsFalse() throws {
        let on = try JSONDecoder().decode(ServerCapabilities.self, from: Data(#"{"agent_avatar":true}"#.utf8))
        XCTAssertTrue(on.agentAvatar)
        let off = try JSONDecoder().decode(ServerCapabilities.self, from: Data("{}".utf8))
        XCTAssertFalse(off.agentAvatar)
    }

    // MARK: photo rules

    func testEncodeWithinLimitWalksTheQualityLadderUntilItFits() {
        var tried: [Double] = []
        // A fake encoder whose output shrinks with quality: 100 KiB at 0.85, 70 at 0.75, 40 at 0.65.
        let data = AgentAvatarImage.encodeWithinLimit { quality in
            tried.append(quality)
            let kib: Int
            switch quality {
            case 0.85: kib = 100
            case 0.75: kib = 70
            default: kib = 40
            }
            return Data(count: kib * 1024)
        }
        XCTAssertEqual(tried, [0.85, 0.75, 0.65])
        XCTAssertEqual(data?.count, 40 * 1024)
        XCTAssertLessThanOrEqual(data?.count ?? .max, AgentAvatarImage.maxBytes)
    }

    func testEncodeWithinLimitGivesUpWhenNothingFits() {
        XCTAssertNil(AgentAvatarImage.encodeWithinLimit { _ in Data(count: AgentAvatarImage.maxBytes + 1) })
        XCTAssertNil(AgentAvatarImage.encodeWithinLimit { _ in nil })
        XCTAssertEqual(AgentAvatarImage.encodeWithinLimit { _ in Data(count: AgentAvatarImage.maxBytes) }?.count,
                       64 * 1024, "exactly 64 KiB is within the cap")
    }

    func testTheNormalisedImageIs256Square() {
        XCTAssertEqual(AgentAvatarImage.pixelSize, 256)
        XCTAssertEqual(AgentAvatarImage.maxBytes, 65_536)
    }

    func testCropRectIsTheCentredSquareAndNeverLeavesTheImage() {
        let centred = AgentAvatarImage.cropRect(imageWidth: 4000, imageHeight: 3000, zoom: 1, offsetX: 0, offsetY: 0)
        XCTAssertEqual(centred.side, 3000)
        XCTAssertEqual(centred.x, 500)
        XCTAssertEqual(centred.y, 0)

        let zoomed = AgentAvatarImage.cropRect(imageWidth: 4000, imageHeight: 3000, zoom: 2, offsetX: 1, offsetY: -1)
        XCTAssertEqual(zoomed.side, 1500)
        XCTAssertEqual(zoomed.x, 2500, "offset 1 puts the square against the right edge")
        XCTAssertEqual(zoomed.y, 0)

        let clamped = AgentAvatarImage.cropRect(imageWidth: 1000, imageHeight: 1000, zoom: 0.2, offsetX: 9, offsetY: 9)
        XCTAssertEqual(clamped.side, 1000, "zoom below 1 is treated as 1")
        XCTAssertEqual(clamped.x, 0)
        XCTAssertEqual(clamped.y, 0)
    }

    func testMimeComesFromTheMagicBytes() {
        XCTAssertEqual(AgentAvatarImage.mime(of: Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0])), "image/jpeg")
        XCTAssertEqual(AgentAvatarImage.mime(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])), "image/png")
        XCTAssertNil(AgentAvatarImage.mime(of: Data("GIF89a".utf8)))
        XCTAssertNil(AgentAvatarImage.mime(of: Data()))
    }

    // MARK: cache

    func testCacheIsKeyedByTheContentAddress() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([0xFF, 0xD8, 0xFF, 1, 2, 3])
        let key = AgentAvatarImage.sha256(of: bytes)

        let cache = AgentAvatarImageCache(directory: root)
        XCTAssertNil(cache.data(for: key))
        XCTAssertTrue(cache.store(bytes, sha256: key.uppercased()))
        XCTAssertEqual(cache.fileURL(for: key)?.lastPathComponent, key)
        XCTAssertEqual(cache.data(for: key), bytes)

        // A second instance (a relaunch) reads it from disk.
        let relaunched = AgentAvatarImageCache(directory: root)
        XCTAssertEqual(relaunched.data(for: key), bytes)
    }

    func testCacheRefusesBytesThatDoNotMatchTheKeyAndMalformedKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AgentAvatarImageCache(directory: root)
        XCTAssertFalse(cache.store(Data([1, 2, 3]), sha256: sha))
        XCTAssertNil(cache.data(for: sha))
        XCTAssertFalse(cache.store(Data([1]), sha256: "../../escape"))
        XCTAssertNil(cache.fileURL(for: "../../escape"))
        XCTAssertNil(cache.fileURL(for: String(repeating: "g", count: 64)))

        // A file swapped on disk is discarded on read, not served.
        let bytes = Data([9, 9, 9])
        let key = AgentAvatarImage.sha256(of: bytes)
        XCTAssertTrue(cache.store(bytes, sha256: key))
        let url = try XCTUnwrap(cache.fileURL(for: key))
        try Data([6, 6]).write(to: url)
        let fresh = AgentAvatarImageCache(directory: root)
        XCTAssertNil(fresh.data(for: key))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: client

    func testSetMascotSendsTheDescriptor() async throws {
        let transport = RecordingTransport(reply: #"{"id":"x","result":{"type":"agent_avatar_set","avatar":{"style":"mascot","mascot":"bot","sha256":null,"updated_unix_ms":9}}}"#)
        let avatar = try await HerdrClient(transport: transport).agentAvatarSet(target: "t-1", choice: .bundled(.bot))
        XCTAssertEqual(avatar?.appearance, .mascot(.bot))
        let request = try transport.last()
        XCTAssertEqual(request.method, "agent.avatar.set")
        XCTAssertEqual(request.params["target"] as? String, "t-1")
        let descriptor = try XCTUnwrap(request.params["avatar"] as? [String: Any])
        XCTAssertEqual(descriptor["style"] as? String, "mascot")
        XCTAssertEqual(descriptor["mascot"] as? String, "bot")
        XCTAssertNil(request.params["image_base64"])
    }

    func testClearSendsAnExplicitNull() async throws {
        let transport = RecordingTransport(reply: #"{"id":"x","result":{"type":"agent_avatar_set","avatar":null}}"#)
        let avatar = try await HerdrClient(transport: transport).agentAvatarSet(target: "t-1", choice: nil)
        XCTAssertNil(avatar)
        XCTAssertTrue(transport.lastRequest.contains(#""avatar":null"#), transport.lastRequest)
    }

    func testSetImageSendsTheBytesInline() async throws {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xDB, 1, 2])
        let key = AgentAvatarImage.sha256(of: bytes)
        let transport = RecordingTransport(reply: #"{"id":"x","result":{"type":"agent_avatar_set","avatar":{"style":"image","sha256":"\#(key)","updated_unix_ms":9}}}"#)
        let avatar = try await HerdrClient(transport: transport)
            .agentAvatarSet(target: "t-1", choice: .image(data: bytes, mime: "image/jpeg"))
        XCTAssertEqual(avatar?.appearance, .image(sha256: key))
        let request = try transport.last()
        XCTAssertEqual((request.params["avatar"] as? [String: Any])?["style"] as? String, "image")
        XCTAssertEqual(request.params["image_base64"] as? String, bytes.base64EncodedString())
        XCTAssertEqual(request.params["mime"] as? String, "image/jpeg")
    }

    func testGetDecodesTheImage() async throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let transport = RecordingTransport(reply: #"{"id":"x","result":{"type":"agent_avatar_image","mime":"image/png","data_base64":"\#(bytes.base64EncodedString())"}}"#)
        let image = try await HerdrClient(transport: transport).agentAvatarGet(target: "t-1", sha256: sha)
        XCTAssertEqual(image, AgentAvatarImageData(mime: "image/png", data: bytes))
        let request = try transport.last()
        XCTAssertEqual(request.method, "agent.avatar.get")
        XCTAssertEqual(request.params["sha256"] as? String, sha)
    }

    func testAnOlderDaemonReadsAsUnsupported() async {
        let transport = RecordingTransport.error(code: "invalid_request",
                                                 message: "unknown variant `agent.avatar.set`, expected one of `ping`")
        do {
            _ = try await HerdrClient(transport: transport).agentAvatarSet(target: "t-1", choice: .bundled(.bot))
            XCTFail("expected unsupported")
        } catch {
            XCTAssertEqual(error as? AgentAvatarError, .unsupported)
        }
        let other = RecordingTransport.error(code: "invalid_avatar", message: "bad mascot")
        do {
            _ = try await HerdrClient(transport: other).agentAvatarSet(target: "t-1", choice: .mascot("x"))
            XCTFail("expected the server error")
        } catch {
            XCTAssertEqual((error as? APIError)?.code, "invalid_avatar")
        }
    }
    // MARK: addressing and Gram lookup

    private func roster(_ rows: [[String: Any]]) throws -> [AgentInfo] {
        try rows.map { try JSONDecoder().decode(AgentInfo.self, from: JSONSerialization.data(withJSONObject: $0)) }
    }

    func testAvatarTargetPrefersTheStableTerminalIDLocally() throws {
        let agents = try roster([
            ["pane_id": "w1:p1", "terminal_id": "t-local", "name": "scout"],
            ["pane_id": "mac/w2:p1", "terminal_id": "t-remote", "name": "mac/scout", "machine_id": "mac"],
            ["pane_id": "", "terminal_id": "t-archived", "name": "old", "archived": ["by": "owner"]],
            ["pane_id": "w1:p9", "name": "legacy"],
        ])
        XCTAssertEqual(agents.map(\.avatarTarget), ["t-local", "mac/w2:p1", "t-archived", "w1:p9"])
        XCTAssertEqual(agents.map(\.avatarKey), ["t-local", "t-remote", "t-archived", "w1:p9"])
    }

    func testGramSendersResolveThroughTheRoster() throws {
        let agents = try roster([
            ["pane_id": "w1:p1", "terminal_id": "t-1", "name": "clientloop", "avatar": ["style": "mascot", "mascot": "bot"]],
            ["pane_id": "4b1e/w1:p2", "terminal_id": "t-2", "name": "4b1e/clientloop", "machine_id": "4b1e",
             "machine_label": "hetzner-1", "avatar": ["style": "mascot", "mascot": "zag"]],
            ["pane_id": "w1:p3", "terminal_id": "t-3", "name": "vetrina"],
        ])
        XCTAssertEqual(AgentAvatarLookup.agent(forGramSender: "clientloop", in: agents)?.terminalID, "t-1",
                       "a local sender is the local agent, not the federated namesake")
        XCTAssertEqual(AgentAvatarLookup.agent(forGramSender: "4b1e/clientloop", in: agents)?.terminalID, "t-2")
        XCTAssertEqual(AgentAvatarLookup.agent(forGramSender: "4b1e/w1:p2/clientloop", in: agents)?.terminalID, "t-2")
        XCTAssertEqual(AgentAvatarLookup.agent(forGramSender: "hetzner-1/clientloop", in: agents)?.terminalID, "t-2",
                       "the machine label names the machine too")
        XCTAssertNil(AgentAvatarLookup.agent(forGramSender: "other/clientloop", in: agents))
        XCTAssertNil(AgentAvatarLookup.agent(forGramSender: "forgotten", in: agents))
        XCTAssertEqual(AgentAvatarAppearance.resolve(AgentAvatarLookup.agent(forGramSender: "forgotten", in: agents)?.avatar),
                       .mascot(.herdy), "an unknown sender wears the default")
    }

    // MARK: pending changes

    func testAPendingChangeHoldsUntilTheRosterCatchesUp() {
        let bot = AgentAvatarDescriptor(style: .mascot, mascot: "bot", updatedUnixMs: 20)
        let inFlight = AgentAvatarPendingChange(descriptor: .mascot(.bot), inFlight: true, replacedUpdatedUnixMs: 10)
        XCTAssertFalse(inFlight.isSettled(by: bot), "an unanswered change always wins")

        let answered = AgentAvatarPendingChange(descriptor: bot, inFlight: false, replacedUpdatedUnixMs: 10)
        XCTAssertFalse(answered.isSettled(by: AgentAvatarDescriptor(style: .mascot, mascot: "tri", updatedUnixMs: 10)),
                       "a list fetched before the change must not revert it")
        XCTAssertTrue(answered.isSettled(by: bot))
        XCTAssertTrue(answered.isSettled(by: AgentAvatarDescriptor(style: .mascot, mascot: "pip", updatedUnixMs: 30)),
                      "a newer change from another device wins")

        let cleared = AgentAvatarPendingChange(descriptor: nil, inFlight: false, replacedUpdatedUnixMs: 20)
        XCTAssertFalse(cleared.isSettled(by: bot))
        XCTAssertTrue(cleared.isSettled(by: nil))
    }
}
