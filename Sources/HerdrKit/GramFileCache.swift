import Foundation
import Crypto

/// A downloaded gram file kept on disk, so opening it a second time costs nothing.
public struct CachedGramFile: Equatable, Sendable {
    public let url: URL
    public let name: String
    /// The sender-supplied mime, carried through the cache because the viewer routing
    /// depends on it. Dropping it made a second open route differently from the first.
    public let mime: String
    public let size: Int

    public init(url: URL, name: String, mime: String, size: Int) {
        self.url = url
        self.name = name
        self.mime = mime
        self.size = size
    }
}

/// On-disk cache for gram files the reader has already downloaded.
///
/// WHY: every open re-fetched the file over SSH. The bytes had already crossed the
/// wire, been written to a temp file, and then been deleted by the page's cleanup, so
/// reopening a 40 MB video downloaded it again — and the reader waited again.
///
/// A gram message is immutable: its id names one file whose bytes never change, which
/// is what makes caching by id CORRECT rather than merely convenient. There is no
/// revalidation here because there is nothing to revalidate against.
///
/// THAT ABSENCE OF REVALIDATION IS ALSO THE RISK, and it drives two decisions below.
/// A bad entry is permanent — nothing would ever refetch it — so:
///
///  * an entry is only a hit once its `meta.json` exists, and that file is written
///    LAST, after the payload is fully in place. A crash inside the write window of a
///    100 MB attachment therefore leaves an entry that reads as a MISS and downloads
///    again, rather than a truncated file served forever.
///  * the recorded byte count is checked on every lookup. A payload that no longer
///    matches its metadata is discarded rather than presented.
///
/// Keys are `sha256(id)`, not a sanitised id. Mapping unsafe scalars to `_` collapsed
/// distinct ids onto one directory — `msg/1`, `msg.1`, `msg 1` and `msg:1` all became
/// `msg_1`, and two ids differing only past the truncation length became identical —
/// so whichever stored last owned the bytes and the other message served them.
///
/// This lives in HerdrKit for the same reason `GramStaging` does: the app target cannot
/// compile on Linux CI, so cache logic kept beside the view would be verified by
/// reading. A cache that silently never hits behaves exactly like no cache at all —
/// the feature would look implemented and do nothing — so the lookup, the eviction
/// order, the integrity gate and the key distinctness are exercised on every CI run.
public enum GramFileCache {

    /// Default ceiling for the whole cache. Gram carries up to ten 100 MB attachments
    /// per message, so a handful of large opens could otherwise fill the device; the
    /// cache lives under Caches, which the system may also purge on its own.
    public static let defaultMaxBytes = 512 * 1024 * 1024

    private static let metaName = "meta.json"
    /// The payload lives in a SUBDIRECTORY, not beside the metadata. An attachment is
    /// free to be called `meta.json` — `GramStaging.safeFileName` only strips directory
    /// parts — and when it was, the payload write and the metadata write hit the same
    /// path: the metadata destroyed the file, and the reader's first open previewed the
    /// cache's own JSON. A separate directory makes the collision impossible rather than
    /// blacklisting one name.
    private static let payloadDir = "payload"

    private struct Meta: Codable {
        let id: String
        let name: String
        let mime: String
        let size: Int
    }

    /// The per-message directory, named by a digest of the id so two different ids can
    /// never share one. Holds the payload under its own file name — preserved for
    /// QuickLook and the share sheet — plus `meta.json`.
    public static func directory(for id: String, in root: URL) -> URL {
        root.appendingPathComponent(key(for: id), isDirectory: true)
    }

    /// A collision-free, filesystem-safe directory name for an opaque daemon id.
    public static func key(for id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The cached file for `id`, or nil when it was never downloaded, is incomplete, or
    /// has been evicted.
    public static func cached(id: String, in root: URL) -> CachedGramFile? {
        let dir = directory(for: id, in: root)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(metaName)),
            let meta = try? JSONDecoder().decode(Meta.self, from: data)
        else { return nil }   // no metadata == a write that never finished
        // The recorded id must match: a digest collision, or a hand-edited cache, must
        // not serve one message's bytes as another's.
        guard meta.id == id else { return nil }

        let url = dir.appendingPathComponent(payloadDir).appendingPathComponent(meta.name)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size == meta.size, size > 0
        else { return nil }   // truncated or replaced since it was written

        // Touched on read so eviction is least-RECENTLY-used rather than oldest-stored:
        // the file the reader keeps opening is the one worth keeping.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
        return CachedGramFile(url: url, name: meta.name, mime: meta.mime, size: size)
    }

