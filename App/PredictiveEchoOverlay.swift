import CoreText
import Foundation
import HerdrKit
import SwiftTerm
import UIKit

/// Settings › Typing › Instant typing, stored as a `PredictionEngine.Mode` raw value.
enum PredictiveEchoSetting {
    static let key = "predictiveEcho"
    static let defaultValue = PredictionEngine.Mode.auto.rawValue

    static func mode(_ raw: String) -> PredictionEngine.Mode {
        PredictionEngine.Mode(rawValue: raw) ?? .auto
    }
}

/// SwiftTerm's LIVE screen as `PredictionEngine` sees it. Read-only: nothing here writes
/// to the emulator. Only meaningful while the view shows the live screen (the controller
/// checks `liveCellRect` first); `getCharData` and the cursor are both relative to it then.
struct TerminalPredictionScreen: PredictionScreen {
    let terminal: SwiftTerm.Terminal

    var columns: Int { terminal.cols }
    var rows: Int { terminal.rows }

    var cursor: (col: Int, row: Int) {
        let location = terminal.getCursorLocation()
        return (location.x, location.y)
    }

    func text(col: Int, row: Int) -> String {
        guard let data = terminal.getCharData(col: col, row: row) else { return "" }
        let character = terminal.getCharacter(for: data)
        return character == "\u{0}" ? "" : String(character)
    }
}

/// Draws predicted characters and the predicted caret over the terminal. A subview of
/// the `TerminalView` (a scroll view), positioned in its content coordinates exactly
/// where SwiftTerm draws the live screen, so it moves with the content like the caret.
/// Never interactive; a wrong guess is removed by redrawing this view, never by
/// touching the emulator.
final class PredictiveEchoOverlayView: UIView {
    struct Glyph {
        /// In this view's coordinates.
        let rect: CGRect
        /// nil: only underline what the cell already shows.
        let text: String?
        let underlined: Bool
    }

    struct Caret {
        let rect: CGRect
        let style: CursorStyle
        /// The character under a block caret.
        let glyph: String
        let focused: Bool
    }

    private(set) var glyphs: [Glyph] = []
    private(set) var caret: Caret?
    weak var terminalView: TerminalView?
    /// After every draw that put something on screen.
    var onDraw: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ glyphs: [Glyph], caret: Caret?, frame: CGRect) {
        if self.frame != frame { self.frame = frame }
        self.glyphs = glyphs
        self.caret = caret
        isHidden = glyphs.isEmpty && caret == nil
        setNeedsDisplay()
    }

    func clear() {
        guard !glyphs.isEmpty || caret != nil else { return }
        glyphs = []
        caret = nil
        isHidden = true
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let terminal = terminalView, let context = UIGraphicsGetCurrentContext(),
              !glyphs.isEmpty || caret != nil else { return }
        let font = terminal.font as CTFont
        // SwiftTerm's baseline: `drawTerminalContents` puts it ceil(descent + leading)
        // above the bottom of the cell.
        let baseline = ceil(CTFontGetDescent(font) + CTFontGetLeading(font))
        let underlineOffset = CTFontGetUnderlinePosition(font)
        let underlineThickness = max(1, CTFontGetUnderlineThickness(font))
        let foreground = terminal.nativeForegroundColor
        let background = Self.opaqueBackground(of: terminal)

        for glyph in glyphs {
            if let text = glyph.text {
                context.setFillColor(background.cgColor)
                context.fill(glyph.rect)
                draw(text, in: glyph.rect, font: font, baseline: baseline, color: foreground, context: context)
            }
            if glyph.underlined {
                let y = glyph.rect.maxY - baseline - underlineOffset
                context.setFillColor(foreground.cgColor)
                context.fill(CGRect(x: glyph.rect.minX, y: y, width: glyph.rect.width, height: underlineThickness))
            }
        }

        if let caret {
            let color = terminal.caretColor
            if !caret.focused {
                // CaretView's unfocused caret: an outline.
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(3)
                context.stroke(caret.rect)
            } else {
                context.setFillColor(color.cgColor)
                switch caret.style {
                case .blinkBar, .steadyBar:
                    context.fill(CGRect(x: caret.rect.minX, y: caret.rect.minY, width: 2, height: caret.rect.height))
                case .blinkUnderline, .steadyUnderline:
                    context.fill(CGRect(x: caret.rect.minX, y: caret.rect.maxY - 2, width: caret.rect.width, height: 2))
                case .blinkBlock, .steadyBlock:
                    context.fill(caret.rect)
                    draw(caret.glyph, in: caret.rect, font: font, baseline: baseline,
                         color: terminal.caretTextColor ?? foreground, context: context)
                }
            }
        }
        onDraw?()
    }

    private func draw(_ text: String, in rect: CGRect, font: CTFont, baseline: CGFloat,
                      color: UIColor, context: CGContext) {
        guard !text.isEmpty, text != " " else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.saveGState()
        context.clip(to: rect)
        context.setFillColor(color.cgColor)
        context.textMatrix = .identity
        context.translateBy(x: rect.minX, y: rect.maxY - baseline)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// The colour a blank cell is painted with. SwiftTerm can move its own background
    /// to the layer and clear `nativeBackgroundColor`; the overlay must stay opaque.
    private static func opaqueBackground(of terminal: TerminalView) -> UIColor {
        if terminal.nativeBackgroundColor.cgColor.alpha > 0 { return terminal.nativeBackgroundColor }
        return terminal.backgroundColor ?? .black
    }
}

