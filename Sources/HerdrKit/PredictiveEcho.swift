import Foundation

/// The terminal screen a `PredictionEngine` predicts on and checks against: the visible
/// grid (the live screen, not scrollback), its cursor, and the text of one cell.
public protocol PredictionScreen {
    var columns: Int { get }
    var rows: Int { get }
    var cursor: (col: Int, row: Int) { get }
    /// The cell's character, "" or " " for a blank cell.
    func text(col: Int, row: Int) -> String
}

/// What the terminal should draw on top of the real screen right now. Empty when nothing
/// may be shown.
public struct PredictionOverlay: Equatable, Sendable {
    public struct Cell: Equatable, Sendable {
        public let col: Int
        public let row: Int
        /// The predicted character, drawn over the cell. nil: the cell's content is not
        /// known, only an underline over what is there is drawn.
        public let text: String?
        public let underlined: Bool

        public init(col: Int, row: Int, text: String?, underlined: Bool) {
            self.col = col
            self.row = row
            self.text = text
            self.underlined = underlined
        }
    }

    public struct Position: Equatable, Sendable {
        public let col: Int
        public let row: Int

        public init(col: Int, row: Int) {
            self.col = col
            self.row = row
        }
    }

    public var cells: [Cell]
    /// The predicted cursor, nil when the real cursor stands.
    public var cursor: Position?

    public init(cells: [Cell] = [], cursor: Position? = nil) {
        self.cells = cells
        self.cursor = cursor
    }

    public var isEmpty: Bool { cells.isEmpty && cursor == nil }
    public static let empty = PredictionOverlay()
}

/// Predictive local echo for one pane, after mosh's `PredictionEngine`
/// (src/frontend/terminaloverlay.{h,cc}): typed characters are drawn at once over the
/// screen and checked against the real screen once the server has had the key.
///
/// What is predicted, as mosh: a printable width-1 character is inserted at the predicted
/// cursor (the rest of the row shifts right), backspace (0x7f) deletes left of it (the
/// rest shifts left), Left/Right arrows (CSI D/C, SS3 D/C) move it. Enter predicts a
/// carriage return + newline in a new epoch; any other control or escape sequence, a
/// wide or combining character, and a character in the last column only start a new
/// epoch ("become tentative").
///
/// Epochs: a prediction is shown only once a prediction of its epoch was confirmed by the
/// real screen. So a prompt that does not echo (a password) never shows anything, and an
/// application that moved the cursor elsewhere never shows anything either. A wrong
/// prediction in an unconfirmed epoch kills that epoch; a wrong prediction that was
/// already shown resets everything.
///
/// When a prediction can be checked (herdr's stand-in for mosh's "late ack"): a key batch
/// is checkable once the server acknowledged it (`batchAcked`) and then either an output
/// frame arrived at least `echoTimeout` after that ack, or an output frame visibly shows a
/// prediction of that batch, or `ackExpiry` passed after the ack without any output
/// (`tick`). Batches are numbered by the caller in send order and acked cumulatively.
///
/// Round trip (mosh's send interval): `srtt`, smoothed here (1/8 gain) from samples
/// "batch handed over → the server's ack AND some output after the batch was sent", i.e.
/// the time until the batch's echo could first be checked. A sample is capped at
/// `glitchThreshold`: a stall longer than that is the glitch rule's business, as in
/// mosh, whose network SRTT an outage does not inflate either.
///
/// Main-thread use only; the clock is injectable for tests. Never touches the emulator:
/// the caller draws `overlay` above it.
public final class PredictionEngine {
    public enum Mode: String, CaseIterable, Sendable {
        /// Show predictions only when the round trip is slow, or the link glitched.
        case auto
        /// Show confirmed predictions whatever the round trip.
        case always
        /// Never predict.
        case off
    }

    /// A key whose prediction was put in the overlay for the first time.
    public struct FirstPaint: Equatable, Sendable {
        public let pressedAt: TimeInterval
        public let shownAt: TimeInterval

        public init(pressedAt: TimeInterval, shownAt: TimeInterval) {
            self.pressedAt = pressedAt
            self.shownAt = shownAt
        }
    }