    /// Store `data` for `id` and return its cached location. Replaces any existing entry
    /// for the same id. Returns nil when the write fails — the caller then falls back to
    /// a temp file, because failing to cache must never fail the open.
    @discardableResult
    public static func store(
        _ data: Data,
        id: String,
        name: String,
        mime: String = "",
        in root: URL,
        maxBytes: Int = defaultMaxBytes
    ) -> CachedGramFile? {
        guard !data.isEmpty else { return nil }
        // A single file larger than the whole budget is not cached: storing it would
        // immediately evict everything else and then itself.
        guard data.count <= maxBytes else { return nil }

        let dir = directory(for: id, in: root)
        try? FileManager.default.removeItem(at: dir)
        let safeName = GramStaging.safeFileName(name)
        do {
            let payload = dir.appendingPathComponent(payloadDir, isDirectory: true)
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            let url = payload.appendingPathComponent(safeName)
            // Payload first, metadata last: the order is what makes an interrupted write
            // read as a miss instead of a permanently truncated hit.
            try data.write(to: url, options: [.atomic])
            protect(url)
            let meta = Meta(id: id, name: safeName, mime: mime, size: data.count)
            try JSONEncoder().encode(meta).write(to: dir.appendingPathComponent(metaName),
                                                 options: [.atomic])
            evict(in: root, maxBytes: maxBytes)
            return CachedGramFile(url: url, name: safeName, mime: mime, size: data.count)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    /// Drop one entry, so the bytes do not outlive the thing that referenced them.
    ///
    /// WIRED TO DELETE ONLY, plus `removeAll` on sign-out. Two routes deliberately do
    /// NOT evict, and the reasoning is worth keeping because review and a second opinion
    /// pulled in opposite directions here:
    ///
    ///  * UNSAVE. Unsaving stops keeping a message in the Saved tab; the message may
    ///    still exist in the inbox, so discarding the bytes would re-download on the
    ///    next open — defeating the feature this cache exists for. An earlier version
    ///    evicted here and it was the wrong call.
    ///  * SERVER-SIDE DISAPPEARANCE. A message the poll stops returning has no single
    ///    call site to hang eviction on.
    ///
    /// Both are reclaimed by the LRU ceiling. The first version of this comment claimed
    /// every removal route evicted, and that claim was simply false.
    public static func remove(id: String, in root: URL) {
        try? FileManager.default.removeItem(at: directory(for: id, in: root))
    }

    /// Drop everything. Called on sign-out and account removal.
    public static func removeAll(in root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    /// Total bytes currently held.
    public static func totalBytes(in root: URL) -> Int {
        entries(in: root).reduce(0) { $0 + $1.size }
    }

    /// Evict least-recently-used entries until the cache fits `maxBytes`.
    public static func evict(in root: URL, maxBytes: Int = defaultMaxBytes) {
        var all = entries(in: root)
        var total = all.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        // Oldest touch first, so the entry evicted is the one the reader has gone
        // longest without opening.
        all.sort { $0.touched < $1.touched }
        for entry in all {
            guard total > maxBytes else { break }
            try? FileManager.default.removeItem(at: entry.dir)
            total -= entry.size
        }
    }

    // MARK: - internals

    private struct Entry {
        let dir: URL
        let size: Int
        let touched: Date
    }

    private static func entries(in root: URL) -> [Entry] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        return dirs.compactMap { dir in
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey])
            else { return nil }
            let size = files.reduce(0) {
                $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            let touched = (try? dir.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return Entry(dir: dir, size: size, touched: touched)
        }
    }

    private static func protect(_ url: URL) {
        #if canImport(Darwin)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }
}
