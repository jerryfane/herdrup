import Foundation

/// A downloaded gram file kept on disk, so opening it a second time costs nothing.
public struct CachedGramFile: Equatable, Sendable {
    public let url: URL
    public let name: String
    public let size: Int

    public init(url: URL, name: String, size: Int) {
        self.url = url
        self.name = name
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
/// This lives in HerdrKit for the same reason `GramStaging` does: the app target cannot
/// compile on Linux CI, so cache logic kept beside the view would be verified by
/// reading. A cache that silently never hits behaves exactly like no cache at all —
/// the feature would look implemented and do nothing — so the lookup, the eviction
/// order and the name handling are exercised on every CI run.
public enum GramFileCache {

    /// Default ceiling for the whole cache. Gram carries up to ten 100 MB attachments
    /// per message, so a handful of large opens could otherwise fill the device; the
    /// cache lives under Caches, which the system may also purge on its own.
    public static let defaultMaxBytes = 512 * 1024 * 1024

    /// The per-message directory. One directory per id, holding the file under its own
    /// name, so the name is preserved for QuickLook and the share sheet without
    /// colliding with another message that shipped a file of the same name.
    public static func directory(for id: String, in root: URL) -> URL {
        root.appendingPathComponent(safeComponent(id), isDirectory: true)
    }

    /// The cached file for `id`, or nil when it was never downloaded or has been
    /// evicted. Returns whatever single file the directory holds rather than requiring
    /// the caller to know the name, because the Saved tab can outlive the server copy
    /// and no longer knows it.
    public static func cached(id: String, in root: URL) -> CachedGramFile? {
        let dir = directory(for: id, in: root)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])
        else { return nil }
        guard let url = entries.first(where: { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true })
        else { return nil }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0
        else { return nil }
        // Touched on read so eviction is least-RECENTLY-USED rather than oldest-stored:
        // the file the reader keeps opening is the one worth keeping.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
        return CachedGramFile(url: url, name: url.lastPathComponent, size: size)
    }

    /// Store `data` for `id` and return its cached location. Replaces any existing
    /// entry for the same id, so a partial or renamed earlier copy cannot linger.
    /// Returns nil only when the write fails — the caller then falls back to a temp
    /// file, because failing to cache must never fail the open.
    @discardableResult
    public static func store(
        _ data: Data,
        id: String,
        name: String,
        in root: URL,
        maxBytes: Int = defaultMaxBytes
    ) -> CachedGramFile? {
        guard !data.isEmpty else { return nil }
        // A single file larger than the whole budget is not cached: storing it would
        // immediately evict everything else and then itself.
        guard data.count <= maxBytes else { return nil }

        let dir = directory(for: id, in: root)
        try? FileManager.default.removeItem(at: dir)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(GramStaging.safeFileName(name))
            try data.write(to: url, options: [.atomic])
            protect(url)
            evict(in: root, maxBytes: maxBytes)
            return CachedGramFile(url: url, name: url.lastPathComponent, size: data.count)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    /// Drop one entry — used when the reader deletes or unsaves the message, so the
    /// bytes do not outlive the thing that referenced them.
    public static func remove(id: String, in root: URL) {
        try? FileManager.default.removeItem(at: directory(for: id, in: root))
    }

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

    /// Message ids come from the daemon. They are opaque strings, so they are reduced
    /// to one safe path component before being used as a directory name — an id
    /// containing a slash or `..` must not be able to write outside the cache root.
    public static func safeComponent(_ id: String) -> String {
        let cleaned = id.unicodeScalars.map { scalar -> Character in
            let allowed = CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
            return allowed ? Character(scalar) : "_"
        }
        let joined = String(cleaned)
        let trimmed = joined.isEmpty ? "unnamed" : String(joined.prefix(120))
        // "." and ".." survive the filter above as "_" already, but an all-underscore
        // result from a pathological id is still a valid, distinct component.
        return trimmed
    }

    private static func protect(_ url: URL) {
        #if canImport(Darwin)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }
}
