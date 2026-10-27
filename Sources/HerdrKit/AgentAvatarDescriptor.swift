import Foundation
import Crypto

// MARK: - Mascots

/// The bundled agent mascots (the approved "Pebbles" set, herdrup#538), in picker order.
/// The raw value is the wire id (`AgentInfo.avatar.mascot`) and names the app's image set
/// `Mascot-<id>`. Herdy, derived from the app icon, is what an agent with no choice wears.
/// Keep in sync with `MASCOTS` in Tools/mascots/generate-mascots.py.
public enum AgentMascot: String, CaseIterable, Sendable, Identifiable {
    case herdy, bot, blip, tri, squib, zag, cub, dome, pip, prism, nib, drop

    /// What an agent without a chosen avatar shows.
    public static let `default`: AgentMascot = .herdy

    public var id: String { rawValue }

    /// Display name for the picker and VoiceOver ("Herdy", "Bot", ...).
    public var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

// MARK: - Descriptor

/// `AgentInfo.avatar`: the picture an owner chose for an agent, stored on the herdr server
/// keyed by the agent's terminal id, so every owner device and every guest the agent is
/// shared with sees the same choice. Only the descriptor rides in `agent.list`; image bytes
/// are fetched once by `sha256` (`HerdrClient.agentAvatarGet`) and cached forever, because a
/// content address never changes meaning.
///
/// Decoded leniently and NEVER throws: an unknown `style` (a newer server) or a malformed
/// value reads as `.unrecognised`, which renders as the default mascot, rather than failing
/// the whole `agent.list`.
public struct AgentAvatarDescriptor: Decodable, Equatable, Sendable {
    public enum Style: String, Sendable {
        case mascot, image, unrecognised
    }

    public let style: Style
    /// The mascot id for `style == .mascot`. Any `^[a-z0-9-]{1,32}$` on the wire, so a
    /// newer server can carry a mascot this build does not ship (see `appearance`).
    public let mascot: String?
    /// Lowercase hex sha256 of the image bytes for `style == .image`.
    public let sha256: String?
    public let updatedUnixMs: UInt64?

    public init(style: Style, mascot: String? = nil, sha256: String? = nil, updatedUnixMs: UInt64? = nil) {
        self.style = style
        self.mascot = mascot
        self.sha256 = sha256
        self.updatedUnixMs = updatedUnixMs
    }

    public static func mascot(_ mascot: AgentMascot) -> AgentAvatarDescriptor {
        AgentAvatarDescriptor(style: .mascot, mascot: mascot.rawValue)
    }

    enum CodingKeys: String, CodingKey {
        case style, mascot, sha256
        case updatedUnixMs = "updated_unix_ms"
    }

    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init(style: .unrecognised)
            return
        }
        let raw = (try? c.decodeIfPresent(String.self, forKey: .style)) ?? nil
        self.init(
            style: raw.flatMap(Style.init(rawValue:)).flatMap { $0 == .unrecognised ? nil : $0 } ?? .unrecognised,
            mascot: (try? c.decodeIfPresent(String.self, forKey: .mascot)) ?? nil,
            sha256: ((try? c.decodeIfPresent(String.self, forKey: .sha256)) ?? nil)?.lowercased(),
            updatedUnixMs: (try? c.decodeIfPresent(UInt64.self, forKey: .updatedUnixMs)) ?? nil)
    }

    /// What to draw for this descriptor.
    public var appearance: AgentAvatarAppearance {
        switch style {
        case .mascot:
            guard let mascot, !mascot.isEmpty else { return .mascot(.default) }
            if let known = AgentMascot(rawValue: mascot) { return .mascot(known) }
            // A mascot a newer build ships: the owner chose something specific, so it
            // shows as the agent's generated circle rather than passing for the default.
            return .unknownMascot(mascot)
        case .image:
            guard let sha256, AgentAvatarImage.isValidSHA256(sha256) else { return .mascot(.default) }
            return .image(sha256: sha256)
        case .unrecognised:
            return .mascot(.default)
        }
    }
}

/// The resolved rendering of an agent's avatar. `nil` descriptors resolve to the default
/// mascot (`AgentAvatarAppearance.resolve`).
public enum AgentAvatarAppearance: Equatable, Sendable {
    case mascot(AgentMascot)
    case image(sha256: String)
    /// A mascot id this build does not ship: drawn as the name's generated circle.
    case unknownMascot(String)

    public static func resolve(_ avatar: AgentAvatarDescriptor?) -> AgentAvatarAppearance {
        avatar?.appearance ?? .mascot(.default)
    }