    // mosh terminaloverlay.h, in seconds.
    /// Auto mode shows predictions once the round trip exceeds this...
    public static let srttTriggerHigh: TimeInterval = 0.030
    /// ...and stops once it is back at or under this with nothing predicted.
    public static let srttTriggerLow: TimeInterval = 0.020
    /// Unconfirmed predictions are underlined once the round trip exceeds this...
    public static let flagTriggerHigh: TimeInterval = 0.080
    /// ...and no longer at or under this.
    public static let flagTriggerLow: TimeInterval = 0.050
    /// A prediction pending this long is a glitch: predictions are shown.
    public static let glitchThreshold: TimeInterval = 0.250
    /// Quick confirmations needed to repair a glitch.
    public static let glitchRepairCount = 10
    /// Quick confirmations count at most once per this.
    public static let glitchRepairMinInterval: TimeInterval = 0.150
    /// A prediction pending this long also turns underlining on.
    public static let glitchFlagThreshold: TimeInterval = 5.0
    /// Output this long after an ack shows the screen the server made of the batch.
    public static let echoTimeout: TimeInterval = 0.050
    /// With no output at all, a batch is checked this long after its ack.
    public static let ackExpiry: TimeInterval = 1.0

    private enum Validity { case pending, correct, correctNoCredit, incorrectOrExpired, inactive }

    /// The key a cell's predicted character came from, carried along when it shifts.
    private struct Key {
        var pressedAt: TimeInterval
        var shown = false
    }

    private struct Cell {
        var active = false
        var tentativeUntil: UInt64 = .max
        var expiration: UInt64 = .max
        var predictionTime: TimeInterval = 0
        var replacement = " "
        var unknown = false
        /// What the cell held before; a match against one of these earns no credit.
        var originals: [String] = []
        var key: Key?

        func tentative(_ confirmedEpoch: UInt64) -> Bool { tentativeUntil > confirmedEpoch }

        mutating func expire(_ batch: UInt64, now: TimeInterval) {
            expiration = batch
            predictionTime = now
        }

        private mutating func resetBase() {
            active = false
            tentativeUntil = .max
            expiration = .max
            key = nil
        }

        mutating func reset() {
            unknown = false
            originals.removeAll()
            resetBase()
        }

        mutating func resetWithOriginal() {
            if !active || unknown {
                reset()
                return
            }
            originals.append(replacement)
            resetBase()
        }
    }

    private struct CursorMove {
        var col: Int
        var row: Int
        var tentativeUntil: UInt64
        var expiration: UInt64

        func tentative(_ confirmedEpoch: UInt64) -> Bool { tentativeUntil > confirmedEpoch }
    }

    private enum ParseState { case ground, escape, escapeIntermediate, csi, csiExtended }

    private let clock: () -> TimeInterval

    public private(set) var mode: Mode
    /// What to draw now.
    public private(set) var overlay = PredictionOverlay.empty
    /// Typed characters put in the overlay.
    public private(set) var shown = 0
    /// Shown characters the real screen then confirmed.
    public private(set) var confirmed = 0
    /// Shown characters withdrawn because the real screen disagreed.
    public private(set) var wrong = 0
    /// Smoothed round trip, nil before the first sample.
    public private(set) var srtt: TimeInterval?

    private var firstPaints: [FirstPaint] = []
    private var rowCells: [Int: [Cell]] = [:]
    private var cursors: [CursorMove] = []
    private var predictionEpoch: UInt64 = 1
    private var confirmedEpoch: UInt64 = 0
    private var srttTrigger = false
    private var flagging = false
    private var glitchTrigger = 0
    private var lastQuickConfirmation: TimeInterval = -.infinity
    private var lastColumns = -1
    private var lastRows = -1

    private var lastBatch: UInt64 = 0
    private var ackedThrough: UInt64 = 0
    private var lateAckedThrough: UInt64 = 0
    /// Acks whose batches are not checkable yet, oldest first.
    private var acks: [(through: UInt64, at: TimeInterval)] = []
    /// Round-trip probes, one per batch until sampled.
    private var probes: [(batch: UInt64, sentAt: TimeInterval, ackedAt: TimeInterval?)] = []
    private static let maxProbes = 64
    private var lastOutputAt: TimeInterval = -.infinity

