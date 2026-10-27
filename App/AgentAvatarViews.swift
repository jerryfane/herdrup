import ImageIO
import Observation
import PhotosUI
import SwiftUI
import UIKit
import HerdrKit

// Agent profile pictures (herdrup#538): one bundled mascot or one photo per agent, stored on
// the herdr server keyed by the agent's terminal id, so every owner device and every guest
// of the agent sees the same picture. An agent with no choice shows its initial tile.

// MARK: - Directory

/// What every avatar on screen draws from: the roster (so a Gram sender's name finds its
/// agent), this device's pending changes, the decoded photos, and whether this connection
/// may edit. One per connected home (the owner's `TerminalHomeView`, a guest's
/// `GuestHomeView`), handed down through the environment; a view without one draws the
/// initial tile.
@Observable
final class AgentAvatarDirectory {
    /// Fetches photo bytes (`agent.avatar.get`) and saves changes (`agent.avatar.set`).
    var client: HerdrClient?
    /// The owner, on a server that advertises `agent_avatar`. False for guests and older
    /// servers: the Avatar… entry points are hidden and nothing can be set.
    var canEdit = false
    private(set) var agents: [AgentInfo] = []
    private var pending: [String: AgentAvatarPendingChange] = [:]
    /// Bumped when a photo finishes loading or fails, so views waiting on it redraw.
    private(set) var imageRevision = 0

    private let cache: AgentAvatarImageCache
    @ObservationIgnored private var decoded: [String: UIImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var failed: Set<String> = []

    init(cache: AgentAvatarImageCache = .shared) {
        self.cache = cache
    }

    /// The roster changed: keep it for lookups, and drop pending changes it now reflects.
    func update(agents next: [AgentInfo]) {
        if next != agents { agents = next }
        settlePending()
    }

    /// The agent's avatar as this device should show it: a pending change of ours, else
    /// what the server reported. The roster copy is preferred over `info`, which may be a
    /// snapshot taken when a pane was opened.
    func descriptor(for info: AgentInfo) -> AgentAvatarDescriptor? {
        let key = info.avatarKey
        if let change = pending[key] { return change.descriptor }
        return latest(info).avatar
    }

    func latest(_ info: AgentInfo) -> AgentInfo {
        agents.first { $0.avatarKey == info.avatarKey } ?? info
    }

    func agent(forGramSender from: String) -> AgentInfo? {
        AgentAvatarLookup.agent(forGramSender: from, in: agents)
    }

    // MARK: photos

    enum PhotoState { case ready(UIImage), loading, failed }

    /// The photo for `sha256`: decoded already, on disk from an earlier launch, or not yet.
    /// Reads `imageRevision` so a view that asked before the bytes arrived redraws after.
    func photo(_ sha256: String) -> PhotoState {
        _ = imageRevision
        if let image = decoded[sha256] { return .ready(image) }
        if failed.contains(sha256) { return .failed }
        if let data = cache.data(for: sha256), let image = UIImage(data: data) {
            decoded[sha256] = image
            return .ready(image)
        }
        return .loading
    }

    /// Fetches a photo not cached yet. Content-addressed, so each one crosses the wire once.
    @MainActor
    func load(_ sha256: String, target: String) async {
        guard case .loading = photo(sha256), let client, loading.insert(sha256).inserted else { return }
        defer { loading.remove(sha256) }
        do {
            let image = try await client.agentAvatarGet(target: target, sha256: sha256)
            if cache.store(image.data, sha256: sha256), let decodedImage = UIImage(data: image.data) {
                decoded[sha256] = decodedImage
            } else {
                failed.insert(sha256)
            }
        } catch is CancellationError {
            return
        } catch {
            failed.insert(sha256)
        }
        imageRevision += 1
    }

    // MARK: editing

    /// Sets (nil: clears) `info`'s avatar. The change shows at once and stays until the
    /// roster reports it; a failure restores what was there and rethrows.
    @MainActor
    func set(_ choice: AgentAvatarChoice?, for info: AgentInfo) async throws {
        guard let client else { throw AgentAvatarError.unsupported }
        let key = info.avatarKey
        let before = pending[key]
        let replaced = descriptor(for: info)
        let optimistic: AgentAvatarDescriptor?
        switch choice {
        case nil:
            optimistic = nil
        case .mascot(let id)?:
            optimistic = AgentAvatarDescriptor(style: .mascot, mascot: id)
        case .image(let data, _)?:
            let sha256 = AgentAvatarImage.sha256(of: data)
            if cache.store(data, sha256: sha256), let image = UIImage(data: data) {
                decoded[sha256] = image
                failed.remove(sha256)
            }
            optimistic = AgentAvatarDescriptor(style: .image, sha256: sha256)
        }
        pending[key] = AgentAvatarPendingChange(descriptor: optimistic, inFlight: true,
                                                replacedUpdatedUnixMs: replaced?.updatedUnixMs)
        do {
            let stored = try await client.agentAvatarSet(target: info.avatarTarget, choice: choice)
            pending[key] = AgentAvatarPendingChange(descriptor: stored, inFlight: false,
                                                    replacedUpdatedUnixMs: replaced?.updatedUnixMs)
            settlePending()
        } catch {
            pending[key] = before
            throw error
        }
    }

    private func settlePending() {
        for (key, change) in pending {
            guard let reported = agents.first(where: { $0.avatarKey == key }) else { continue }
            if change.isSettled(by: reported.avatar) { pending[key] = nil }
        }
    }
}

// MARK: - Avatar

/// One agent's round picture, everywhere an agent is shown: the roster and sidebar, the
/// archived rows, a guest's home, the guest accept card, and Gram's bubbles, stacks and
/// pickers. Photo (cached, fetched by content address) → mascot → the initial tile. The
/// initial tile is also what a mascot this build does not ship and a photo that fails to
/// load fall back to.
struct AgentAvatarView: View {
    private enum Source {
        case agent(AgentInfo?)
        case gramSender(String)
    }

