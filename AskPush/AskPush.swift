import Foundation

// Shared verbatim by the notification service extension (which turns a question push into
// lock-screen buttons) and the app (which answers when one is pressed), and tested on Linux
// as the `AskPush` package target. Foundation only: the extension must not link HerdrKit,
// whose SSH stack would cost the extension's small memory budget for nothing.

/// The omp question a NeedsInput push carries as `herdr_ask` (herdr#309): only for an
/// answerable ask — one single-select question — on an agent local to the pushing daemon.
struct AskPush: Equatable, Sendable {
    /// The most buttons iOS shows on a notification.
    static let maxOptions = 4

    /// Display name only; `paneID` is what `agent.answer` targets.
    let agent: String
    let paneID: String
    /// The pushing daemon's install id (`agent.list` `origin_machine_id`); nil when absent.
    let machineID: String?
    let askID: String
    let question: String
    let options: [String]

    init(agent: String, paneID: String, machineID: String?, askID: String, question: String, options: [String]) {
        self.agent = agent
        self.paneID = paneID
        self.machineID = machineID
        self.askID = askID
        self.question = question
        self.options = options
    }

    /// Nil unless the push is an owner question with 1...4 usable options. A guest push is
    /// refused even if it carries `herdr_ask`: guests can never answer. More than four
    /// options is refused rather than truncated, because a lock screen offering some of the
    /// choices reads as if those were all of them; the notification still opens the chat.
    init?(userInfo: [AnyHashable: Any]) {
        guard userInfo["herdr_guest"] == nil,
              let ask = userInfo["herdr_ask"] as? [String: Any],
              let paneID = Self.nonEmpty(ask["pane_id"]),
              let askID = Self.nonEmpty(ask["ask_id"]),
              let rawOptions = ask["options"] as? [Any] else { return nil }
        // The server matches the answer by option TEXT, so a blank or non-string entry is
        // unanswerable; one is enough to distrust the whole list.
        let options = rawOptions.compactMap { Self.nonEmpty($0) }
        guard options.count == rawOptions.count, (1...Self.maxOptions).contains(options.count) else { return nil }
        self.init(
            agent: Self.nonEmpty(ask["agent"]) ?? "omp",
            paneID: paneID,
            machineID: Self.nonEmpty(ask["machine_id"]),
            askID: askID,
            question: (ask["question"] as? String) ?? "",
            options: options)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return string
    }
}

/// The notification category one question gets: one action per option. Action titles are
/// the option texts, so each ask needs its own category.
struct AskCategory: Equatable, Sendable {
    struct Action: Equatable, Sendable {
        let identifier: String
        let title: String
    }

    static let identifierPrefix = "herdr.ask."
    static let actionPrefix = "herdr.ask.option."

    let identifier: String
    let actions: [Action]

    init(_ ask: AskPush) {
        identifier = Self.identifierPrefix + ask.askID
        // The action carries the option's INDEX, not its text: the response handler reads the
        // text back from the same payload, so no option text has to survive as an identifier.
        actions = ask.options.enumerated().map { index, option in
            Action(identifier: Self.actionPrefix + String(index), title: option)
        }
    }

    /// The option index an action identifier names, or nil for any other action.
    static func optionIndex(actionIdentifier: String) -> Int? {
        guard actionIdentifier.hasPrefix(actionPrefix) else { return nil }
        return Int(actionIdentifier.dropFirst(actionPrefix.count))
    }

    /// Which registered categories to keep when `adding` one. Registration replaces the
    /// app's whole set, and every question adds a category, so ask categories whose
    /// notification is gone are dropped (their buttons can no longer be pressed); anything
    /// that is not an ask category is kept untouched.
    static func retained(existing: [String], delivered: Set<String>, adding: String) -> Set<String> {
        var keep = Set(existing.filter { !$0.hasPrefix(identifierPrefix) || delivered.contains($0) })
        keep.insert(adding)
        return keep
    }
}