    private var parseState = ParseState.ground
    private var utf8: [UInt8] = []
    private var utf8Needed = 0

    public init(mode: Mode = .auto,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.mode = mode
        self.clock = clock
    }

    // MARK: - API

    public func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        if mode == .off { reset() }
    }

    /// Bytes the user typed, about to go out as `batch` (numbers increase in send order).
    /// `screen` is the screen as it is now, before any echo.
    public func userBytes(_ bytes: [UInt8], screen: PredictionScreen, batch: UInt64) {
        guard mode != .off, !bytes.isEmpty else { return }
        let now = clock()
        cull(screen, now: now)
        if batch > lastBatch { lastBatch = batch }
        if !probes.contains(where: { $0.batch == batch }) {
            probes.append((batch, now, nil))
            if probes.count > Self.maxProbes { probes.removeFirst() }
        }
        for byte in bytes { consume(byte, screen: screen, batch: batch, now: now) }
        refreshOverlay(screen, now: now)
    }

    /// The server has every batch up to `batch`. `failed`: their send failed, so what
    /// reached the pane is unknown. With `screen`, predictions are checked at once
    /// (output that arrived before the ack may already show them).
    public func batchAcked(_ batch: UInt64, failed: Bool = false, screen: PredictionScreen? = nil) {
        guard mode != .off else { return }
        let now = clock()
        if batch > ackedThrough {
            ackedThrough = batch
            acks.append((batch, now))
        }
        if failed {
            reset()
            return
        }
        // Round trip: to the ack when output since the send is already in; otherwise
        // until the first output after the ack (`settleProbes`).
        probes.removeAll { probe in
            guard probe.batch <= batch, probe.ackedAt == nil else { return false }
            guard lastOutputAt < probe.sentAt else {
                sample(now - probe.sentAt)
                return true
            }
            return false
        }
        for index in probes.indices where probes[index].batch <= batch && probes[index].ackedAt == nil {
            probes[index].ackedAt = now
        }
        if let screen {
            cull(screen, now: now)
            refreshOverlay(screen, now: now)
        }
    }

    /// An output frame was applied to the emulator; `screen` shows it.
    public func outputArrived(screen: PredictionScreen) {
        guard mode != .off else { return }
        let now = clock()
        lastOutputAt = now
        settleProbes(now: now, output: true)
        promoteAcks(olderThan: Self.echoTimeout, now: now)
        cull(screen, now: now)
        refreshOverlay(screen, now: now)
    }

    /// Time passed without output: expires acked batches after `ackExpiry` and applies
    /// the glitch rule. Call every few tens of milliseconds while `needsTick`.
    public func tick(screen: PredictionScreen) {
        guard mode != .off else { return }
        let now = clock()
        settleProbes(now: now, output: false)
        promoteAcks(olderThan: Self.ackExpiry, now: now)
        cull(screen, now: now)
        refreshOverlay(screen, now: now)
    }

    /// Whether predictions for sent batches are waiting to be checked.
    public var needsTick: Bool {
        guard mode != .off else { return false }
        if probes.contains(where: { $0.ackedAt != nil }) { return true }
        if cursors.contains(where: { $0.expiration <= lastBatch }) { return true }
        return rowCells.values.contains { cells in cells.contains { $0.active && $0.expiration <= lastBatch } }
    }

    /// Whether anything is predicted, shown or not.
    public var hasPredictions: Bool {
        !cursors.isEmpty || rowCells.values.contains { $0.contains(where: \.active) }
    }

    /// Forget every prediction (the screen changed under them: a resize, another screen,
    /// the reader scrolled away, the pane stopped). Not counted as wrong.
    public func reset() {
        discardPredictions()
        probes.removeAll()
        parseState = .ground
        utf8.removeAll()
        utf8Needed = 0
        overlay = .empty
    }

    /// Keys put in the overlay since the last call.
    public func takeFirstPaints() -> [FirstPaint] {
        defer { firstPaints.removeAll() }
        return firstPaints
    }

    // MARK: - Round trip

    private func sample(_ measured: TimeInterval) {
        guard measured >= 0 else { return }
        let interval = min(measured, Self.glitchThreshold)
        if let srtt {
            self.srtt = srtt + (interval - srtt) / 8
        } else {
            srtt = interval
        }
    }

    /// Acked probes without output yet: output within `echoTimeout` of the ack ends the
    /// sample there; later output, or none (`output` false), ends it at the ack, so a
    /// key nothing echoes (a password) does not count as a slow link.
    private func settleProbes(now: TimeInterval, output: Bool) {
        probes.removeAll { probe in
            guard let ackedAt = probe.ackedAt else { return false }
            if output, now - ackedAt <= Self.echoTimeout {
                sample(now - probe.sentAt)
                return true
            }
            guard output || now - ackedAt > Self.echoTimeout else { return false }
            sample(ackedAt - probe.sentAt)
            return true
        }
    }

    private func promoteAcks(olderThan age: TimeInterval, now: TimeInterval) {
        var through = lateAckedThrough
        for ack in acks where now - ack.at >= age { through = max(through, ack.through) }
        setLateAcked(through)
    }

    private func setLateAcked(_ through: UInt64) {
        guard through > lateAckedThrough else { return }
        lateAckedThrough = through
        acks.removeAll { $0.through <= through }
    }

    /// Output that shows a prediction of an acked batch (one that did not already hold
    /// that character) is the screen the server made of it: that batch and every earlier
    /// one are checkable now.
    private func promoteVisiblyEchoed(_ screen: PredictionScreen) {
        guard ackedThrough > lateAckedThrough else { return }
        var through = lateAckedThrough
        for (row, cells) in rowCells where row >= 0 && row < screen.rows {
            for (col, cell) in cells.enumerated() where col < screen.columns {
                guard cell.active, !cell.unknown, !Self.isBlank(cell.replacement),
                      cell.expiration > through, cell.expiration <= ackedThrough else { continue }
                let current = Self.text(screen, col: col, row: row)
                if current == cell.replacement, !cell.originals.contains(current) {
                    through = cell.expiration
                }
            }
        }
        setLateAcked(through)
    }

    /// Whether a pending prediction of `batch` is only waiting for evidence: acked at
    /// least `echoTimeout` ago, i.e. past what mosh would have waited. That wait is not
    /// a slow link, so it does not count toward a glitch.
    private func awaitingEvidence(_ batch: UInt64, now: TimeInterval) -> Bool {
        guard batch <= ackedThrough, let ack = acks.first(where: { $0.through >= batch }) else { return false }
        return now - ack.at >= Self.echoTimeout
    }

    // MARK: - Checking (mosh `cull`)

    private func validity(_ cell: Cell, col: Int, row: Int, screen: PredictionScreen) -> Validity {
        guard cell.active else { return .inactive }
        guard row < screen.rows, col < screen.columns else { return .incorrectOrExpired }
        if lateAckedThrough < cell.expiration { return .pending }
        if cell.unknown { return .correctNoCredit }
        // Too easy to match by accident.
        if Self.isBlank(cell.replacement) { return .correctNoCredit }
        let current = Self.text(screen, col: col, row: row)
        guard current == cell.replacement else { return .incorrectOrExpired }
        return cell.originals.contains(current) ? .correctNoCredit : .correct
    }

    private func validity(_ cursor: CursorMove, screen: PredictionScreen) -> Validity {
        guard cursor.row >= 0, cursor.col >= 0, cursor.row < screen.rows, cursor.col < screen.columns else {
            return .incorrectOrExpired
        }
        guard lateAckedThrough >= cursor.expiration else { return .pending }
        let real = screen.cursor
        return real.col == cursor.col && real.row == cursor.row ? .correct : .incorrectOrExpired
    }

    private func cull(_ screen: PredictionScreen, now: TimeInterval) {
        if screen.columns != lastColumns || screen.rows != lastRows {
            let first = lastColumns < 0
            lastColumns = screen.columns
            lastRows = screen.rows
            if !first { discardPredictions() }
        }

        if let srtt {
            if srtt > Self.srttTriggerHigh {
                srttTrigger = true
            } else if srttTrigger, srtt <= Self.srttTriggerLow, !hasPredictions {
                srttTrigger = false
            }
            if srtt > Self.flagTriggerHigh {
                flagging = true
            } else if srtt <= Self.flagTriggerLow {
                flagging = false
            }
        }
        if glitchTrigger > Self.glitchRepairCount { flagging = true }

        promoteVisiblyEchoed(screen)

        for row in rowCells.keys.sorted() {
            guard row >= 0, row < screen.rows else {
                rowCells[row] = nil
                continue
            }
            var col = 0
            while let count = rowCells[row]?.count, col < count {
                let cell = rowCells[row]![col]
                switch validity(cell, col: col, row: row, screen: screen) {
                case .incorrectOrExpired:
                    if cell.tentative(confirmedEpoch) {
                        killEpoch(cell.tentativeUntil, screen: screen)
                    } else {
                        withdrawShown()
                        return
                    }
                case .correct:
                    if cell.key?.shown == true { confirmed += 1 }
                    if cell.tentativeUntil > confirmedEpoch { confirmedEpoch = cell.tentativeUntil }
                    // Quick confirmations slowly repair a glitch.
                    if now - cell.predictionTime < Self.glitchThreshold, glitchTrigger > 0,
                       now - Self.glitchRepairMinInterval >= lastQuickConfirmation {
                        glitchTrigger -= 1
                        lastQuickConfirmation = now
                    }
                    rowCells[row]![col].reset()
                case .correctNoCredit:
                    if cell.key?.shown == true, Self.text(screen, col: col, row: row) == cell.replacement {
                        confirmed += 1
                    }
                    rowCells[row]![col].reset()
                case .pending:
                    if !awaitingEvidence(cell.expiration, now: now) {
                        let age = now - cell.predictionTime
                        if age >= Self.glitchFlagThreshold {
                            glitchTrigger = Self.glitchRepairCount * 2   // show and underline
                        } else if age >= Self.glitchThreshold, glitchTrigger < Self.glitchRepairCount {
                            glitchTrigger = Self.glitchRepairCount       // show
                        }
                    }
                case .inactive:
                    break
                }
                col += 1
            }
        }

        if let last = cursors.last, validity(last, screen: screen) == .incorrectOrExpired {
            withdrawShown()
            return
        }
        cursors.removeAll { validity($0, screen: screen) != .pending }
        // A glitch found just now underlines in this pass, not the next one.
        if glitchTrigger > Self.glitchRepairCount { flagging = true }
    }

    /// A shown prediction was wrong: every shown character goes, counted wrong.
    private func withdrawShown() {
        for cells in rowCells.values {
            wrong += cells.reduce(0) { $1.active && $1.key?.shown == true ? $0 + 1 : $0 }
        }
        discardPredictions()
        overlay = .empty
    }

    /// mosh `reset`.
    private func discardPredictions() {
        cursors.removeAll()
        rowCells.removeAll()
        becomeTentative()
    }

    private func killEpoch(_ epoch: UInt64, screen: PredictionScreen) {
        cursors.removeAll { $0.tentative(epoch - 1) }
        let real = screen.cursor
        cursors.append(CursorMove(col: real.col, row: real.row,
                                  tentativeUntil: predictionEpoch, expiration: lastBatch + 1))
        for row in rowCells.keys {
            for col in rowCells[row]!.indices where rowCells[row]![col].tentative(epoch - 1) {
                rowCells[row]![col].reset()
            }
        }
        becomeTentative()
    }

    private func becomeTentative() {
        predictionEpoch += 1
    }

    // MARK: - Showing (mosh `apply`)

    private func refreshOverlay(_ screen: PredictionScreen, now: TimeInterval) {
        let show = mode == .always || (mode == .auto && (srttTrigger || glitchTrigger > 0))
        guard show else {
            overlay = .empty
            return
        }
        var cells: [PredictionOverlay.Cell] = []
        for row in rowCells.keys.sorted() where row >= 0 && row < screen.rows {
            for col in rowCells[row]!.indices where col < screen.columns {
                let cell = rowCells[row]![col]
                guard cell.active, !cell.tentative(confirmedEpoch) else { continue }
                if cell.unknown {
                    if flagging, col != screen.columns - 1 {
                        cells.append(.init(col: col, row: row, text: nil, underlined: true))
                    }
                    continue
                }
                if Self.text(screen, col: col, row: row) == cell.replacement { continue }
                cells.append(.init(col: col, row: row, text: cell.replacement, underlined: flagging))
                if let key = cell.key, !key.shown {
                    rowCells[row]![col].key?.shown = true
                    shown += 1
                    firstPaints.append(FirstPaint(pressedAt: key.pressedAt, shownAt: now))
                }
            }
        }
        var cursor: PredictionOverlay.Position?
        if let move = cursors.last(where: { !$0.tentative(confirmedEpoch) }),
           move.row >= 0, move.col >= 0, move.row < screen.rows, move.col < screen.columns {
            cursor = .init(col: move.col, row: move.row)
        }
        overlay = PredictionOverlay(cells: cells, cursor: cursor)
    }

    // MARK: - Input (mosh `new_user_byte`)

    private func consume(_ byte: UInt8, screen: PredictionScreen, batch: UInt64, now: TimeInterval) {
        switch parseState {
        case .ground:
            ground(byte, screen: screen, batch: batch, now: now)
        case .escape:
            switch byte {
            // SS3 is read as CSI, as mosh does, so application-mode arrows are arrows.
            case 0x5B, 0x4F: parseState = .csi
            case 0x1B, 0x7F: break
            case 0x20...0x2F: parseState = .escapeIntermediate
            case 0x30...0x7E:
                becomeTentative()
                parseState = .ground
            case 0x00..<0x20: control(byte, screen: screen, batch: batch, now: now)
            default:
                becomeTentative()
                parseState = .ground
                ground(byte, screen: screen, batch: batch, now: now)
            }
        case .escapeIntermediate:
            switch byte {
            case 0x20...0x2F, 0x7F: break
            case 0x30...0x7E:
                becomeTentative()
                parseState = .ground
            case 0x1B:
                becomeTentative()
                parseState = .escape
            case 0x00..<0x20: control(byte, screen: screen, batch: batch, now: now)
            default:
                becomeTentative()
                parseState = .ground
                ground(byte, screen: screen, batch: batch, now: now)
            }
        case .csi, .csiExtended:
            switch byte {
            case 0x20...0x3F: parseState = .csiExtended
            case 0x40...0x7E:
                let plain = parseState == .csi
                parseState = .ground
                if plain, byte == 0x43 {
                    arrowRight(screen: screen, batch: batch, now: now)
                } else if plain, byte == 0x44 {
                    arrowLeft(screen: screen, batch: batch, now: now)
                } else {
                    becomeTentative()
                }
            case 0x7F: break
            case 0x1B:
                becomeTentative()
                parseState = .escape
            case 0x00..<0x20: control(byte, screen: screen, batch: batch, now: now)
            default:
                becomeTentative()
                parseState = .ground
                ground(byte, screen: screen, batch: batch, now: now)
            }
        }
    }

    /// A C0 control byte inside or outside a sequence.
    private func control(_ byte: UInt8, screen: PredictionScreen, batch: UInt64, now: TimeInterval) {
        if byte == 0x18 || byte == 0x1A { parseState = .ground }   // CAN, SUB abort a sequence
        if byte == 0x0D {
            becomeTentative()
            newlineCarriageReturn(screen: screen, batch: batch, now: now)
        } else {
            becomeTentative()
        }
    }

    private func ground(_ byte: UInt8, screen: PredictionScreen, batch: UInt64, now: TimeInterval) {
        if utf8Needed > 0 {
            if byte & 0xC0 == 0x80 {
                utf8.append(byte)
                utf8Needed -= 1
                if utf8Needed == 0 { finishScalar(screen: screen, batch: batch, now: now) }
                return
            }
            utf8.removeAll()
            utf8Needed = 0
            becomeTentative()
        }
        switch byte {
        case 0x1B: parseState = .escape
        case 0x7F: backspace(screen: screen, batch: batch, now: now)
        case 0x00..<0x20: control(byte, screen: screen, batch: batch, now: now)
        case 0x20..<0x7F: printable(Unicode.Scalar(byte), screen: screen, batch: batch, now: now)
        case 0xC2...0xDF: startScalar(byte, needing: 1)
        case 0xE0...0xEF: startScalar(byte, needing: 2)
        case 0xF0...0xF4: startScalar(byte, needing: 3)
        default: becomeTentative()
        }
    }

    private func startScalar(_ lead: UInt8, needing: Int) {
        utf8 = [lead]
        utf8Needed = needing
    }

    private func finishScalar(screen: PredictionScreen, batch: UInt64, now: TimeInterval) {
        let bytes = utf8
        utf8.removeAll()
        var decoder = UTF8()
        var iterator = bytes.makeIterator()
        guard case .scalarValue(let scalar) = decoder.decode(&iterator), scalar.value >= 0xA0 else {
            becomeTentative()   // malformed, or a C1 control
            return
        }
        printable(scalar, screen: screen, batch: batch, now: now)
    }

    private func printable(_ scalar: Unicode.Scalar, screen: PredictionScreen, batch: UInt64, now: TimeInterval) {
        guard Self.isSingleWidth(scalar) else {
            becomeTentative()
            return
        }
        insert(String(Character(scalar)), screen: screen, batch: batch, now: now)
    }

    private func initCursor(screen: PredictionScreen, batch: UInt64) {
        if let last = cursors.last {
            guard last.tentativeUntil != predictionEpoch else { return }
            cursors.append(CursorMove(col: last.col, row: last.row,
                                      tentativeUntil: predictionEpoch, expiration: batch))
        } else {
            let real = screen.cursor
            cursors.append(CursorMove(col: real.col, row: real.row,
                                      tentativeUntil: predictionEpoch, expiration: batch))
        }
    }

    private func cellsOfRow(_ row: Int, width: Int) -> [Cell] {
        if let cells = rowCells[row], cells.count == width { return cells }
        return Array(repeating: Cell(), count: width)
    }

    private func insert(_ character: String, screen: PredictionScreen, batch: UInt64, now: TimeInterval) {
        initCursor(screen: screen, batch: batch)
        let width = screen.columns
        let cursorRow = cursors[cursors.count - 1].row
        let cursorCol = cursors[cursors.count - 1].col
        guard cursorRow >= 0, cursorRow < screen.rows, cursorCol >= 0, cursorCol < width else {
            becomeTentative()
            return
        }
        // The last column is tricky: an editor shows a wrap mark, a shell just prints.
        if cursorCol + 1 >= width { becomeTentative() }

        var cells = cellsOfRow(cursorRow, width: width)
        var i = width - 1
        while i > cursorCol {
            cells[i].resetWithOriginal()
            cells[i].active = true
            cells[i].tentativeUntil = predictionEpoch
            cells[i].expire(batch, now: now)
            cells[i].originals.append(Self.text(screen, col: i, row: cursorRow))
            if i == width - 1 {
                cells[i].unknown = true
            } else if cells[i - 1].active {
                if cells[i - 1].unknown {
                    cells[i].unknown = true
                } else {
                    cells[i].unknown = false
                    cells[i].replacement = cells[i - 1].replacement
                    cells[i].key = cells[i - 1].key
                }
            } else {
                cells[i].unknown = false
                cells[i].replacement = Self.text(screen, col: i - 1, row: cursorRow)
            }
            i -= 1
        }
        cells[cursorCol].resetWithOriginal()
        cells[cursorCol].active = true
        cells[cursorCol].tentativeUntil = predictionEpoch
        cells[cursorCol].expire(batch, now: now)
        cells[cursorCol].replacement = character
        cells[cursorCol].key = Key(pressedAt: now)
        cells[cursorCol].originals.append(Self.text(screen, col: cursorCol, row: cursorRow))
        rowCells[cursorRow] = cells

        if cursorCol < width - 1 {
            cursors[cursors.count - 1].col += 1
            cursors[cursors.count - 1].expiration = batch
        } else {
            becomeTentative()
            newlineCarriageReturn(screen: screen, batch: batch, now: now)
        }
    }

    private func backspace(screen: PredictionScreen, batch: UInt64, now: TimeInterval) {
        initCursor(screen: screen, batch: batch)
        let width = screen.columns
        let cursorRow = cursors[cursors.count - 1].row
        let cursorCol = cursors[cursors.count - 1].col
        guard cursorCol > 0 else { return }
        guard cursorRow >= 0, cursorRow < screen.rows, cursorCol <= width else {
            becomeTentative()
            return
        }
        let start = cursorCol - 1
        cursors[cursors.count - 1].col = start
        cursors[cursors.count - 1].expiration = batch
        var cells = cellsOfRow(cursorRow, width: width)
        for i in start..<width {
            cells[i].resetWithOriginal()
            cells[i].active = true
            cells[i].tentativeUntil = predictionEpoch
            cells[i].expire(batch, now: now)
            cells[i].originals.append(Self.text(screen, col: i, row: cursorRow))
            if i + 2 < width {
                if cells[i + 1].active {
                    if cells[i + 1].unknown {
                        cells[i].unknown = true
                    } else {
                        cells[i].unknown = false
                        cells[i].replacement = cells[i + 1].replacement
                        cells[i].key = cells[i + 1].key
                    }
                } else {
                    cells[i].unknown = false
                    cells[i].replacement = Self.text(screen, col: i + 1, row: cursorRow)
                }
            } else {
                cells[i].unknown = true
            }
        }
        rowCells[cursorRow] = cells
    }

    private func newlineCarriageReturn(screen: PredictionScreen, batch: UInt64, now: TimeInterval) {
        initCursor(screen: screen, batch: batch)
        let last = cursors.count - 1
        cursors[last].col = 0
        let cursorRow = cursors[last].row
        if cursorRow == screen.rows - 1 {
            // No scroll prediction: the last row is predicted blank.
            var cells = cellsOfRow(cursorRow, width: screen.columns)
            for i in cells.indices {
                cells[i].active = true
                cells[i].tentativeUntil = predictionEpoch
                cells[i].expire(batch, now: now)
                cells[i].replacement = " "
                cells[i].key = nil
            }
            rowCells[cursorRow] = cells
        } else {
            cursors[last].row += 1
        }
        cursors[last].expiration = batch
    }

    private func arrowRight(screen: PredictionScreen, batch: UInt64, now: TimeInterval) {
        initCursor(screen: screen, batch: batch)
        let last = cursors.count - 1
        if cursors[last].col < screen.columns - 1 {
            cursors[last].col += 1
            cursors[last].expiration = batch
        }
    }

    private func arrowLeft(screen: PredictionScreen, batch: UInt64, now: TimeInterval) {
        initCursor(screen: screen, batch: batch)
        let last = cursors.count - 1
        if cursors[last].col > 0 {
            cursors[last].col -= 1
            cursors[last].expiration = batch
        }
    }

    // MARK: - Cells

    private static func text(_ screen: PredictionScreen, col: Int, row: Int) -> String {
        let text = screen.text(col: col, row: row)
        return text.isEmpty ? " " : text
    }

    private static func isBlank(_ text: String) -> Bool { text == " " || text.isEmpty }

    /// Scalars that certainly take one cell. Anything else (wide, combining, emoji,
    /// scripts whose width varies by font) is not predicted.
    static func isSingleWidth(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        switch value {
        case 0x20...0x7E: return true
        case 0xA0...0xFF: return value != 0xAD                     // Latin-1, not the soft hyphen
        case 0x100...0x2FF: return true                            // Latin Extended, IPA, modifiers
        case 0x370...0x52F: return !(0x483...0x489).contains(value)  // Greek, Cyrillic
        default: return false
        }
    }
}