    private let source: Source
    private let name: String
    let size: CGFloat
    private let glyphSize: CGFloat?
    @Environment(AgentAvatarDirectory.self) private var directory: AgentAvatarDirectory?

    /// A known agent (or nil: the default). `name` drives only the initial tile.
    init(agent: AgentInfo?, name: String, size: CGFloat, glyphSize: CGFloat? = nil) {
        source = .agent(agent)
        self.name = name
        self.size = size
        self.glyphSize = glyphSize
    }

    /// A Gram sender, by its routing name; resolved through the roster.
    init(gramSender: String, size: CGFloat) {
        source = .gramSender(gramSender)
        name = GramMessage.agentName(from: gramSender)
        self.size = size
        // Gram's initial was a touch larger than a row's before pictures (herdrup#538).
        glyphSize = (size * 0.45).rounded()
    }

    private var agent: AgentInfo? {
        switch source {
        case .agent(let info): return info
        case .gramSender(let from): return directory?.agent(forGramSender: from)
        }
    }

    var body: some View {
        let agent = agent
        let descriptor = agent.flatMap { info in directory.map { $0.descriptor(for: info) } ?? info.avatar }
        let appearance = AgentAvatarAppearance.resolve(descriptor)
        let (face, identifier, label) = render(appearance)
        return face
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityIdentifier("agent-avatar-\(identifier)")
            .task(id: appearance) {
                guard case .image(let sha256) = appearance, let target = agent?.avatarTarget else { return }
                await directory?.load(sha256, target: target)
            }
    }

    private func render(_ appearance: AgentAvatarAppearance) -> (AnyView, String, String) {
        switch appearance {
        case .initial, .unknownMascot:
            return initialFace(appearance.identifierSuffix)
        case .mascot(let mascot):
            let asset = AgentMascotArt.assetName(mascot)
            guard UIImage(named: asset) != nil else { return initialFace(AgentAvatarAppearance.initial.identifierSuffix) }
            return (AnyView(Image(asset).resizable().interpolation(.high).aspectRatio(contentMode: .fit)),
                    appearance.identifierSuffix, mascot.displayName)
        case .image(let sha256):
            switch directory?.photo(sha256) ?? .failed {
            case .ready(let image):
                return (AnyView(Image(uiImage: image).resizable().interpolation(.high).scaledToFill()
                    .overlay(Circle().stroke(Palette.hairline, lineWidth: 1))), appearance.identifierSuffix, "Photo")
            case .loading:
                return (AnyView(Circle().fill(Palette.surfaceRaised)), "loading", "Photo")
            case .failed:
                return initialFace(AgentAvatarAppearance.initial.identifierSuffix)
            }
        }
    }