    /// The stable accessibility identifier suffix: `herdy`, `bot`, `image`, `unknown`.
    public var identifierSuffix: String {
        switch self {
        case .mascot(let m): return m.rawValue
        case .image: return "image"
        case .unknownMascot: return "unknown"
        }
    }
}

// MARK: - Addressing

extension AgentInfo {
    /// What `agent.avatar.set` / `agent.avatar.get` address this agent by. A local agent's
    /// terminal id: the key the server stores avatars under, stable across rename, restart
    /// and archive. A federated agent's prefixed pane id, which the home routes to its
    /// machine (a bare terminal id would resolve on the home). An archived agent has no
    /// pane, so its terminal id or name.
    public var avatarTarget: String {
        if machineID == nil, let terminalID, !terminalID.isEmpty { return terminalID }
        if !paneID.isEmpty { return paneID }
        return terminalID ?? name ?? paneID
    }

    /// The identity the app keys a pending avatar change by: the terminal id, else the
    /// list identity.
    public var avatarKey: String { terminalID ?? id }
}

/// Gram identifies a sender only by its routing name (`from`), so its avatar comes from
/// the roster entry that name denotes. A local sender is the local agent of that name; a
/// federated `<machine>/…/<name>` is the agent of that bare name on the machine whose id
/// or label the prefix carries. No match (a renamed or forgotten agent, a guest who only
/// knows its granted agent) means the default mascot.
public enum AgentAvatarLookup {
    public static func agent(forGramSender from: String, in roster: [AgentInfo]) -> AgentInfo? {
        if let exact = roster.first(where: { $0.name == from }) { return exact }
        let bare = GramMessage.agentName(from: from)
        guard let slash = from.firstIndex(of: "/"), slash != from.startIndex else {
            return roster.first { $0.machineID == nil && $0.name == bare }
        }
        let machine = String(from[..<slash])
        return roster.first { info in
            guard info.machineID == machine || (info.machineLabel != nil && info.machineLabel == machine) else { return false }
            return info.name.map(GramMessage.agentName(from:)) == bare
        }
    }
}

/// What `agent.avatar.set` sends as `avatar`: a mascot, or a photo whose bytes travel
/// alongside as `image_base64`. A nil choice clears the agent back to the default.
public enum AgentAvatarChoice: Equatable, Sendable {
    case mascot(String)
    case image(data: Data, mime: String)

    public static func bundled(_ mascot: AgentMascot) -> AgentAvatarChoice { .mascot(mascot.rawValue) }
}

/// An avatar image as `agent.avatar.get` returns it.
public struct AgentAvatarImageData: Equatable, Sendable {
    public let mime: String
    public let data: Data

    public init(mime: String, data: Data) {
        self.mime = mime
        self.data = data
    }
}

public enum AgentAvatarError: Error, Equatable, Sendable {
    /// The daemon predates `agent.avatar.*` (method not found).
    case unsupported
    /// The server answered with bytes that are not base64.
    case malformedImage
}

// MARK: - Image rules

/// The photo rules shared by the app's upload path and its tests. The app target cannot
/// compile on Linux, so the decisions live here where `swift test` exercises them: the
/// pixel size, the byte cap the server enforces, the quality ladder, the crop geometry
/// and the content address.
public enum AgentAvatarImage {
    /// The server's cap on decoded image bytes.
    public static let maxBytes = 64 * 1024
    /// The normalised edge: covers the 72 pt guest accept card at 3x.
    public static let pixelSize = 256
    /// JPEG qualities tried in order until the encoding fits `maxBytes`.
    public static let qualityLadder: [Double] = [0.85, 0.75, 0.65, 0.55, 0.45, 0.35, 0.25, 0.15]

    /// The first encoding along `qualityLadder` that fits `maxBytes`, or nil when even the
    /// lowest quality does not (or the encoder fails).
    public static func encodeWithinLimit(
        maxBytes: Int = maxBytes,
        qualities: [Double] = qualityLadder,
        encode: (Double) -> Data?
    ) -> Data? {
        for quality in qualities {
            guard let data = encode(quality) else { continue }
            if !data.isEmpty, data.count <= maxBytes { return data }
        }
        return nil
    }

