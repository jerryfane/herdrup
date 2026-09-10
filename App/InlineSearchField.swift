import SwiftUI

/// The inline search field used by the terminal pane header and the Gram header.
///
/// One component rather than two look-alikes: the two surfaces search different things
/// (the terminal walks matches in a scrollback, Gram filters a list) but they are the
/// same control to the reader — a magnifier in the header that becomes a field, and
/// gives the header back when dismissed. Keeping them literally the same view is what
/// stops them drifting into two slightly different search boxes.
///
/// Match navigation is OPTIONAL. Passing `matches` plus the two step closures gives the
/// terminal's "3/17" counter and chevrons; omitting them gives Gram's plain filter, with
/// no dead chevrons to explain.
struct InlineSearchField: View {
    let placeholder: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    /// `(index, total)` for a walk-the-matches search; nil for a filter.
    var matches: (index: Int, total: Int)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    /// Identifier prefix so each host's controls are addressable in UI tests.
    var identifierPrefix: String

    private var hasMatches: Bool { (matches?.total ?? 0) > 0 }

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Typography.app(14))
                .foregroundStyle(Palette.text)
                .tint(Palette.text)
                .focused(focus)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("\(identifierPrefix)-field")
                .onSubmit { onNext?() }

            if let matches {
                // Only a match-walking search reports a count. A filter's "how many" is
                // the list itself, and a "0 results" chip above a visibly empty list is
                // the same fact twice.
                if matches.total > 0 {
                    Text("\(matches.index)/\(matches.total)")
                        .font(Typography.machine(11))
                        .foregroundStyle(Palette.textFaint)
                        .monospacedDigit()
                        .accessibilityIdentifier("\(identifierPrefix)-count")
                } else if !text.isEmpty {
                    Text("none")
                        .font(Typography.machine(11))
                        .foregroundStyle(Palette.textFaint)
                        .accessibilityIdentifier("\(identifierPrefix)-count")
                }
            }

            if let onPrevious {
                stepButton("chevron.up", label: "Previous match",
                           identifier: "\(identifierPrefix)-previous", action: onPrevious)
            }
            if let onNext {
                stepButton("chevron.down", label: "Next match",
                           identifier: "\(identifierPrefix)-next", action: onNext)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surface))
    }

    private func stepButton(_ symbol: String, label: String,
                            identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hasMatches ? Palette.textDim : Palette.textFaint)
        }
        .disabled(!hasMatches)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
    }
}

/// The magnifier that opens one. Separate from the field so a header can place it
/// among its other icons without inheriting the field's layout.
struct InlineSearchToggle: View {
    let isOpen: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOpen ? Palette.text : Palette.textDim)
        }
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(isOpen ? "Close search" : "Search")
    }
}