/// Instant typing for one pane: owns its `PredictionEngine`, feeds it the keys, acks and
/// output the `Coordinator` sees, and draws `PredictionEngine.overlay` over the terminal.
///
/// Main thread only (the Coordinator's callbacks). Every hook is a no-op while the mode
/// is Off, and nothing here writes to the emulator: the only effects are the overlay
/// subview and hiding SwiftTerm's caret while a predicted one is drawn.
final class PredictiveEchoController {
    private let engine = PredictionEngine()
    private weak var view: TerminalView?
    private let overlayView = PredictiveEchoOverlayView()
    private var lastAlternate: Bool?
    private var outputDeferred = false
    private var tickTask: Task<Void, Never>?
    /// Keys put in the overlay and not yet painted.
    private var unpainted: [PredictionEngine.FirstPaint] = []
    private var reportedConfirmed = 0
    private var reportedWrong = 0
    private static let tickInterval: UInt64 = 40_000_000

    var mode: PredictionEngine.Mode { engine.mode }

    init() {
        overlayView.onDraw = { [weak self] in self?.overlayDrawn() }
    }

    func attach(to view: TerminalView) {
        self.view = view
        overlayView.terminalView = view
        overlayView.isHidden = true
        view.addSubview(overlayView)
    }

    /// The pane stopped: nothing is predicted again.
    func detach() {
        reset()
        engine.setMode(.off)
        overlayView.removeFromSuperview()
        view = nil
    }

    func setMode(_ mode: PredictionEngine.Mode) {
        guard mode != engine.mode else { return }
        engine.setMode(mode)
        if mode == .off { reset() }
    }

    /// Keys about to go out as `batch` (`PaneInputSender.enqueue`'s number). `allowed`:
    /// the screen on display is the one the keys act on (no retained frame over it).
    func userBytes(_ bytes: [UInt8], batch: UInt64, allowed: Bool) {
        guard engine.mode != .off, batch > 0, let screen = liveScreen() else { return }
        guard allowed else {
            reset()
            return
        }
        engine.userBytes(bytes, screen: screen, batch: batch)
        sync()
    }

    /// `PaneInputSender.onAcked`.
    func batchAcked(_ through: UInt64, failed: Bool) {
        guard engine.mode != .off else { return }
        engine.batchAcked(through, failed: failed, screen: liveScreen())
        sync()
    }

    /// A stream frame was fed to the emulator.
    func outputArrived() {
        guard engine.mode != .off, let terminal = view?.getTerminal() else { return }
        // Mid DEC 2026 batch the buffer holds a half-drawn frame SwiftTerm does not
        // paint; judge the screen once the batch ends.
        if terminal.synchronizedOutputActive {
            outputDeferred = true
            return
        }
        outputDeferred = false
        guard let screen = liveScreen() else { return }
        engine.outputArrived(screen: screen)
        sync()
    }