    /// The square of the source image, in source pixels, that the crop sheet shows.
    /// `zoom >= 1` scales the largest centred square down; `offset` moves the square's
    /// centre in units of the free travel on each axis (-1 ... 1, clamped), so the crop
    /// can never leave the image.
    public static func cropRect(
        imageWidth: Double, imageHeight: Double, zoom: Double, offsetX: Double, offsetY: Double
    ) -> (x: Double, y: Double, side: Double) {
        let side = min(imageWidth, imageHeight) / max(zoom, 1)
        let travelX = (imageWidth - side) / 2
        let travelY = (imageHeight - side) / 2
        let clampedX = min(max(offsetX, -1), 1)
        let clampedY = min(max(offsetY, -1), 1)
        return (x: travelX + clampedX * travelX, y: travelY + clampedY * travelY, side: side)
    }

    /// `image/jpeg` or `image/png` from the magic bytes (what the server checks), else nil.
    public static func mime(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(8))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "image/jpeg" }
        if bytes == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return "image/png" }
        return nil
    }

    /// The content address the server stores an image under: lowercase hex sha256.
    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Exactly 64 lowercase hex digits: the only strings that may become a cache file name.
    public static func isValidSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

// MARK: - Cache

/// Avatar image bytes, keyed by their sha256: in memory (NSCache) and on disk under
/// Caches. Content addressing means an entry never goes stale, so there is no
/// revalidation; integrity is the only check. A key must be a well-formed sha256 (it
/// becomes a file name) and the bytes must hash to it, on store and on every disk read,
/// so a truncated or swapped file is discarded and refetched instead of shown forever.
public final class AgentAvatarImageCache: @unchecked Sendable {
    private let memory = NSCache<NSString, NSData>()
    public let directory: URL?

    /// `directory` nil keeps the cache in memory only.
    public init(directory: URL?) {
        self.directory = directory
        memory.totalCostLimit = 8 * 1024 * 1024
    }

    /// The app's shared cache: `Caches/agent-avatars`.
    public static let shared = AgentAvatarImageCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("agent-avatars", isDirectory: true))

    /// The on-disk file for `sha256`, or nil for a malformed key or a memory-only cache.
    public func fileURL(for sha256: String) -> URL? {
        let key = sha256.lowercased()
        guard AgentAvatarImage.isValidSHA256(key), let directory else { return nil }
        return directory.appendingPathComponent(key, isDirectory: false)
    }

    public func data(for sha256: String) -> Data? {
        let key = sha256.lowercased()
        guard AgentAvatarImage.isValidSHA256(key) else { return nil }
        if let hit = memory.object(forKey: key as NSString) { return hit as Data }
        guard let url = fileURL(for: key), let data = try? Data(contentsOf: url) else { return nil }
        guard AgentAvatarImage.sha256(of: data) == key else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }

    /// Stores `data` under `sha256` when the bytes hash to it. Returns whether it did.
    @discardableResult
    public func store(_ data: Data, sha256: String) -> Bool {
        let key = sha256.lowercased()
        guard AgentAvatarImage.isValidSHA256(key), !data.isEmpty,
              AgentAvatarImage.sha256(of: data) == key else { return false }
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        if let directory, let url = fileURL(for: key) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic])
        }
        return true
    }

    /// Drops the in-memory copies (the disk copies stay).
    public func clearMemory() {
        memory.removeAllObjects()
    }
}

// MARK: - Pending changes

/// An avatar change this device made, held over the roster until the roster reports it.
/// The roster's own value wins as soon as it shows the same choice, or a NEWER change made
/// elsewhere (another device of the owner), so an optimistic value can never mask a later
/// edit for long.
public struct AgentAvatarPendingChange: Equatable, Sendable {
    public var descriptor: AgentAvatarDescriptor?
    /// True until `agent.avatar.set` answers; an in-flight change always wins.
    public var inFlight: Bool
    /// The `updated_unix_ms` of the value this change replaced.
    public var replacedUpdatedUnixMs: UInt64?

    public init(descriptor: AgentAvatarDescriptor?, inFlight: Bool, replacedUpdatedUnixMs: UInt64?) {
        self.descriptor = descriptor
        self.inFlight = inFlight
        self.replacedUpdatedUnixMs = replacedUpdatedUnixMs
    }

    /// Whether the roster's `reported` value makes this change unnecessary.
    public func isSettled(by reported: AgentAvatarDescriptor?) -> Bool {
        guard !inFlight else { return false }
        if AgentAvatarAppearance.resolve(reported) == AgentAvatarAppearance.resolve(descriptor),
           (reported == nil) == (descriptor == nil) {
            return true
        }
        let ours = max(descriptor?.updatedUnixMs ?? 0, replacedUpdatedUnixMs ?? 0)
        return (reported?.updatedUnixMs ?? 0) > ours
    }
}