    private func initialFace(_ identifier: String) -> (AnyView, String, String) {
        (AnyView(AgentInitialTile(name: name, size: size, glyphSize: glyphSize)),
         identifier, AgentInitialTile.label(for: name))
    }
}

/// The default avatar: the name's initial on its identity gradient, the look every agent
/// had before mascots (herdrup#538). Also the picker's "Use default" option.
struct AgentInitialTile: View {
    let name: String
    let size: CGFloat
    var glyphSize: CGFloat? = nil

    /// What VoiceOver reads for the tile, e.g. "Initial J".
    static func label(for name: String) -> String { "Initial \(AgentIdentity.glyph(forName: name))" }

    var body: some View {
        Circle().fill(AgentIdentity.gradient(forName: name))
            .overlay(Text(AgentIdentity.glyph(forName: name))
                .font(Typography.app(glyphSize ?? (size * 0.42).rounded(), .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5))
            .frame(width: size, height: size)
    }
}

/// The asset catalog names of the bundled mascots (Tools/mascots/generate-mascots.py).
enum AgentMascotArt {
    static func assetName(_ mascot: AgentMascot) -> String { "Mascot-\(mascot.rawValue)" }
}

// MARK: - Editing

/// Opens the avatar sheet; owner only, on a server that supports avatars.
struct AgentAvatarMenuButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label("Avatar…", systemImage: "person.crop.circle") }
            .accessibilityIdentifier("agent-avatar-edit")
    }
}

/// The avatar sheet: the default (the agent's initial tile), the twelve mascots, and a photo
/// from the library cropped to a circle. Every choice applies at once and is shared with the
/// owner's other devices and the agent's guests.
struct AgentAvatarSheet: View {
    let agent: AgentInfo
    let name: String
    var badge: AgentAvatarBadge = .none
    var badgeLabel: String = ""

    @Environment(AgentAvatarDirectory.self) private var directory: AgentAvatarDirectory?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var showingPicker = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var cropping: AgentAvatarCropSource?
    @State private var loadingPhoto = false

