import Foundation

/// Normalizes an arbitrary string (e.g. a folder basename) to herdr's agent-name
/// grammar, `^[a-z][a-z0-9_-]{0,31}$`.
///
/// This exists so `agent.start` does not fail AFTER a pane was already created: a
/// folder like "Herdr-iOS", "~/My Project", or "工作" would otherwise pass the UI
/// and be rejected by the server mid-spawn, stranding the pane. Normalizing up
/// front turns those into names the server accepts. Duplicate normalized names
/// still surface `agent_name_taken` — that is the server's call, not guessed here.
public enum AgentName {
    public static func normalize(_ raw: String) -> String {
        var out = ""
        for scalar in raw.lowercased().unicodeScalars {
            let c = Character(scalar)
            if out.isEmpty {
                // Must start with a letter; drop anything (digits, symbols) before it.
                if ("a"..."z").contains(c) { out.append(c) }
            } else if ("a"..."z").contains(c) || ("0"..."9").contains(c) || c == "-" || c == "_" {
                out.append(c)
            } else {
                out.append("-")   // any other character becomes a separator
            }
            if out.count >= 32 { break }
        }
        return out.isEmpty ? "agent" : out
    }
}
