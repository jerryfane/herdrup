import HerdrKit
import QuickLook
import SwiftUI

/// A received web document (HTML/SVG) staged for the in-app `HtmlWebView` viewer: the
/// markup to render plus the raw file on disk, so the reader can still Share/save it (the
/// affordance QuickLook used to offer).
struct GramWebDoc: Identifiable {
    let id = UUID()
    let title: String
    let html: String
    let fileURL: URL
}

/// What opening a Gram file shows: QuickLook on a file, or the in-app viewer on a web
/// document. Owner and guest pages hold one and draw it with `gramFileViewer`.
enum GramPreview {
    case quickLook(URL)
    case web(GramWebDoc)

    /// The file on disk the viewer shows: a temp file, or a download cache entry.
    var fileURL: URL {
        switch self {
        case .quickLook(let url): return url
        case .web(let doc): return doc.fileURL
        }
    }
}

/// Which viewer a received file opens in, and the files it needs on disk. Shared by the
/// owner's Gram (cache hit and fresh download alike) and the guest's, so every page renders a
/// markdown or web document identically.
enum GramPreviewRouter {
    /// Temp files go in a directory of their own per open, under this prefix, so two files with
    /// one name never collide and `discard` removes the open's directory whole.
    private static let tempPrefix = "gram-preview-"

    /// A file we should render as formatted HTML (a markdown source), by extension
    /// or advisory mime.
    static func isMarkdown(name: String, mime: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
            || mime.lowercased() == "text/markdown"
    }

    /// The markdown file's name without its `.md`/`.markdown` extension, for the
    /// preview title.
    static func displayTitle(_ name: String) -> String {
        let base = GramStaging.safeFileName(name)
        for ext in [".markdown", ".md"] where base.lowercased().hasSuffix(ext) {
            return String(base.dropLast(ext.count))
        }
        return base
    }

    /// The temp file name for a rendered markdown preview — a `.html` extension so
    /// QuickLook renders it as a web page, not source.
    static func previewHTMLName(for name: String) -> String {
        displayTitle(name) + ".html"
    }

    /// A received web document that QuickLook would otherwise render as live,
    /// scriptable content — routed to the in-app `HtmlWebView` viewer instead.
    static func isWebDocument(name: String, mime: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasSuffix(".html") || lower.hasSuffix(".htm") || lower.hasSuffix(".xhtml")
            || lower.hasSuffix(".svg")
        {
            return true
        }
        let m = mime.lowercased()
        return m == "text/html" || m == "application/xhtml+xml" || m == "image/svg+xml"
    }

    /// The web file's name without its extension, for the preview title.
    static func webBaseName(_ name: String) -> String {
        let base = GramStaging.safeFileName(name)
        for ext in [".xhtml", ".html", ".htm", ".svg"] where base.lowercased().hasSuffix(ext) {
            return String(base.dropLast(ext.count))
        }
        return base
    }

    /// Whether opening the file needs its bytes in memory (a markdown or web document is
    /// rendered from them). QuickLook takes any other file by URL, so a cached video is never
    /// read into memory on the main actor only to be discarded.
    static func needsBytes(name: String, mime: String) -> Bool {
        isMarkdown(name: name, mime: mime) || isWebDocument(name: name, mime: mime)
    }

    /// Route already-held bytes to the right viewer.
    ///
    /// `cachedAt` is the download cache entry for the ORIGINAL bytes when one exists. QuickLook
    /// and the web viewer are handed that file directly, so nothing is re-written per open;
    /// derived artifacts (markdown rendered to HTML) still go to a temp file, because what the
    /// cache holds is the source, not the rendering. `data` may be nil only when `cachedAt` is
    /// set and the file opens in QuickLook (`needsBytes` is false).
    static func preview(data: Data?, name: String, mime: String, cachedAt: URL?) throws -> GramPreview {
        if isMarkdown(name: name, mime: mime), let data, let text = String(data: data, encoding: .utf8) {
            // Render markdown to styled HTML so it previews FORMATTED — QuickLook shows a raw
            // .md file as plain source otherwise.
            let html = Markdown.toStyledHTML(text, title: displayTitle(name))
            return .quickLook(try writeTemp(Data(html.utf8), named: previewHTMLName(for: name)))
        }
        if isWebDocument(name: name, mime: mime), let data {
            // Received HTML/SVG renders in a dedicated in-app WKWebView viewer (no remote loads,
            // script off by default), NOT QuickLook — the old srcdoc-sandbox path painted a blank
            // white screen (#92). Decode LOSSILY (invalid UTF-8 -> U+FFFD) so a non-UTF-8 file
            // still renders as text rather than being treated as a plain download. Keep the raw
            // bytes on disk so the viewer's Share button can save the original.
            let raw = try cachedAt ?? writeTemp(data, named: name)
            return .web(GramWebDoc(title: webBaseName(name), html: String(decoding: data, as: UTF8.self),
                                   fileURL: raw))
        }
        // The cache entry IS the file, under its real name: hand it straight to QuickLook
        // rather than copying it into tmp on every open.
        if let cachedAt { return .quickLook(cachedAt) }
        return .quickLook(try writeTemp(data ?? Data(), named: name))
    }