    private var current: AgentAvatarAppearance {
        AgentAvatarAppearance.resolve(directory.map { $0.descriptor(for: agent) } ?? agent.avatar)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    AgentAvatar(name: name, badge: badge, badgeLabel: badgeLabel, diameter: 96,
                                glyphSize: 40, info: agent)
                        .padding(.top, 12)
                    mascotGrid
                    actions
                    if let error {
                        Text(error)
                            .font(Typography.app(13.5)).foregroundStyle(Palette.died)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("agent-avatar-error")
                    }
                    Text("Guests you share this agent with will see this picture.")
                        .font(Typography.app(13)).foregroundStyle(Palette.textFaint)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
            .background(Palette.ground.ignoresSafeArea())
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("agent-avatar-done")
                }
            }
            .navigationDestination(item: $cropping) { source in
                AgentAvatarCropView(source: source, name: name, badge: badge, badgeLabel: badgeLabel) { data in
                    cropping = nil
                    apply(.image(data: data, mime: "image/jpeg"))
                }
            }
        }
        .photosPicker(isPresented: $showingPicker, selection: $pickedItem, matching: .images)
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            pickedItem = nil
            Task { await load(item) }
        }
        .presentationDetents([.large])
    }

    private var mascotGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 12)], spacing: 14) {
            // "Use default": clears the choice, back to the agent's own initial tile.
            choiceCell(label: "Use default", accessibilityLabel: "Use default, \(AgentInitialTile.label(for: name))",
                       selected: current == .initial, identifier: "agent-avatar-use-default") {
                apply(nil)
            } face: {
                AgentInitialTile(name: name, size: 56, glyphSize: 24)
            }
            ForEach(AgentMascot.allCases) { mascot in
                choiceCell(label: mascot.displayName, accessibilityLabel: mascot.displayName,
                           selected: current == .mascot(mascot),
                           identifier: "agent-avatar-choice-\(mascot.rawValue)") {
                    apply(.bundled(mascot))
                } face: {
                    Image(AgentMascotArt.assetName(mascot)).resizable().interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                }
            }
        }
    }

    private func choiceCell(label: String, accessibilityLabel: String, selected: Bool, identifier: String,
                            action: @escaping () -> Void,
                            @ViewBuilder face: () -> some View) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                face()
                    .padding(3)
                    .overlay(Circle().stroke(selected ? Palette.text : .clear, lineWidth: 2.5))
                Text(label)
                    .font(Typography.app(11.5)).foregroundStyle(Palette.textDim)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button { showingPicker = true } label: {
                HStack(spacing: 8) {
                    if loadingPhoto { ProgressView().tint(Palette.textDim) }
                    else { Image(systemName: "photo.on.rectangle") }
                    Text("Choose photo")
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.text)
            .disabled(loadingPhoto)
            .accessibilityIdentifier("agent-avatar-choose-photo")

            if case .image = current {
                Button { apply(nil) } label: {
                    Text("Remove photo").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textDim)
                .accessibilityIdentifier("agent-avatar-remove-photo")
            }
        }
        .font(Typography.app(15, .semibold))
    }

    private func apply(_ choice: AgentAvatarChoice?) {
        error = nil
        Task { @MainActor in
            do {
                try await directory?.set(choice, for: agent)
            } catch {
                self.error = "Couldn't change the picture: \(AgentAvatarSheet.describe(error))"
            }
        }
    }

    private func load(_ item: PhotosPickerItem) async {
        loadingPhoto = true
        defer { loadingPhoto = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = AgentAvatarPhoto.downsampled(data) else {
            error = "That photo couldn't be read."
            return
        }
        error = nil
        cropping = AgentAvatarCropSource(image: image)
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? AgentAvatarError, error == .unsupported {
            return "this server doesn't support agent pictures."
        }
        if let error = error as? APIError {
            switch error.code {
            case "avatar_too_large": return "the photo is too large."
            case "invalid_avatar": return "the server refused it."
            default: return error.message
            }
        }
        return error.localizedDescription
    }
}

/// A picked photo, downsampled and upright, ready to crop.
struct AgentAvatarCropSource: Identifiable, Hashable {
    let id = UUID()
    let image: UIImage

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The square crop: drag to move, pinch to zoom, with the circle the avatar will show and a
/// live preview carrying the agent's status badge.
struct AgentAvatarCropView: View {
    let source: AgentAvatarCropSource
    let name: String
    let badge: AgentAvatarBadge
    let badgeLabel: String
    let onUse: (Data) -> Void

    @State private var zoom: Double = 1
    @State private var offset = CGPoint.zero
    @State private var gestureZoom: Double = 1
    @State private var gestureStart: CGPoint?
    @State private var failed = false

    private let viewport: CGFloat = 280

