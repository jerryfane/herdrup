import Foundation

/// Strips terminal *graphics* escape strings from a raw PTY byte stream before it
/// reaches the on-device terminal emulator (SwiftTerm), which crashes on them.
///
/// ## Why this exists
/// A herdr pane running `terminal-browser` draws a real Chromium view into the
/// terminal using the **kitty graphics protocol** — high-volume base64 image data
/// carried in APC escape strings (`ESC _ G … ESC \`). The daemon's own VT handles
/// these (it has first-class kitty support); the iOS client feeds the same raw
/// firehose straight into SwiftTerm 1.15.0, which chokes on the payload and takes
/// the whole app down. Because the pane re-feeds on every open, it is a crash loop
/// (jerryfane/herdrup#170, directive 83120).
///
/// The app is a *read-only display*: it never needs to act on a graphics string,
/// so the safe fix is to drop them client-side before `feed`. That is correct
/// regardless of whether SwiftTerm dies parsing the payload or on its size — it
/// simply never sees it. The daemon / TUI / ghostty path is untouched; this is a
/// client-renderer defect and the fix belongs in the client.
///
/// ## What is dropped, what is kept
/// - **APC** (`ESC _ … ST/BEL`) — dropped entirely. This is kitty graphics and any
///   other APC protocol; a display terminal has no use for APC. Covers the reported
///   crash and any APC-based image protocol at once, not just a kitty-specific
///   `_G` match (jarvis: prefer the general form when it costs the same).
/// - **DCS** (`ESC P … ST/BEL`) — *size-gated*: a DCS whose bytes exceed
///   ``dcsPassThroughLimit`` is dropped (sixel / high-volume graphics); a small one
///   passes through verbatim, so legitimate control strings (e.g. DECRQSS status
///   replies) are preserved.
/// - **Everything else passes through byte-identical** — plain text, CSI/SGR
///   (`ESC [ …`), and OSC (`ESC ] …`, used by SwiftTerm for title/colours). OSC-1337
///   inline images (iTerm2) are a size-gate follow-up, noted on #170.
///
/// ## Statefulness
/// The daemon streams PTY output in chunks, so a single graphics string routinely
/// spans several `feed` calls. This filter is therefore a **stateful** byte machine:
/// one instance per live stream, carried across chunks. Only the 7-bit `ESC`-
/// introduced forms are recognised — the 8-bit C1 introducers (0x90/0x9f) are left
/// alone because in a UTF-8 stream those bytes are valid multi-byte continuation
/// bytes, and treating them as controls would corrupt text.
public struct TerminalGraphicsFilter {

    /// A DCS string at or under this many bytes passes through unchanged; a larger
    /// one is dropped as graphics. Legitimate DCS control replies are tens of bytes;
    /// sixel/graphics DCS run to many kilobytes, so this cleanly separates them.
    public static let dcsPassThroughLimit = 4096

    private enum Mode {
        case ground   // normal passthrough
        case esc      // saw ESC (0x1b); next byte classifies the sequence
        case apc      // inside an APC string — dropping
        case dcs      // inside a DCS string — buffering to decide pass/drop by size
    }

    private var mode: Mode = .ground
    /// Inside `.apc`/`.dcs`: the previous byte was ESC (0x1b), so the current byte
    /// may complete an ST terminator (`ESC \`).
    private var escPending = false
    /// Buffered DCS bytes (from the `ESC P` intro), held so a small DCS can be
    /// re-emitted verbatim. Emptied and abandoned once `dcsOverflow` trips.
    private var dcsBuffer: [UInt8] = []
    /// The current DCS exceeded ``dcsPassThroughLimit`` — stop buffering (bounded
    /// memory) and drop it on termination.
    private var dcsOverflow = false

    public init() {}

    /// Abandon any in-progress sequence. Call at a full keyframe (`reset`), where a
    /// fresh screen means any partial string from the previous stream is void.
    public mutating func reset() {
        mode = .ground
        escPending = false
        dcsBuffer = []
        dcsOverflow = false
    }

    /// Filter one chunk, returning the bytes safe to feed to the emulator. State
    /// carries to the next call, so a sequence split across chunks is handled.
    public mutating func filter(_ input: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        for b in input {
            switch mode {
            case .ground:
                if b == 0x1b { mode = .esc }   // hold the ESC; classify on the next byte
                else { out.append(b) }

            case .esc:
                switch b {
                case 0x5f:                     // ESC _  → APC: drop until terminator
                    mode = .apc; escPending = false
                case 0x50:                     // ESC P  → DCS: buffer until terminator
                    mode = .dcs; escPending = false; dcsBuffer = [0x1b, 0x50]; dcsOverflow = false
                case 0x1b:                     // ESC ESC → emit the first, keep holding the second
                    out.append(0x1b)
                default:                       // any other 2-byte / CSI / OSC intro: not a graphics string
                    out.append(0x1b)
                    out.append(b)
                    mode = .ground
                }

            case .apc:                         // drop everything to the ST/BEL terminator
                if escPending {
                    if b == 0x5c { mode = .ground; escPending = false }   // ESC \ = ST → end
                    else if b != 0x1b { escPending = false }              // ESC + other: still inside
                    // ESC ESC: keep escPending true
                } else if b == 0x07 { mode = .ground }                    // BEL → end
                else if b == 0x1b { escPending = true }
                // otherwise: drop the byte

            case .dcs:                         // buffer (bounded) to decide pass vs drop by size
                appendDCS(b)
                if escPending {
                    if b == 0x5c { flushDCS(&out); mode = .ground; escPending = false }  // ST → end
                    else if b != 0x1b { escPending = false }
                } else if b == 0x07 { flushDCS(&out); mode = .ground }    // BEL → end
                else if b == 0x1b { escPending = true }
            }
        }
        return out
    }

    private mutating func appendDCS(_ b: UInt8) {
        if dcsOverflow { return }
        dcsBuffer.append(b)
        if dcsBuffer.count > Self.dcsPassThroughLimit {
            dcsOverflow = true    // give up buffering; this DCS is graphics and will be dropped
            dcsBuffer = []
        }
    }

    private mutating func flushDCS(_ out: inout [UInt8]) {
        if !dcsOverflow { out.append(contentsOf: dcsBuffer) }   // small DCS → verbatim; large → dropped
        dcsBuffer = []
        dcsOverflow = false
    }
}