    func synchronizedOutputEnded() {
        guard outputDeferred else { return }
        outputArrived()
    }

    /// The scroll position moved: predictions stand only on the live screen.
    func viewScrolled() {
        guard engine.hasPredictions || !overlayView.isHidden else { return }
        _ = liveScreen()
    }

    /// Forget every prediction: the screen they were made on is gone or covered (resize,
    /// font change, keyframe, a retained frame, the pane left the front, input that did
    /// not come through `userBytes`).
    func reset() {
        engine.reset()
        tickTask?.cancel()
        tickTask = nil
        outputDeferred = false
        unpainted.removeAll()
        overlayView.clear()
        view?.caretSuppressed = false
    }

    /// The live screen, or nil (after a reset) when the view is not showing it: the
    /// reader scrolled into history, or the alternate screen was switched since.
    private func liveScreen() -> PredictionScreen? {
        guard let view, view.liveCellRect(col: 0, row: 0) != nil else {
            if engine.hasPredictions || !overlayView.isHidden { reset() }
            return nil
        }
        let terminal = view.getTerminal()
        let alternate = terminal.isCurrentBufferAlternate
        if let lastAlternate, lastAlternate != alternate { reset() }
        lastAlternate = alternate
        return TerminalPredictionScreen(terminal: terminal)
    }

    private func sync() {
        let confirmed = engine.confirmed - reportedConfirmed
        let wrong = engine.wrong - reportedWrong
        reportedConfirmed = engine.confirmed
        reportedWrong = engine.wrong
        TypingLatencyRecorder.shared.notePredictions(confirmed: confirmed, wrong: wrong)
        unpainted.append(contentsOf: engine.takeFirstPaints())
        redraw()
        scheduleTick()
    }

    private func redraw() {
        guard let view else { return }
        let overlay = engine.overlay
        let terminal = view.getTerminal()
        guard !overlay.isEmpty, let origin = view.liveCellRect(col: 0, row: 0)?.origin else {
            unpainted.removeAll()
            overlayView.clear()
            view.caretSuppressed = false
            return
        }
        let cell = view.cellSize
        let frame = CGRect(origin: origin, size: CGSize(width: cell.width * CGFloat(terminal.cols),
                                                        height: cell.height * CGFloat(terminal.rows)))
        func local(_ col: Int, _ row: Int) -> CGRect? {
            view.liveCellRect(col: col, row: row)?.offsetBy(dx: -origin.x, dy: -origin.y)
        }
        let glyphs = overlay.cells.compactMap { cell -> PredictiveEchoOverlayView.Glyph? in
            guard let rect = local(cell.col, cell.row) else { return nil }
            return .init(rect: rect, text: cell.text, underlined: cell.underlined)
        }
        var caret: PredictiveEchoOverlayView.Caret?
        // Only where SwiftTerm itself would show a caret (the application has not hidden it).
        if let position = overlay.cursor, view.isCaretShown, let rect = local(position.col, position.row) {
            let under = overlay.cells.first { $0.col == position.col && $0.row == position.row }?.text
                ?? TerminalPredictionScreen(terminal: terminal).text(col: position.col, row: position.row)
            caret = .init(rect: rect, style: terminal.options.cursorStyle, glyph: under,
                          focused: view.isFirstResponder)
        }
        view.caretSuppressed = caret != nil
        overlayView.show(glyphs, caret: caret, frame: frame)
        if view.subviews.last !== overlayView { view.bringSubviewToFront(overlayView) }
    }

    private func overlayDrawn() {
        guard !unpainted.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for key in unpainted {
            TypingLatencyRecorder.shared.predictionPainted(keyToPrediction: max(0, now - key.pressedAt))
        }
        unpainted.removeAll()
    }

    /// Acked batches with no output are checked by time; so is the glitch rule.
    private func scheduleTick() {
        guard tickTask == nil, engine.needsTick else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: PredictiveEchoController.tickInterval)
                guard !Task.isCancelled, let self else { return }
                guard self.engine.needsTick, let screen = self.liveScreen() else {
                    self.tickTask = nil
                    return
                }
                self.engine.tick(screen: screen)
                self.sync()
            }
        }
    }
}
