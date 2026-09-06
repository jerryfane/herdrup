import Foundation

/// Typed client for the herdr JSON API.
///
/// Every command opens its own connection, because the control socket is
/// single-shot (see `HerdrTransport`). Only `subscribe` holds a connection open.
public actor HerdrClient {
    private let transport: HerdrTransport
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Do NOT escape "/" as "\/". A base64 gram file chunk is slash-heavy (an
        // all-0xFF chunk is ALL "/"), and the default escaping would nearly double
        // those bytes — enough to push an otherwise in-budget chunk past the SSH
        // transport's command-size cap. Unescaped "/" is valid JSON and the server
        // parses it identically.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()
    private let decoder = JSONDecoder()
    private var sequence: UInt64 = 0
    /// Whether this daemon serves `gram.upload.stream`, cached per client so a
    /// multi-file send pays ONE `ping`.
    ///
    /// Three states on purpose: a successful probe is cached either way (so an old
    /// daemon is not re-probed per file), while a FAILED probe stays `unknown` (so a
    /// transient error cannot pin this client to the per-chunk path for its whole
    /// lifetime, and a daemon upgraded under a long-lived app is picked up).
    private enum StreamCapability {
        case unknown
        case supported
        case unsupported
    }
    private var streamCapability: StreamCapability = .unknown

    public init(transport: HerdrTransport) {
        self.transport = transport
    }

    private func nextID(_ method: String) -> String {
        sequence &+= 1
        return "herdrkit:\(method):\(sequence)"
    }

    private func encodeRequest<P: Encodable>(_ method: String, _ params: P) throws -> String {
        let env = RequestEnvelope(id: nextID(method), method: method, params: params)
        let data = try encoder.encode(env)
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes a response line, surfacing a server `error` object as a thrown `APIError`.
    private func decodeResult<R: Decodable>(_ line: String, as: R.Type) throws -> R {
        let data = Data(line.utf8)
        if let err = try? decoder.decode(ErrorEnvelope.self, from: data) {
            throw err.error
        }
        return try decoder.decode(ResultEnvelope<R>.self, from: data).result
    }

    private func call<P: Encodable, R: Decodable>(
        _ method: String, _ params: P, as type: R.Type
    ) async throws -> R {
        let line = try encodeRequest(method, params)
        let response = try await transport.roundTrip(line)
        return try decodeResult(response, as: type)
    }

    // MARK: - Commands

    /// Every agent the server knows about, with the `revision` /
    /// `stateChangeSeq` counters that drive refresh decisions.
    public func agentList() async throws -> [AgentInfo] {
        try await call("agent.list", EmptyParams(), as: AgentListResult.self).agents
    }

    /// Every credential account (subscription) the daemon knows about, for the
    /// Settings → Accounts list and the per-agent "Swap subscription" menu. Mirrors
    /// `agentList()`: a small parameterless JSON query. THROWS the server's
    /// `APIError` on an older daemon that lacks the method, so callers that want a
    /// quiet degrade use `try?`.
    public func accountsList() async throws -> [CredentialAccount] {
        try await call("accounts.list", EmptyParams(), as: AccountsListResult.self).accounts
    }

    /// Feature flags from the daemon's `ping` result. `nil` capabilities means an
    /// older daemon; callers treat every new feature as unsupported in that case.
    public func serverCapabilities() async throws -> ServerCapabilities? {
        try await call("ping", EmptyParams(), as: PingResult.self).capabilities
    }

    struct AccountsCreateParams: Encodable {
        let kind: String
        let label: String
        let configDir: String?
        enum CodingKeys: String, CodingKey {
            case kind, label
            case configDir = "config_dir"
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(label, forKey: .label)
            try container.encodeIfPresent(configDir, forKey: .configDir)
        }
    }

    /// Register a NEW credential account (`accounts.create`): the daemon derives a
    /// fresh config-home + id, creates the dir, appends it to config.toml, reloads, and
    /// returns the refreshed list. Only non-secret metadata is written — the caller then
    /// drives login into the new account's config-home. Returns the refreshed accounts.
    @discardableResult
    public func accountsCreate(kind: String, label: String, configDir: String? = nil) async throws -> [CredentialAccount] {
        try await call("accounts.create",
                       AccountsCreateParams(kind: kind, label: label, configDir: configDir),
                       as: AccountsListResult.self)
            .accounts
    }

    struct AccountsRemoveParams: Encodable {
        let id: String
    }

    /// Unregister an account (`accounts.remove`): the daemon drops its `[[accounts]]`
    /// block from config.toml and reloads, returning the refreshed list. Does NOT delete
    /// the account's config-home or credentials — the entry can be re-added later. THROWS
    /// the server's `APIError` on an older daemon that lacks the method.
    @discardableResult
    public func accountsRemove(id: String) async throws -> [CredentialAccount] {
        try await call("accounts.remove",
                       AccountsRemoveParams(id: id),
                       as: AccountsListResult.self)
            .accounts
    }

    /// The running daemon's version/protocol plus any staged update the fleet build step pre-staged
    /// (`server.staged_update`). Parameterless read; THROWS the server's `APIError` on a daemon too
    /// old to know the method, so callers that want a quiet degrade use `try?` (mirrors
    /// `accountsList`). `staged` is nil when nothing is staged.
    public func stagedUpdate() async throws -> StagedUpdate {
        try await call("server.staged_update", EmptyParams(), as: StagedUpdate.self)
    }

    /// Activate the staged build (`server.apply_staged_update`): the daemon swaps its binary and
    /// re-execs via live-handoff, keeping agent panes alive. Because the daemon replaces ITSELF, the
    /// single-shot command socket may return the `ok` ack OR drop mid-handoff (a thrown transport
    /// error); callers treat a transport drop here as "restart in progress" and re-poll
    /// `stagedUpdate()`. Distinct server errors surface as thrown `APIError`:
    /// `apply_staged_update_failed` (handoff rolled back — the OLD build is still serving) and
    /// `apply_staged_update_disk_stale` (new build running, but the on-disk path was not updated).
    public func applyStagedUpdate() async throws {
        _ = try await call("server.apply_staged_update", EmptyParams(), as: OkAck.self)
    }

    struct FsListDirParams: Encodable {
        let path: String?
        enum CodingKeys: String, CodingKey { case path }
        // Omit `path` when nil so the daemon defaults to $HOME (rather than sending null).
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(path, forKey: .path)
        }
    }

    /// List one directory on the connected machine (`fs.list_dir`), for the new-agent folder browser.
    /// `path` nil → the daemon's `$HOME`; a leading `~` expands there. Returns the resolved absolute
    /// path + entries (dirs first). THROWS `APIError` (`not_a_directory`) for a non-directory, and on
    /// a daemon too old to know the method — callers browsing folders use `try?` to degrade to manual
    /// path entry.
    public func listDir(path: String?) async throws -> DirListing {
        try await call("fs.list_dir", FsListDirParams(path: path), as: DirListing.self)
    }

    struct AgentKindsResult: Decodable {
        let kinds: [AgentKind]
    }

    /// The known agent kinds and whether each harness is installed on the connected machine
    /// (`agent.kinds`). The new-agent picker offers only the installed ones. THROWS on an older daemon
    /// lacking the method, so callers `try?`-degrade to a static kind list.
    public func agentKinds() async throws -> [AgentKind] {
        try await call("agent.kinds", EmptyParams(), as: AgentKindsResult.self).kinds
    }

    /// The complete pane set, as a value that carries its own provenance.
    ///
    /// `SessionRecovery.observe` takes this rather than `[AgentInfo]` because an
    /// array can be filtered and a `PaneSnapshot` cannot be constructed outside
    /// the module. A partial listing silently unsubscribes every omitted pane,
    /// and their silence afterwards is indistinguishable from having no output —
    /// so "this is the whole set" is enforced by where the value came from.
    public func paneSnapshot() async throws -> PaneSnapshot {
        PaneSnapshot(agents: try await agentList())
    }

    struct ReadParams: Encodable {
        let target: String
        let source: ReadSource
        let format: ReadFormat
        let lines: UInt32?
    }

    /// Reads a pane. `lines` is clamped by the server to 1000 and defaults to 80.
    ///
    /// Requesting `.ansi` with `.detection` silently yields plain text, so this
    /// refuses that combination rather than returning unstyled output that the
    /// caller believes is styled.
    /// Defaults to `.recentUnwrapped`: `read` is the REFLOWED-SNAPSHOT surface —
    /// a 100-column pane at readable size does not fit a phone, so a transcript
    /// reflowed to the phone's width is the right default for skimming. Styling
    /// survives it. This is now the COMPLEMENT to the live path, not the only
    /// option: `streamTerminal(pane:)` renders a real grid-faithful VT from the
    /// raw byte stream, and `setPTYSize(...)` drives the actual PTY geometry that
    /// `PaneInfo` never exposed. `read` stays the cheap, reflowed snapshot.
    public func read(
        pane: String,
        source: ReadSource = .recentUnwrapped,
        format: ReadFormat = .ansi,
        lines: UInt32? = nil
    ) async throws -> PaneRead {
        if format == .ansi && source == .detection {
            throw APIError(
                code: "herdrkit_invalid_read",
                message: "source=detection ignores format=ansi and returns plain text; "
                    + "use .visible or .recent for styled output"
            )
        }
        let params = ReadParams(target: pane, source: source, format: format, lines: lines)
        return try await call("agent.read", params, as: PaneReadResult.self).read
    }

    struct PromptParams: Encodable {
        let target: String
        let text: String
        let wait: PromptWaitOptions?
    }

    /// The `wait` block herdr's `agent.prompt` accepts: block until the agent
    /// settles into one of `until` (an AgentStatus set) or `timeoutMs` elapses.
    /// Passing it is what makes the server report a REAL `delivery` (submitted vs
    /// written_to_pty); the no-wait path returns an unconditional written_to_pty.
    struct PromptWaitOptions: Encodable {
        let until: [String]
        let timeoutMs: Int?
        enum CodingKeys: String, CodingKey {
            case until
            case timeoutMs = "timeout_ms"
        }
    }

    /// The full AgentStatus set. Passed as `agent.prompt`'s `wait.until` so the
    /// server returns AS SOON AS it has classified delivery (every real status is
    /// in the set, so the initial wait-match succeeds immediately and no status
    /// timeout can fire) — the point is the truthful `delivery`, not to block for a
    /// particular status.
    public static let anyAgentStatus = ["working", "idle", "blocked", "done", "unknown"]

    /// Submits prompt text as intent rather than as raw keystrokes.
    ///
    /// Pass `waitUntil` (a set of AgentStatus wire values, e.g. `anyAgentStatus`)
    /// to have the server report a real `delivery`; without it herdr returns an
    /// unconditional `writtenToPty`, so the app cannot tell a started turn from a
    /// stranded draft. Returns the server's `delivery` (nil when it did not
    /// determine one). THROWS the server's `APIError` on rejection (agent_not_ready
    /// / agent_input_pending / agent_prompt_not_received / timeout), so a
    /// non-delivery is never silent.
    @discardableResult
    public func prompt(
        pane: String,
        text: String,
        waitUntil: [String]? = nil,
        timeoutMs: Int? = nil
    ) async throws -> PromptDelivery? {
        let wait = waitUntil.map { PromptWaitOptions(until: $0, timeoutMs: timeoutMs) }
        let result = try await call(
            "agent.prompt", PromptParams(target: pane, text: text, wait: wait), as: PromptResult.self)
        return result.delivery
    }

    struct SendTextParams: Encodable {
        let paneID: String
        let text: String
        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case text
        }
    }

    /// Types literal characters into a pane. Does not submit — Enter is a
    /// separate call, so nothing executes without a deliberate second action.
    public func sendText(pane: String, text: String) async throws {
        _ = try await call("pane.send_text", SendTextParams(paneID: pane, text: text), as: JSONNull.self)
    }

    /// Opens a persistent `pane.input.stream` write channel for one pane (issue
    /// #62), the write-side mirror of `streamTerminal`. Returns nil when the
    /// transport cannot provide one (e.g. the in-memory test transport) — the
    /// caller then uses per-call `sendText`. Feature detection is by ATTEMPT:
    /// `PaneInputChannel.start()` throws against a daemon lacking the method (or an
    /// older server), so the caller falls back on the throw.
    public func openPaneInput(pane: String) -> PaneInputChannel? {
        guard let citadel = transport as? CitadelTransport else { return nil }
        let env = RequestEnvelope(
            id: "herdrkit:pane.input.stream:\(pane)",
            method: "pane.input.stream",
            params: PaneInputStreamParams(paneID: pane)
        )
        guard let data = try? encoder.encode(env) else { return nil }
        return citadel.openInputChannel(String(decoding: data, as: UTF8.self))
    }

    struct RegisterDeviceParams: Encodable {
        let deviceToken: String
        let platform: String
        let notifyNeedsInput: Bool
        let notifyDies: Bool
        let notifyFinishes: Bool
        let notifyGram: Bool
        /// Public pane ids the owner muted on this device — the server skips their
        /// pushes. The client owns the set and sends the full list each time.
        let mutedPanes: [String]
        enum CodingKeys: String, CodingKey {
            case deviceToken = "device_token"
            case platform
            case notifyNeedsInput = "notify_needs_input"
            case notifyDies = "notify_dies"
            case notifyFinishes = "notify_finishes"
            case notifyGram = "notify_gram"
            case mutedPanes = "muted_panes"
        }
    }

    /// Register this device's APNs token so the server can push agent transitions (needs-you /
    /// finished / stopped) and gram messages even while the app is closed, filtered by the user's
    /// category prefs. Idempotent — safe to re-send on every (re)connect and whenever a token or
    /// pref changes. A server that does not yet implement the method (or the `notify_gram` field)
    /// just ignores what it does not know, and an older server throws, which the caller ignores.
    public func registerDevice(
        token: String, needsInput: Bool, dies: Bool, finishes: Bool, gram: Bool,
        mutedPanes: [String] = []
    ) async throws {
        _ = try await call("notifications.register_device",
                           RegisterDeviceParams(deviceToken: token, platform: "apns",
                                                notifyNeedsInput: needsInput, notifyDies: dies,
                                                notifyFinishes: finishes, notifyGram: gram,
                                                mutedPanes: mutedPanes),
                           as: JSONNull.self)
    }

    struct RegisterActivityParams: Encodable {
        let activityPushToken: String
        enum CodingKeys: String, CodingKey {
            case activityPushToken = "activity_push_token"
        }
    }

    /// Register a Live Activity's PER-ACTIVITY push token so the server can update the
    /// lock-screen / Dynamic Island widget with the session's agent status while the app is
    /// closed. Distinct from `registerDevice` (that is the one device APNs token; this is one
    /// token per running Live Activity). Idempotent — safe to re-send on (re)connect and each
    /// time the token rotates. A server that does not implement the method throws, which the
    /// caller ignores (the widget still updates in the foreground).
    public func registerActivity(token: String) async throws {
        _ = try await call("notifications.register_activity",
                           RegisterActivityParams(activityPushToken: token),
                           as: JSONNull.self)
    }

    /// Stop pushing to a Live Activity token (the activity ended / the session disconnected),
    /// so the server prunes it instead of pushing to a dead activity. Best-effort like the above.
    public func unregisterActivity(token: String) async throws {
        _ = try await call("notifications.unregister_activity",
                           RegisterActivityParams(activityPushToken: token),
                           as: JSONNull.self)
    }

    // MARK: - Gram (owner<->agent messages)

    struct GramListParams: Encodable {
        let callerPaneID: String?
        let onlyQueue: Bool
        let unreadOnly: Bool
        /// Omitted when nil, so an unconditional fetch sends the same JSON it always
        /// did and a daemon without the feature sees no new field at all.
        var ifUnchangedDigest: String?
        enum CodingKeys: String, CodingKey {
            case callerPaneID = "caller_pane_id"
            case onlyQueue = "only_queue"
            case unreadOnly = "unread_only"
            case ifUnchangedDigest = "if_unchanged_digest"
        }
    }

    /// The owner view of the gram store: every message, both directions, newest
    /// first. The app is the owner, so it omits `caller_pane_id` (supplying one
    /// would select an agent view). `unreadOnly` narrows to unread agent->owner
    /// messages. Throws the server's `APIError` on an older server that lacks gram.
    /// Reads the inbox. `ifUnchangedDigest` makes the fetch conditional: pass the
    /// digest from the previous answer and a daemon that still has the same store
    /// replies "unchanged" with no messages, which is the difference between a few
    /// hundred bytes and the whole store on a 6-second poll.
    ///
    /// Needs no capability gate. `GramListParams` is not `deny_unknown_fields`, and a
    /// daemon predating this (0.8.2, measured) IGNORES the field and returns the full
    /// list — which decodes as a normal changed answer. An old daemon therefore behaves
    /// exactly as before rather than erroring.
    public func gramList(
        unreadOnly: Bool = false, ifUnchangedDigest: String? = nil
    ) async throws -> GramListAnswer {
        let result = try await call(
            "gram.list",
            GramListParams(callerPaneID: nil, onlyQueue: false, unreadOnly: unreadOnly,
                           ifUnchangedDigest: ifUnchangedDigest),
            as: GramListResult.self)
        return GramListAnswer(
            messages: result.messages, digest: result.digest, storeID: result.storeID)
    }

    /// Whether the connected daemon is our fork or the upstream base.
    public enum ForkProbe: Sendable, Equatable {
        /// Has the fork-only methods (gram, live terminal, push).
        case isFork
        /// The base daemon — rejected a fork-only method as unknown.
        case notFork
        /// Couldn't tell (network/transport error, or an unexpected API error on a
        /// well-formed call). Callers should NOT prompt on this — assume fork.
        case indeterminate
    }

    /// Detect the fork by calling a fork-only method (`gram.list`). The base daemon
    /// parses `method` as an enum, so it cannot even DESERIALIZE an unknown method and
    /// answers `invalid_request` / "unknown variant" — an outcome a well-formed
    /// `gram.list` never produces on the fork (which returns a list, or
    /// `gram_unavailable` when the shared server is down). Everything that is not a
    /// definitive "unknown method" is treated as `indeterminate`, so a real fork user
    /// is never falsely told to install the fork (a false positive is worse than a
    /// missed one — the notice is only advisory).
    public func probeFork() async -> ForkProbe {
        do {
            // A success line that decodes to NO messages is not proof of a fork. This
            // probe sends no `ifUnchangedDigest`, and an unconditional `gram.list` on
            // the fork always answers with a list — so nil means the line was not a
            // gram-list answer at all (it decoded only because every field is
            // optional), which is exactly the case that used to surface as a
            // DecodingError before conditional fetch made `messages` optional.
            guard try await gramList().messages != nil else { return .indeterminate }
            return .isFork
        } catch let error as APIError {
            if error.code == "gram_unavailable" {
                return .isFork  // fork HAS gram.list; the shared server is just down
            }
            let lowered = error.message.lowercased()
            if error.code == "invalid_request",
                lowered.contains("unknown variant"),
                lowered.contains("gram.list")
            {
                // serde's variant error always names the offending tag ("unknown
                // variant `gram.list`, …"). Requiring the METHOD name narrows this to
                // the top-level method enum — so if gram.list ever gains an enum-typed
                // PARAM, an older fork that rejects that param's variant degrades to
                // indeterminate (quiet) instead of a false notFork.
                return .notFork
            }
            return .indeterminate  // some other API error on a well-formed call
        } catch {
            return .indeterminate  // network / decode / transport error
        }
    }

    /// A file already uploaded via `gramUploadFile`, ready to attach to a post.
    public struct GramFileAttachment: Sendable {
        public let uploadID: String
        public let name: String
        public let mime: String
        public init(uploadID: String, name: String, mime: String) {
            self.uploadID = uploadID
            self.name = name
            self.mime = mime
        }
    }

    struct GramFileUploadParams: Encodable {
        let uploadID: String
        let name: String
        let mime: String
        enum CodingKeys: String, CodingKey {
            case uploadID = "upload_id"
            case name, mime
        }
    }

    struct GramPostParams: Encodable {
        let text: String
        let to: String?
        let file: GramFileUploadParams?
    }

    /// The owner posts a message to agents. `to == nil` posts to the shared
    /// grab-queue any agent can claim; `to == <agentName>` addresses one live
    /// agent directly (the server rejects a name that is not a live agent).
    /// `attachment` attaches a file previously uploaded with `gramUploadFile`; the
    /// text may be empty when a file is attached. Returns the stored message.
    @discardableResult
    public func gramPost(
        text: String, to: String? = nil, attachment: GramFileAttachment? = nil
    ) async throws -> GramMessage {
        let file = attachment.map {
            GramFileUploadParams(uploadID: $0.uploadID, name: $0.name, mime: $0.mime)
        }
        return try await call("gram.post", GramPostParams(text: text, to: to, file: file),
                              as: GramMessageResult.self).message
    }

    struct GramMarkReadParams: Encodable { let id: String }

    /// The owner marks an agent->owner message read (clears its unread badge).
    public func gramMarkRead(id: String) async throws {
        _ = try await call("gram.mark_read", GramMarkReadParams(id: id), as: JSONNull.self)
    }

    struct GramDeleteParams: Encodable { let id: String }

    /// The owner deletes a gram message and any file attached to it, for good. As
    /// the owner the app sends no caller pane, so it may delete any message.
    public func gramDelete(id: String) async throws {
        _ = try await call("gram.delete", GramDeleteParams(id: id), as: JSONNull.self)
    }

    struct GramUploadChunkParams: Encodable {
        let uploadID: String
        let offset: UInt64
        let dataBase64: String
        enum CodingKeys: String, CodingKey {
            case uploadID = "upload_id"
            case offset
            case dataBase64 = "data_base64"
        }
    }

    /// Raw bytes per upload chunk. The SSH transport caps a whole request command
    /// near 120 KB, and the request JSON is base64'd twice on the way out (the
    /// inner `data_base64`, then the argv itself), a ~1.78x expansion. 48 KiB raw
    /// lands around 87 KB of command — safely under the cap with headroom.
    static let gramUploadChunkBytes = 48 * 1024

    /// Raw bytes per streamed frame. The streaming path has no argv, so the
    /// 120 KB command cap does not apply; this is the daemon's own
    /// `MAX_CHUNK_BYTES` (512 KiB), which keeps a base64 frame (~700 KB) under
    /// its 1 MiB request-line ceiling.
    static let gramStreamChunkBytes = 512 * 1024

    struct GramUploadStreamParams: Encodable {
        let uploadID: String
        enum CodingKeys: String, CodingKey {
            case uploadID = "upload_id"
        }
    }

    /// Opens a streaming upload channel, or nil when this transport or daemon
    /// cannot serve one. Feature-detected by `ping` CAPABILITY, never by
    /// attempting the method: an unknown method comes back with an EMPTY `id` and
    /// the connection closed, so the reply cannot be correlated to the attempt.
    public func gramOpenUploadChannel(uploadID: String) async -> GramUploadChannel? {
        guard let citadel = transport as? CitadelTransport else { return nil }
        // Three cache states, not two, and the probe is NOT written with `try?`:
        // `serverCapabilities()` both throws AND returns an Optional, so `try?`
        // flattens "the ping failed" into the same nil as "the daemon sent no
        // capabilities" — which would cache a transient error as `unsupported` and pin
        // this client to the per-chunk path for its whole lifetime, the exact outcome
        // the `unknown` state exists to prevent. A ping that SUCCEEDS is cached either
        // way, so a ten-file send pays one probe even against an old daemon; a ping
        // that THROWS leaves the cache `unknown` and is re-probed on the next upload.
        if case .unknown = streamCapability {
            do {
                let probed = try await serverCapabilities()
                streamCapability = probed?.gramUploadStream == true ? .supported : .unsupported
            } catch {
                return nil
            }
        }
        guard case .supported = streamCapability else { return nil }
        let env = RequestEnvelope(
            id: "herdrkit:gram.upload.stream:\(uploadID)",
            method: "gram.upload.stream",
            params: GramUploadStreamParams(uploadID: uploadID)
        )
        guard let data = try? encoder.encode(env) else { return nil }
        return citadel.openUploadChannel(String(decoding: data, as: UTF8.self))
    }

    /// Uploads a file's bytes in chunks and returns the `upload_id` to attach to a
    /// `gramPost`. Chunks are sent in order; the server validates each against the
    /// running offset. A single request per chunk keeps every one under the SSH
    /// command-size cap.
    ///
    /// `onProgress` (if given) is called on the main actor with `(bytesSent, totalBytes)`
    /// — once at 0, then throttled to ~1% steps as chunks land, and once at completion —
    /// so a caller can drive a determinate progress bar without flooding the UI on a
    /// large (≈2100-chunk) 100 MB upload.
    public func gramUploadFile(
        _ data: Data,
        onProgress: (@MainActor @Sendable (_ bytesSent: Int, _ totalBytes: Int) -> Void)? = nil
    ) async throws -> String {
        let uploadID = "app-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var offset = 0
        // Report at most ~once per 1% (or per chunk, whichever is coarser) so a big
        // file's thousands of round-trips don't schedule thousands of UI updates.
        let reportStep = max(Self.gramUploadChunkBytes, data.count / 100)
        var lastReported = -reportStep
        await onProgress?(0, data.count)
        while offset < data.count {
            let end = min(offset + Self.gramUploadChunkBytes, data.count)
            let chunk = data.subdata(in: offset..<end)
            _ = try await call(
                "gram.upload_chunk",
                GramUploadChunkParams(
                    uploadID: uploadID, offset: UInt64(offset),
                    dataBase64: chunk.base64EncodedString()),
                as: JSONNull.self)
            offset = end
            if offset == data.count || offset - lastReported >= reportStep {
                lastReported = offset
                await onProgress?(offset, data.count)
            }
        }
        return uploadID
    }

    /// A fresh `upload_id`. The daemon keys its staging file and its single-writer
    /// claim on this, and validates it as one safe path component.
    static func mintUploadID() -> String {
        "app-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// Uploads a file's bytes FROM DISK and returns the `upload_id` to attach to a
    /// `gramPost`.
    ///
    /// Streams over one held channel when the daemon advertises
    /// `gram_upload_stream`, else falls back to per-chunk `gram.upload_chunk` —
    /// still reading from disk, so neither path holds the whole file in memory
    /// and a 100 MB attachment costs one chunk of resident bytes.
    ///
    /// `onProgress` (if given) is called on the main actor with
    /// `(bytesSent, totalBytes)` — once at 0, then throttled to ~1% steps, and
    /// once at completion.
    public func gramUploadFile(
        fileURL: URL,
        onProgress: (@MainActor @Sendable (_ bytesSent: Int, _ totalBytes: Int) -> Void)? = nil
    ) async throws -> String {
        var uploadID = Self.mintUploadID()
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let total = (attributes[.size] as? NSNumber)?.intValue ?? 0

        // Open the FILE first, and only then the channel. A file we cannot read must
        // not cost an SSH channel and a daemon-side claim on this `upload_id` that is
        // then released asynchronously by the `defer` below.
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let channel = await gramOpenUploadChannel(uploadID: uploadID)
        var streaming = false
        if let channel {
            do {
                try await channel.start()
                streaming = true
            } catch {
                // An out-of-date capability flag, a daemon that advertises the
                // method but cannot serve it, or a channel that died before the
                // ack must not fail the send — fall back. A REAL rejection
                // (invalid_params, gram_unavailable, upload_in_progress,
                // gram_file_error) is rethrown: the staged file may be partially
                // written, so a fallback retry from offset 0 would be a second
                // writer on the same upload_id.
                await channel.close()
                if let fatal = Self.fatalStreamOpenError(error) { throw fatal }
                // Fall back under an id the daemon has NEVER seen. It takes its
                // single-writer claim at OPEN — before it asks the app anything — and
                // refuses a per-chunk write while that claim is held, so reusing this
                // id can lose a race with the claim's release and fail the send with
                // `upload_in_progress` for a reason unrelated to the file. Nothing
                // outside this function keys on the id: the caller passes whatever is
                // returned straight to `gramPost(attachment:)`.
                uploadID = Self.mintUploadID()
            }
        }
        defer { if let channel { Task { await channel.close() } } }

        let chunkBytes = streaming ? Self.gramStreamChunkBytes : Self.gramUploadChunkBytes

        // Report at most ~once per 1% (or per chunk, whichever is coarser) so a
        // big file's round-trips don't schedule thousands of UI updates. The total is
        // widened to the bytes actually read: the file is stat'd before the first
        // read, so one that GREW in between must not drive a determinate bar past
        // 100% (a shrunken one simply reports fewer bytes and ends early).
        let reportStep = max(chunkBytes, total / 100)
        var lastReported = -reportStep
        var offset = 0
        await onProgress?(0, total)
        while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            let encoded = chunk.base64EncodedString()
            if streaming, let channel {
                try await channel.sendChunk(offset: UInt64(offset), dataBase64: encoded)
            } else {
                _ = try await call(
                    "gram.upload_chunk",
                    GramUploadChunkParams(
                        uploadID: uploadID, offset: UInt64(offset), dataBase64: encoded),
                    as: JSONNull.self)
            }
            offset += chunk.count
            // Throttle ONLY: no `offset >= total` disjunct. That condition is
            // permanently true once the cursor passes the stat'd size, so a file that
            // grew after being stat'd reported every single chunk — the exact main-actor
            // flood the throttle exists to prevent. The terminal report is emitted once,
            // after the loop.
            if offset - lastReported >= reportStep {
                lastReported = offset
                await onProgress?(offset, max(total, offset))
            }
        }
        // One terminal report at the bytes ACTUALLY read, so a determinate bar always
        // lands on 100%. `(offset, offset)`, not `max(total, offset)`: a file that
        // SHRANK after the stat would otherwise leave the bar at `offset/total` — 50%
        // for a file half the stat'd size — and a shrink whose last chunk happens to
        // land on `reportStep` would emit no terminal report at all.
        if lastReported != offset || total != offset {
            await onProgress?(offset, offset)
        }
        // The daemon frees its single-writer claim on the `upload_id` only when it
        // observes EOF on the upload connection, and it REFUSES a `gram.post` that
        // would finalize an upload a stream still owns. The caller posts immediately
        // after this returns, over the already-warm command connection, so returning
        // before the teardown completes makes that post race the claim release and
        // fail with `upload_in_progress` after a fully successful upload.
        if streaming, let channel {
            await channel.closeAndWait()
        }
        return uploadID
    }

    /// A streaming-open failure the caller must NOT retry per-chunk, or nil when
    /// falling back is safe. Only a daemon-side REJECTION of the UPLOAD is fatal;
    /// transport, capability and availability failures are what the fallback exists
    /// for, because on those paths the daemon read no frame and staging is untouched.
    static func fatalStreamOpenError(_ error: Error) -> Error? {
        guard case GramUploadChannel.ChannelError.remoteError(let api) = error else { return nil }
        // `invalid_request`: an older daemon's answer to an unknown method.
        // `server_unavailable`: the open handshake timed out waiting on the daemon's
        // single-threaded app loop (5 s), or the daemon is shutting down. Neither
        // says anything about the upload, so both fall back rather than failing the
        // send — a busy app thread must not abort a whole batch.
        let recoverable = ["invalid_request", "server_unavailable"]
        return recoverable.contains(api.code) ? nil : api
    }

    struct GramGetFileParams: Encodable { let id: String }

    /// Downloads the file attached to a message and returns its name, mime, and
    /// bytes. As the owner the app sends no caller pane and may download any file.
    /// The bytes come back inline (base64) in one reply.
    public func gramGetFile(id: String) async throws -> (name: String, mime: String, data: Data) {
        let result = try await call("gram.get_file", GramGetFileParams(id: id),
                                    as: GramFileContentResult.self)
        guard let data = Data(base64Encoded: result.dataBase64) else {
            throw GramError.invalidFileData
        }
        return (result.name, result.mime, data)
    }

    struct SendKeysParams: Encodable {
        let target: String
        let keys: [String]
    }

    /// Sends named keys (e.g. "Enter", "Escape", "Up") to an AGENT pane, for dialog
    /// navigation and turn control.
    ///
    /// Goes through `agent.send_keys`, which does agent-specific work `pane.send_keys`
    /// does not: it refuses a pane whose running process is not the expected agent, and
    /// records a turn abort for keys that interrupt one. Use it only where the pane
    /// really hosts an agent — the server rejects anything else with `agent_not_found`.
    /// For a plain shell pane use `sendPaneKeys`.
    public func sendKeys(pane: String, keys: [String]) async throws {
        _ = try await call("agent.send_keys", SendKeysParams(target: pane, keys: keys), as: JSONNull.self)
    }

    struct PaneSendKeysParams: Encodable {
        let paneID: String
        let keys: [String]
        enum CodingKeys: String, CodingKey {
            case keys
            case paneID = "pane_id"
        }
    }

    /// Sends named keys to ANY pane, agent or not.
    ///
    /// The counterpart to `sendKeys` for panes that host a plain shell — the sign-in and
    /// sign-out flows split a fresh shell and need to press Enter in it. Those flows used
    /// `sendKeys`, and every one of them failed: `agent.send_keys` resolves a pane id only
    /// when that pane is an agent terminal, so a bare shell came back as
    /// `agent target <pane> not found`.
    public func sendPaneKeys(pane: String, keys: [String]) async throws {
        _ = try await call("pane.send_keys", PaneSendKeysParams(paneID: pane, keys: keys), as: JSONNull.self)
    }

    // MARK: - Spawning agents

    /// A new pane splits off horizontally (`right`) or vertically (`down`). herdr
    /// supports only these two — there is no left/up split.
    public enum SplitDirection: String, Sendable {
        case right, down
    }

    struct PaneSplitParams: Encodable {
        let direction: String
        let cwd: String?
        let focus: Bool
    }

    struct PaneInfoResult: Decodable {
        let pane: PaneRef
        /// Only the id is needed here; the rest of `pane` is deliberately not
        /// modelled so a schema addition on the server cannot break this decode.
        struct PaneRef: Decodable {
            let paneID: String
            enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
        }
    }

    /// Splits the currently focused pane and returns the NEW pane's id. `cwd` is
    /// the working directory the new pane (and the agent started in it) runs in —
    /// the "folder" of the new-agent form; nil follows the split pane's cwd.
    /// No target pane is sent, so the server splits whatever is focused.
    ///
    /// `focus` defaults to true, which is right for a pane the user ASKED for and is
    /// about to look at. Pass false for a BACKGROUND pane the app drives on the user's
    /// behalf — sign-in and log-out run a command in a pane the user never sees, and
    /// focusing it yanks the box's focus away from whatever they were actually doing.
    public func splitPane(cwd: String?, direction: SplitDirection = .down,
                          focus: Bool = true) async throws -> String {
        let params = PaneSplitParams(direction: direction.rawValue, cwd: cwd, focus: focus)
        return try await call("pane.split", params, as: PaneInfoResult.self).pane.paneID
    }

    struct AgentStartParams: Encodable {
        let name: String
        let kind: String
        let paneID: String
        enum CodingKeys: String, CodingKey {
            case name, kind
            case paneID = "pane_id"
        }
    }

    struct AgentStartedResult: Decodable {
        let agent: AgentInfo
    }

    /// Starts an agent of `kind` (claude/codex/gemini/…) named `name` in an
    /// existing pane (the one from `splitPane`). Returns the started agent.
    ///
    /// NOTE: this only INITIATES launch. `agent.start` returns while the agent is
    /// still `launch_pending`, and `agent.prompt` refuses (agent_not_ready) for a
    /// variable, sometimes-long window until the agent registers as a promptable
    /// known agent with a composer. There is no reliable client-pollable readiness
    /// flag (`interactive_ready` is not populated on this path), so we do NOT
    /// auto-deliver a task after start. The caller opens the new pane instead and
    /// lets the terminal's own input router send the task as a prompt once the
    /// pane reports a composer (`InputMode.intent`). See `NewAgentView.start`.
    public func startAgent(name: String, kind: String, paneID: String) async throws -> AgentInfo {
        let params = AgentStartParams(name: name, kind: kind, paneID: paneID)
        return try await call("agent.start", params, as: AgentStartedResult.self).agent
    }

    struct PaneTarget: Encodable {
        let paneID: String
        enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
    }

    /// Closes a pane — used to clean up the pane a failed spawn left behind, so a
    /// retry does not accumulate orphan panes.
    public func closePane(paneID: String) async throws {
        _ = try await call("pane.close", PaneTarget(paneID: paneID), as: JSONNull.self)
    }

    struct AgentTargetParams: Encodable {
        let target: String
    }

    /// `agent.restart` params. `account` is the credential-account id to swap the
    /// agent onto; it is OMITTED when nil (a plain in-place restart) via the custom
    /// `encode`, so a no-account restart sends exactly the old `{ target }` payload
    /// and an older daemon is unaffected. Mirrors the server's optional/skip-if-none.
    struct AgentRestartParams: Encodable {
        let target: String
        let account: String?

        enum CodingKeys: String, CodingKey {
            case target, account
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(target, forKey: .target)
            try container.encodeIfPresent(account, forKey: .account)
        }
    }

    struct AgentInfoResult: Decodable {
        let agent: AgentInfo
    }

    /// Restarts an agent in place: the daemon kills its harness process and
    /// reopens the SAME session with `--resume`, keeping the pane and identity.
    /// `target` is the pane id (or agent name). Passing `account` reopens the
    /// session on that credential subscription instead (the "swap subscription"
    /// action); nil keeps the current account. Throws when the agent has no
    /// resumable session (`no_resumable_session` — not a herdr-launched agent, or
    /// none reported). Returns the restarted agent.
    @discardableResult
    public func restartAgent(target: String, account: String? = nil) async throws -> AgentInfo {
        try await call("agent.restart", AgentRestartParams(target: target, account: account),
                       as: AgentInfoResult.self)
            .agent
    }

    /// Wire payload shared by the explicit prepare and confirm calls. False
    /// `confirm` and nil optionals are omitted so the prepare request stays the
    /// minimal `{ target, to, account? }` contract.
    struct AgentTransferSessionParams: Encodable {
        let target: String
        let to: AgentSessionTransferHarness
        let account: String?
        let transferID: String?
        let confirm: Bool

        enum CodingKeys: String, CodingKey {
            case target, to, account, confirm
            case transferID = "transfer_id"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(target, forKey: .target)
            try container.encode(to, forKey: .to)
            try container.encodeIfPresent(account, forKey: .account)
            try container.encodeIfPresent(transferID, forKey: .transferID)
            if confirm { try container.encode(true, forKey: .confirm) }
        }
    }

    /// Stage and verify a native destination transcript while the source harness
    /// remains live. The returned agent carries `sessionTransfer`; the caller must
    /// review its counts before making the separate confirmation call.
    @discardableResult
    public func prepareAgentSessionTransfer(
        target: String,
        to harness: AgentSessionTransferHarness,
        account: String? = nil
    ) async throws -> AgentInfo {
        try await call(
            "agent.transfer_session",
            AgentTransferSessionParams(
                target: target, to: harness, account: account,
                transferID: nil, confirm: false),
            as: AgentInfoResult.self
        ).agent
    }

    /// Confirm one exact prepared transfer. Herdr first returns the durable
    /// `verifyingCutover` phase while the source stays live, then owns cutover and
    /// rollback; this call never silently prepares a replacement transaction.
    @discardableResult
    public func confirmAgentSessionTransfer(
        target: String,
        to harness: AgentSessionTransferHarness,
        account: String? = nil,
        transferID: String
    ) async throws -> AgentInfo {
        try await call(
            "agent.transfer_session",
            AgentTransferSessionParams(
                target: target, to: harness, account: account,
                transferID: transferID, confirm: true),
            as: AgentInfoResult.self
        ).agent
    }

    struct AgentRenameParams: Encodable {
        let target: String
        let name: String
    }

    /// Renames an agent (`agent.rename`): sets the agent's `name`, which becomes a
    /// resolvable mention target daemon-side (`herdr agent read <name>` / another agent
    /// prompting `<name>`). `target` is the pane id (or the current name). The server
    /// enforces the name grammar `^[a-z][a-z0-9_-]{0,31}$`, so callers pass a name already
    /// coerced by `AgentName.normalize`; it still THROWS `APIError` for a duplicate
    /// (`agent_name_taken`) or an otherwise invalid name. Returns the updated agent.
    @discardableResult
    public func renameAgent(target: String, name: String) async throws -> AgentInfo {
        try await call("agent.rename", AgentRenameParams(target: target, name: name),
                       as: AgentInfoResult.self)
            .agent
    }

    /// `agent.archive` params. `reason`/`by`/`force` are OMITTED when nil/false so a plain
    /// archive sends `{ target }` and matches the server's optional/skip-if-none.
    struct AgentArchiveParams: Encodable {
        let target: String
        let reason: String?
        let by: String?
        let force: Bool

        enum CodingKeys: String, CodingKey {
            case target, reason, by, force
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(target, forKey: .target)
            try container.encodeIfPresent(reason, forKey: .reason)
            try container.encodeIfPresent(by, forKey: .by)
            if force { try container.encode(true, forKey: .force) }
        }
    }

    /// Archives an agent (`agent.archive`, issue #173): the daemon releases its pane
    /// but preserves the session ref so `agent.unarchive` can resume it later. `target`
    /// is the pane id (or agent name). The server REJECTS archiving an agent that is
    /// mid-turn unless `force` — that surfaces as an `APIError` the caller shows.
    /// Returns the archived agent (its `archived` block now set).
    ///
    /// PASS `by` AND `reason`. They are optional on the wire, and omitting them is not
    /// neutral: the daemon then records `by: "api"` with no reason, which is exactly what
    /// it records for bookkeeping on a pane that merely died. An archive that does not say
    /// who did it or why is indistinguishable from one nobody decided — a real ambiguity
    /// downstream, where tooling reads the `archived` block as evidence a seat is gone.
    /// Both are `encodeIfPresent`, so a caller that passes neither still sends the exact
    /// bytes it did before.
    @discardableResult
    public func archiveAgent(
        target: String, reason: String? = nil, by: String? = nil, force: Bool = false
    ) async throws -> AgentInfo {
        try await call("agent.archive",
                       AgentArchiveParams(target: target, reason: reason, by: by, force: force),
                       as: AgentInfoResult.self)
            .agent
    }

    /// `agent.unarchive` params. `fresh` (start a clean agent instead of resuming the
    /// preserved session) is OMITTED when false.
    struct AgentUnarchiveParams: Encodable {
        let target: String
        let fresh: Bool

        enum CodingKeys: String, CodingKey {
            case target, fresh
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(target, forKey: .target)
            if fresh { try container.encode(true, forKey: .fresh) }
        }
    }

    /// Unarchives an agent (`agent.unarchive`, issue #173): resumes the preserved
    /// session into a fresh pane, restoring the agent's terminal identity. `target` is
    /// the archived agent's name or terminal id. Returns the resumed agent.
    @discardableResult
    public func unarchiveAgent(target: String, fresh: Bool = false) async throws -> AgentInfo {
        try await call("agent.unarchive", AgentUnarchiveParams(target: target, fresh: fresh),
                       as: AgentInfoResult.self)
            .agent
    }

    struct PaneRenameParams: Encodable {
        let paneID: String
        let label: String
        enum CodingKeys: String, CodingKey {
            case label
            case paneID = "pane_id"
        }
    }

    /// Renames a pane (`pane.rename`): sets the pane's manual `label`, which shows in
    /// `pane.list` — so a plain terminal can be mentioned to an agent ("check the terminal
    /// labelled <label>"; the agent lists panes, matches the label, then reads that pane).
    /// Works on any pane, agent or not. The server trims the label. The returned pane is
    /// ignored (callers keep the app-local label in sync separately).
    public func renamePane(paneID: String, label: String) async throws {
        _ = try await call("pane.rename", PaneRenameParams(paneID: paneID, label: label),
                           as: PaneInfoResult.self)
    }

    /// True when `pane` reports an agent WITH a composer — the observable proxy for
    /// "a prompt will land NOW". This is the STRICTER new-agent PRE-FILL gate
    /// (`InputRouter.isPromptable(for:)`), deliberately NOT the reply-routing gate
    /// (`mode(for:)`, which needs only a named agent): auto-delivering a just-
    /// spawned agent's task unattended warrants holding out for a confirmed
    /// composer, since there is no reliable readiness flag (interactive_ready is nil
    /// on this path). The UI polls THIS to learn when a just-spawned agent can
    /// receive its pre-filled task — then delivers it as a prompt, never as rawKeys
    /// send_text into a not-ready agent. Absent pane, or an agent with no composer,
    /// is NOT promptable (false).
    public func isPromptable(pane: String) async throws -> Bool {
        guard let info = try await agentList().first(where: { $0.paneID == pane }) else { return false }
        return InputRouter().isPromptable(for: info)
    }

    // MARK: - Events

    /// Opens the persistent event stream.
    ///
    /// The first line is `subscriptionStarted`; the connection then stays open.
    /// Pane-scoped subscriptions need a `paneID` — the server has no wildcard.
    public nonisolated func subscribe(
        _ subscriptions: [Subscription]
    ) -> AsyncThrowingStream<StreamLine, Error> {
        let encoder = JSONEncoder()
        let env = RequestEnvelope(
            id: "herdrkit:events.subscribe",
            method: "events.subscribe",
            params: SubscribeParams(subscriptions: subscriptions)
        )
        guard let data = try? encoder.encode(env) else {
            return AsyncThrowingStream { $0.finish(throwing: TransportError.closedBeforeResponse) }
        }
        let requestLine = String(decoding: data, as: UTF8.self)
        let raw = transport.stream(requestLine)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in raw {
                        continuation.yield(Self.classify(line))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated static func classify(_ line: String) -> StreamLine {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .other(raw: line) }

        if let result = obj["result"] as? [String: Any],
           result["type"] as? String == "subscription_started" {
            return .subscriptionStarted
        }
        if let event = obj["event"] as? [String: Any] {
            let kind = (event["type"] as? String) ?? (event["kind"] as? String) ?? "unknown"
            return .event(kind: kind, paneID: event["pane_id"] as? String, raw: line)
        }
        if let kind = obj["type"] as? String {
            return .event(kind: kind, paneID: obj["pane_id"] as? String, raw: line)
        }
        return .other(raw: line)
    }

    // MARK: - Live terminal stream

    /// Opens `pane.stream` — herdr's persistent server->client raw PTY byte firehose
    /// — and yields the opening `stream_started` ack (geometry + epoch) followed by
    /// the ordered `\n`-delimited frames. Cloned from `subscribe()`: same Transport
    /// line framing, no busy-poll (the server pushes as bytes arrive off the PTY). A
    /// line that fails to decode as a valid frame THROWS and finishes the stream — a
    /// stateful byte stream can't skip a corrupt line without desyncing the emulator,
    /// so the view surfaces the failure and re-opening the pane reseeds a fresh reset.
    /// The connection also ends when the peer closes or the task is cancelled (closing
    /// the SSH channel = unsubscribe).
    public nonisolated func streamTerminal(
        pane: String,
        includeHistory: Bool = true,
        maxFrameBytes: Int? = nil,
        scrollbackLines: Int? = nil,
        viewerID: String? = nil
    ) -> AsyncThrowingStream<TerminalStreamEvent, Error> {
        let encoder = JSONEncoder()
        let env = RequestEnvelope(
            id: "herdrkit:pane.stream:\(pane)",
            method: "pane.stream",
            params: PaneStreamParams(
                paneID: pane, includeHistory: includeHistory,
                resumeFrom: nil, epoch: nil,
                maxFrameBytes: maxFrameBytes, scrollbackLines: scrollbackLines,
                viewerID: viewerID)
        )
        guard let data = try? encoder.encode(env) else {
            return AsyncThrowingStream { $0.finish(throwing: TransportError.closedBeforeResponse) }
        }
        let requestLine = String(decoding: data, as: UTF8.self)
        let raw = transport.stream(requestLine)

        return AsyncThrowingStream { continuation in
            let task = Task {
                let decoder = JSONDecoder()
                var sawAck = false
                do {
                    for try await line in raw {
                        if !sawAck {
                            sawAck = true
                            switch Self.decodeStreamAck(line, decoder) {
                            case .started(let started):
                                continuation.yield(.started(started))
                                continue
                            case .error(let apiError):
                                // pane_not_found, or an older server rejecting the
                                // unknown method — surface it and stop cleanly.
                                continuation.finish(throwing: apiError)
                                return
                            case .undecodable:
                                // Not the ack we expected: fall through and try this
                                // line as a frame. If it is a valid frame it is
                                // yielded; if not, the strict decode below THROWS and
                                // ends the stream (a stray non-frame leading line is
                                // not silently swallowed).
                                break
                            }
                        }
                        // STRICT: every line after the ack must be a valid pane.bytes
                        // frame. A stateful byte stream cannot skip a corrupt line
                        // without desyncing the emulator (feeding the next frame mid
                        // escape-sequence), so a decode failure THROWS — the stream
                        // ends with an error, the view surfaces it, and re-opening the
                        // pane reseeds a fresh full-screen reset. The ack fall-through
                        // above lands here too, so a non-ack/non-frame leading line
                        // also fails loudly rather than being silently swallowed.
                        let frame = try decoder.decode(StreamFrame.self, from: Data(line.utf8))
                        continuation.yield(.frame(frame))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum StreamAck {
        case started(StreamStarted)
        case error(APIError)
        case undecodable
    }

    /// Classifies the first `pane.stream` line: the `stream_started` ack, a server
    /// error envelope, or something else (which the caller then re-tries as a frame).
    private nonisolated static func decodeStreamAck(_ line: String, _ decoder: JSONDecoder) -> StreamAck {
        let data = Data(line.utf8)
        if let err = try? decoder.decode(ErrorEnvelope.self, from: data) {
            return .error(err.error)
        }
        if let ok = try? decoder.decode(ResultEnvelope<StreamStarted>.self, from: data) {
            return .started(ok.result)
        }
        return .undecodable
    }

    /// Sets the pane's real PTY winsize and takes/releases geometry ownership.
    /// One-shot request/response on the single-shot control socket, dispatched via
    /// the same `call(...)` path as `read`/`sendText`. NOTE `lock:false` (the
    /// default) is NOT side-effect-free: the server applies the winsize resize FIRST
    /// and only then releases ownership, so this DOES resize the shared PTY (a
    /// co-viewing desktop reflows until its next render reclaims the size). `false`
    /// only means "don't PIN the geometry"; it does not mean "don't resize". cols/
    /// rows are clamped to the server's floor (cols>=4, rows>=2) before the round-trip.
    public func setPTYSize(
        pane: String,
        cols: Int,
        rows: Int,
        cellWidthPx: UInt32? = nil,
        cellHeightPx: UInt32? = nil,
        lock: Bool = false,
        viewerID: String? = nil,
        ttl: UInt64? = nil
    ) async throws -> PanePtySize {
        let clampedCols = min(max(cols, 4), Int(UInt16.max))
        let clampedRows = min(max(rows, 2), Int(UInt16.max))
        let params = PaneSetPtySizeParams(
            paneID: pane, cols: clampedCols, rows: clampedRows,
            cellWidthPx: cellWidthPx, cellHeightPx: cellHeightPx, lock: lock,
            viewerID: viewerID, ttl: ttl)
        return try await call("pane.set_pty_size", params, as: PanePtySize.self)
    }
}

/// Who the app reports as the actor when it archives an agent, and why.
///
/// Constants, not free text, for two readers. A person sees
/// "archived by herdrup · user action" on the archived row. Fleet tooling that treats the
/// `archived` block as evidence a seat is gone can match these EXACTLY to tell a deliberate
/// archive from bookkeeping on a dead pane — a distinction that was previously impossible,
/// because the app sent neither field and the daemon's `by: "api"` default is what a
/// reasonless archive looks like too.
///
/// `by` names the actor; `reason` says it was deliberate. Neither repeats the other, since
/// the row renders them joined.
public let appArchiveActor = "herdrup"
public let appArchiveReason = "user action"

/// Decodes any JSON value, for calls whose result body the client ignores.
struct JSONNull: Decodable {
    init(from decoder: Decoder) throws { _ = decoder }
}
