import Foundation

/// A gram attachment staged on disk: the bytes, plus the per-item directory that
/// holds them. Removing `dir` removes the staged bytes.
public struct StagedAttachment: Equatable, Sendable {
    public let url: URL
    public let dir: URL
    public let size: Int

    public init(url: URL, dir: URL, size: Int) {
        self.url = url
        self.dir = dir
        self.size = size
    }
}

/// Filesystem staging for gram attachments: copy a pick into app-owned storage so
/// the upload streams it from disk instead of holding it in memory, and reclaim
/// what a killed session left behind.
///
/// This lives in HerdrKit rather than beside the composer for ONE reason: the app
/// target is iOS-only and cannot be compiled — let alone run — on Linux CI, so
/// staging logic kept there is verified by reading. A missing copy is not a
/// compile error and produces exactly the same "picked file was unreadable"
/// message as a genuinely unreadable pick; that defect shipped once and was caught
/// by review, not by a test. Here it is exercised on every CI run.
public enum GramStaging {
    /// Copy `source` into a fresh per-item directory under `sessionDirectory` and
    /// return it, or nil when the copy fails or the copied file is empty or over
    /// `maxBytes`. The per-item directory is removed on every failure path, so a
    /// rejected pick leaves nothing behind.
    ///
    /// The caller stats the source first (an unstat-able pick must never reach an
    /// unbounded copy); this re-checks the COPY, which is the file the upload will
    /// actually read.
    public static func stageCopy(
        of source: URL,
        named name: String,
        in sessionDirectory: URL,
        maxBytes: Int
    ) -> StagedAttachment? {
        let dir = sessionDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let destination = dir.appendingPathComponent(safeFileName(name))
            try FileManager.default.copyItem(at: source, to: destination)
            protectStagedFile(at: destination)
            guard let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                size > 0, size <= maxBytes
            else {
                try? FileManager.default.removeItem(at: dir)
                return nil
            }
            return StagedAttachment(url: destination, dir: dir, size: size)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    /// Remove every session directory under `root` except `keeping`. Bounded and
    /// stateless: a sibling of the current session's directory is by definition
    /// abandoned, because a session directory is named once at launch.
    public static func sweepAbandoned(root: URL, keeping current: String) {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries where entry.lastPathComponent != current {
            try? manager.removeItem(at: entry)
        }
    }

    /// Reduce a client-supplied name to a safe single path component: strip
    /// directory parts, replace separators, and never `.`/`..`.
    public static func safeFileName(_ name: String) -> String {
        let base = URL(fileURLWithPath: name).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == "." || base == ".." { return "file" }
        return base
    }

    /// `copyItem` does not set data protection, and a staged gram attachment can be
    /// a secret, so the class is set explicitly.
    ///
    /// `completeUnlessOpen`, NOT `complete`: the upload holds this file open across
    /// its whole transfer and keeps running when the app is backgrounded. Class A
    /// eviction fails reads even on an already-open descriptor, so locking the phone
    /// mid-upload would abort the send; Class B keeps an open file readable while
    /// still denying a new open while locked.
    private static func protectStagedFile(at url: URL) {
        #if canImport(Darwin)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
        #endif
    }
}
