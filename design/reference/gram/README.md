# Gram references for Herdrup Desktop

Eleven states on each reference iPad (22 PNGs), captured through the native Gram sidebar, feed, Saved view and composer. These are fixture-backed iOS 27.0 screenshots, not Mac captures or live-service evidence.

`manifest.json` records each PNG's hash, actual source head and CI run, fixture hash, simulator, dimensions and capture conditions. Keep it with the images. The complete delivery also includes 24 [agent-list](../agent-list/) and eight [Settings](../settings/) images; do not mix these with the earlier iOS 26.5 baseline.

| State suffix | Visible reference |
|---|---|
| `gram-mixed-latest` | Incoming and outgoing messages, delivered state, unread rule, image and file card |
| `gram-mixed-folded` | Long message with Read more, sender grouping and pinned Today separator |
| `gram-mixed-code` | Code block and Copy action |
| `gram-mixed-image` | Full image aspect ratio and neighboring file card |
| `gram-search-results` | `handoff` query and matching file message |
| `gram-search-empty` | Retained query and No matches state |
| `gram-saved` | Two saved messages, bookmark controls and pinned message ages |
| `gram-composer-attachment` | Resolved mention, Ready attachment chip and enabled Send |
| `gram-composer-ambiguous` | Ambiguous mention warning, retained draft/attachment and disabled Send |
| `gram-empty` | Empty inbox with composer |
| `gram-loading` | Held loading spinner with sidebar and composer |

The image/latest/code targets can share a scroll position when all targets fit on the larger iPad. The captures preserve the actual app layout rather than inventing different positions. Other content may continue beyond the viewport.

Fixtures are `HerdrUITests/Fixtures/desktop-reference-gram*.json`; the populated fixture includes its image and file data. The capture instruments are `DesktopGramReferenceShots` and `DesktopReferenceCaptureCase`. English (`en_US`), UTC, Gregorian calendar, dark appearance, Large Dynamic Type and `HERDR_MOCK_NOW=2026-10-28T09:41:00Z` are common across all sets. Dates and Saved ages use that clock; the system status bar shows the actual capture date, Fri Oct 30, at overridden 9:41.

See [regeneration instructions](../agent-list/README.md#regenerating) and [Mac differences](../MAC-DIFFERENCES.md). A single Gram method can be recaptured on both devices without repeating the other accepted states.