    var body: some View {
        let cropped = AgentAvatarPhoto.crop(source.image, zoom: zoom * gestureZoom, offset: offset)
        ScrollView {
            VStack(spacing: 20) {
                ZStack {
                    if let cropped {
                        Image(uiImage: cropped).resizable().interpolation(.high)
                            .frame(width: viewport, height: viewport)
                    }
                    // Dim outside the circle the avatar shows.
                    Rectangle().fill(Color.black.opacity(0.5))
                        .mask(Rectangle().overlay(Circle().blendMode(.destinationOut)).compositingGroup())
                        .allowsHitTesting(false)
                    Circle().stroke(Color.white.opacity(0.8), lineWidth: 1).allowsHitTesting(false)
                }
                .frame(width: viewport, height: viewport)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
                .gesture(drag.simultaneously(with: pinch))
                .accessibilityIdentifier("agent-avatar-crop")

                HStack(spacing: 16) {
                    AgentAvatar(name: name, badge: badge, badgeLabel: badgeLabel, diameter: 72,
                                glyphSize: 30, preview: cropped)
                    AgentAvatar(name: name, badge: badge, badgeLabel: badgeLabel, diameter: 44,
                                glyphSize: 19, preview: cropped)
                }

                if failed {
                    Text("That photo couldn't be made small enough.")
                        .font(Typography.app(13.5)).foregroundStyle(Palette.died)
                }
                Text("Drag to move, pinch to zoom.")
                    .font(Typography.app(13)).foregroundStyle(Palette.textFaint)
            }
            .padding(.top, 16).frame(maxWidth: .infinity)
        }
        .background(Palette.ground.ignoresSafeArea())
        .navigationTitle("Move and scale")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Use photo") {
                    guard let data = AgentAvatarPhoto.normalised(source.image, zoom: zoom, offset: offset) else {
                        failed = true
                        return
                    }
                    onUse(data)
                }
                .accessibilityIdentifier("agent-avatar-use-photo")
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = gestureStart ?? offset
                if gestureStart == nil { gestureStart = start }
                offset = AgentAvatarPhoto.offset(start, dragging: value.translation, viewport: viewport,
                                                 image: source.image.size, zoom: zoom)
            }
            .onEnded { _ in gestureStart = nil }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in gestureZoom = value.magnification }
            .onEnded { value in
                zoom = min(max(zoom * value.magnification, 1), 6)
                gestureZoom = 1
            }
    }
}

/// The photo pipeline. Geometry, the byte cap and the quality ladder are HerdrKit's
/// `AgentAvatarImage` (unit-tested on Linux); this is the UIKit half.
enum AgentAvatarPhoto {
    /// The longest edge a picked photo is decoded at: plenty for a 256 px crop at 4x zoom.
    static let workingEdge: CGFloat = 1600

    /// Decodes `data` small and upright (EXIF orientation applied), never at full size.
    static func downsampled(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: workingEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    static func cropRect(_ image: UIImage, zoom: Double, offset: CGPoint) -> CGRect {
        let size = image.size
        let rect = AgentAvatarImage.cropRect(imageWidth: size.width * image.scale, imageHeight: size.height * image.scale,
                                             zoom: zoom, offsetX: offset.x, offsetY: offset.y)
        return CGRect(x: rect.x, y: rect.y, width: rect.side, height: rect.side).integral
    }

    static func crop(_ image: UIImage, zoom: Double, offset: CGPoint) -> UIImage? {
        guard let cg = image.cgImage?.cropping(to: cropRect(image, zoom: zoom, offset: offset)) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// A drag of `translation` points over the viewport, as a new normalised offset.
    static func offset(_ start: CGPoint, dragging translation: CGSize, viewport: CGFloat,
                       image: CGSize, zoom: Double) -> CGPoint {
        let side = min(image.width, image.height) / max(zoom, 1)
        let pixelsPerPoint = side / viewport
        let travelX = (image.width - side) / 2
        let travelY = (image.height - side) / 2
        // Dragging the picture right shows more of its left: the crop moves the other way.
        let dx = travelX > 0 ? -translation.width * pixelsPerPoint / travelX : 0
        let dy = travelY > 0 ? -translation.height * pixelsPerPoint / travelY : 0
        return CGPoint(x: min(max(start.x + dx, -1), 1), y: min(max(start.y + dy, -1), 1))
    }

    /// The upload: the crop drawn at 256×256 (opaque, so no alpha), JPEG-encoded at the
    /// first quality along the ladder that fits 64 KiB. Re-encoding from pixels carries no
    /// EXIF, GPS or other metadata from the original.
    static func normalised(_ image: UIImage, zoom: Double, offset: CGPoint) -> Data? {
        guard let cropped = crop(image, zoom: zoom, offset: offset) else { return nil }
        let edge = CGFloat(AgentAvatarImage.pixelSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge), format: format).image { _ in
            cropped.draw(in: CGRect(x: 0, y: 0, width: edge, height: edge))
        }
        return AgentAvatarImage.encodeWithinLimit { rendered.jpegData(compressionQuality: $0) }
    }
}