    /// Remove a closed or replaced preview's TEMP file (and its per-open directory), so a viewed
    /// secret does not linger in tmp.
    ///
    /// CACHED FILES ARE NOT TEMP FILES (#451). A downloaded gram file lives under
    /// `GramView.Downloads.root` so reopening it costs nothing, and a cache hit hands the viewer
    /// the cache entry itself; deleting it would re-download on the next open and quietly undo
    /// the cache. Only paths outside that root are unlinked.
    static func discard(_ url: URL) {
        guard !GramView.Downloads.isCached(url) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir.lastPathComponent.hasPrefix(tempPrefix) ? dir : url)
    }

    /// Write bytes to a fresh per-open temp directory, encrypted at rest. The server's name is
    /// never trusted as a path component: it is reduced to a bare basename.
    private static func writeTemp(_ data: Data, named name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(tempPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(GramStaging.safeFileName(name))
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

extension View {
    /// Shows `preview` in its viewer — QuickLook, whose share button saves or sends the file,
    /// or the in-app web viewer — and removes its temp file once it closes, is replaced, or the
    /// page goes away. Never a download cache entry (`GramPreviewRouter.discard`).
    func gramFileViewer(_ preview: Binding<GramPreview?>) -> some View {
        modifier(GramFileViewer(preview: preview))
    }
}

/// The file viewer of every Gram page (see `gramFileViewer`).
struct GramFileViewer: ViewModifier {
    @Binding var preview: GramPreview?
    /// Whether a received html/svg preview may run script (Settings → HTML previews).
    /// Off unless the reader turned it on; read here so the viewer is built with it.
    @AppStorage(WebViewPolicy.javaScriptDefaultsKey) private var previewJavaScript = false

    private var quickLookURL: Binding<URL?> {
        Binding(
            get: {
                guard case .quickLook(let url) = preview else { return nil }
                return url
            },
            // QuickLook nils it on dismiss. Only a QuickLook preview is cleared: by the time a
            // replaced QuickLook reports its dismissal, `preview` may already be a web document.
            set: { url in
                if url == nil, case .quickLook = preview { preview = nil }
            }
        )
    }

    private var webDoc: Binding<GramWebDoc?> {
        Binding(
            get: {
                guard case .web(let doc) = preview else { return nil }
                return doc
            },
            set: { doc in
                if doc == nil, case .web = preview { preview = nil }
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .quickLookPreview(quickLookURL)
            // Received HTML/SVG opens in a dedicated in-app viewer (no remote loads, navigation
            // frozen, and script off unless the reader turned it on in Settings) rather than
            // QuickLook, which rendered these blank (#92). Done dismisses; Share still lets the
            // reader save the raw file.
            .fullScreenCover(item: webDoc) { doc in
                NavigationStack {
                    HtmlWebView(html: doc.html, allowsJavaScript: previewJavaScript)
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle(doc.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { webDoc.wrappedValue = nil }
                            }
                            ToolbarItem(placement: .primaryAction) {
                                ShareLink(item: doc.fileURL)
                            }
                        }
                }
                .onDisappear { GramPreviewRouter.discard(doc.fileURL) }
            }
            // Remove the previous preview's temp file whenever it changes, including → nil on
            // dismiss.
            .onChange(of: preview?.fileURL) { oldValue, newValue in
                if let oldValue, oldValue != newValue { GramPreviewRouter.discard(oldValue) }
            }
            // Backstop: the page went away with a preview still set.
            .onDisappear {
                if let url = preview?.fileURL { GramPreviewRouter.discard(url) }
            }
    }
}
