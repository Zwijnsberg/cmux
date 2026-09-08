import Foundation
import Observation

/// Commands the native UI can send to the hidden audio page.
@MainActor
protocol VoiceAgentAudioControlling: AnyObject {
    func setMuted(_ muted: Bool)
    func stop()
    func requestRecap(surfaceID: String?)
    /// Semantic mode on for one terminal (`surfaceID` non-nil, with the coding
    /// agent detected there) or off (`nil`).
    func setSemanticMode(surfaceID: String?, agent: String?)
    /// Send or Clear pressed on the hovering semantic box.
    func semanticCommand(_ command: VoiceSemanticCommand, surfaceID: String)
}

/// Buttons on the hovering semantic box. Every entrypoint (box button, voice)
/// ends in the sidecar's `semantic_send` / `semantic_clear` tools.
enum VoiceSemanticCommand: String {
    case send
    case clear
}

/// What the hovering semantic box shows for the terminal in semantic mode.
struct VoiceSemanticDraft: Equatable {
    enum Stage: String {
        /// Box is empty; the agent is listening for the idea.
        case idle
        /// A partial idea, restructured by the agent as the user talks.
        case drafting
        /// The consolidated prompt; the agent asked "Is this ready to send?".
        case final
    }

    var text: String
    var stage: Stage
    /// Set for one update when the sidecar reports a transition ("sent", "cleared").
    var event: String?
}

/// Single source of truth for the voice session as shown by the right-sidebar
/// Voice panel, the palette command, and the shortcut. Fed by the hidden
/// audio page through the `cmuxVoice` script-message bridge
/// (see `VoiceAgentAudioWebView`).
@MainActor
@Observable
final class VoiceAgentSessionState {
    static let shared = VoiceAgentSessionState()

    enum Phase: Equatable {
        case off
        case starting
        case connecting
        case listening
        case thinking
        case speaking
        case error
    }

    struct TranscriptLine: Identifiable, Equatable {
        enum Role: Equatable {
            case user
            case agent
        }

        let id: UUID
        var role: Role
        var text: String
        var isFinal: Bool
    }

    struct ActionChip: Identifiable, Equatable {
        let id: UUID
        var name: String
        var isFinished: Bool
        var summary: String?
    }

    var phase: Phase = .off
    var isMuted = false
    var lastError: String?
    var transcript: [TranscriptLine] = []
    var recentActions: [ActionChip] = []
    var uiSummary = ""
    var sidecar: VoiceAgentSidecarSession?
    /// True once the hidden page reports the bot's audio track is playing.
    var isAudioPlaying = false
    /// A recap the user asked for before the session was live; sent once it is.
    var pendingRecapSurfaceID: String??
    /// The one terminal whose Semantic mode button is on (nil = off everywhere).
    /// One at a time: the spoken brainstorm is about a single prompt.
    private(set) var semanticSurfaceID: UUID?
    /// The hovering box contents for `semanticSurfaceID`, as last reported by the sidecar.
    private(set) var semanticDraft = VoiceSemanticDraft(text: "", stage: .idle, event: nil)
    /// Coding agent detected in each terminal that had semantic mode on
    /// (`claude` / `codex`), reported by the terminal overlays.
    private(set) var semanticAgentBySurface: [UUID: String] = [:]
    /// Semantic mode was turned on before the call was live; announced once it is.
    private(set) var pendingSemanticSurfaceID: UUID?
    /// True while the audio page should be mounted (from start until stop).
    var isSessionRequested = false
    /// Whether the chat log already had lines when this session was started:
    /// the microphone was toggled off and on mid-conversation, so the agent
    /// opens with a short "Hey." instead of the first-session greeting.
    private(set) var isResumingConversation = false
    @ObservationIgnored weak var audioController: (any VoiceAgentAudioControlling)?

    private static let transcriptLimit = 200
    private static let actionLimit = 12

    var audioPageURL: URL? {
        guard isSessionRequested else { return nil }
        return sidecar?.audioPageURL(resumingConversation: isResumingConversation)
    }

    var isLive: Bool {
        switch phase {
        case .listening, .thinking, .speaking:
            return true
        case .off, .starting, .connecting, .error:
            return false
        }
    }

    var isBusy: Bool {
        phase == .starting || phase == .connecting
    }

    // MARK: - Transitions driven by the app

    func beginStarting() {
        lastError = nil
        recentActions = []
        // Decided once per session, before the audio page URL is built.
        isResumingConversation = !transcript.isEmpty
        phase = .starting
    }

    func fail(_ message: String) {
        lastError = message
        phase = .error
        isSessionRequested = false
        clearSemanticMode()
    }

    func reset() {
        phase = .off
        isAudioPlaying = false
        isSessionRequested = false
        isMuted = false
        finalizeOpenTranscriptLines()
        // The brainstorm lives in the call; without a call the glowing button
        // and its box would be stale.
        clearSemanticMode()
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        audioController?.setMuted(muted)
    }

    func clearTranscript() {
        transcript = []
        recentActions = []
    }

    // MARK: - Bridge messages from the audio page

    func handleBridgeMessage(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "status":
            handleStatus(dict["status"] as? String ?? "", message: dict["message"] as? String)
        case "transcript":
            let role: TranscriptLine.Role = (dict["role"] as? String) == "user" ? .user : .agent
            appendTranscript(role: role, text: dict["text"] as? String ?? "", isFinal: dict["final"] as? Bool ?? false)
        case "tool":
            handleTool(name: dict["name"] as? String ?? "", phase: dict["phase"] as? String ?? "", result: dict["result"])
        case "server":
            guard let data = dict["data"] as? [String: Any] else { return }
            switch data["type"] as? String {
            case "ui_state":
                if let summary = data["summary"] as? String {
                    uiSummary = summary
                }
            case "semantic_draft":
                handleSemanticDraft(data)
            default:
                break
            }
        case "error":
            lastError = dict["message"] as? String ?? String(localized: "voiceAgent.error.generic", defaultValue: "Something went wrong.")
        case "mic":
            isMuted = dict["muted"] as? Bool ?? isMuted
        default:
            break
        }
    }

    private func handleStatus(_ status: String, message: String?) {
        switch status {
        case "connecting":
            if isSessionRequested { phase = .connecting }
        case "audio-playing":
            isAudioPlaying = true
        case "ready", "listening":
            if isSessionRequested {
                let wasLive = isLive
                phase = .listening
                finalizeOpenTranscriptLines(role: .agent)
                // A Recap button press that arrived before the call was live.
                if !wasLive, let pending = pendingRecapSurfaceID {
                    pendingRecapSurfaceID = nil
                    audioController?.requestRecap(surfaceID: pending)
                }
                // Semantic mode turned on before the call was live.
                if !wasLive, let pending = pendingSemanticSurfaceID, pending == semanticSurfaceID {
                    pendingSemanticSurfaceID = nil
                    audioController?.setSemanticMode(surfaceID: pending.uuidString, agent: semanticAgentBySurface[pending])
                }
            }
        case "thinking":
            if isSessionRequested { phase = .thinking }
        case "speaking":
            if isSessionRequested { phase = .speaking }
        case "disconnected":
            if isSessionRequested, phase != .error {
                // The call ended from the far side (max duration, hang-up, or a crash).
                phase = .off
                isSessionRequested = false
                finalizeOpenTranscriptLines()
                clearSemanticMode()
            }
        case "error":
            fail(message ?? lastError ?? String(localized: "voiceAgent.error.generic", defaultValue: "Something went wrong."))
        default:
            break
        }
    }

    private func appendTranscript(role: TranscriptLine.Role, text: String, isFinal: Bool) {
        guard !text.isEmpty else { return }
        if let last = transcript.last, last.role == role, !last.isFinal {
            var updated = last
            switch role {
            case .user:
                // Interim user transcripts replace each other until finalized.
                updated.text = text
            case .agent:
                // Agent output arrives in word/sentence chunks; stitch them.
                updated.text = Self.joined(updated.text, text)
            }
            updated.isFinal = isFinal
            transcript[transcript.count - 1] = updated
        } else {
            transcript.append(TranscriptLine(id: UUID(), role: role, text: text, isFinal: isFinal))
        }
        if transcript.count > Self.transcriptLimit {
            transcript.removeFirst(transcript.count - Self.transcriptLimit)
        }
    }

    private func finalizeOpenTranscriptLines(role: TranscriptLine.Role? = nil) {
        for index in transcript.indices where !transcript[index].isFinal && (role == nil || transcript[index].role == role) {
            transcript[index].isFinal = true
        }
    }

    private func handleTool(name: String, phase: String, result: Any?) {
        guard !name.isEmpty else { return }
        if phase == "started" {
            recentActions.append(ActionChip(id: UUID(), name: name, isFinished: false, summary: nil))
        } else if let index = recentActions.lastIndex(where: { $0.name == name && !$0.isFinished }) {
            recentActions[index].isFinished = true
            if let dict = result as? [String: Any], let say = dict["say"] as? String {
                recentActions[index].summary = say
            }
        }
        if recentActions.count > Self.actionLimit {
            recentActions.removeFirst(recentActions.count - Self.actionLimit)
        }
    }

    // MARK: - Semantic mode

    func isSemanticModeOn(for surfaceID: UUID) -> Bool {
        semanticSurfaceID == surfaceID
    }

    /// Turns semantic mode on for `surfaceID` (moving it off any other
    /// terminal). Tells the sidecar at once when the call is live; otherwise
    /// the announcement waits for `listening`. Returns whether the caller
    /// still has to start a session.
    @discardableResult
    func enableSemanticMode(surfaceID: UUID) -> Bool {
        semanticSurfaceID = surfaceID
        semanticDraft = VoiceSemanticDraft(text: "", stage: .idle, event: nil)
        if isLive, let controller = audioController {
            pendingSemanticSurfaceID = nil
            controller.setSemanticMode(surfaceID: surfaceID.uuidString, agent: semanticAgentBySurface[surfaceID])
            return false
        }
        pendingSemanticSurfaceID = surfaceID
        return !isSessionRequested && phase != .starting
    }

    /// Turns semantic mode off; the box is discarded on both sides.
    func disableSemanticMode() {
        let wasOn = semanticSurfaceID != nil
        let wasPending = pendingSemanticSurfaceID != nil
        clearSemanticMode()
        if wasOn, !wasPending, isLive {
            audioController?.setSemanticMode(surfaceID: nil, agent: nil)
        }
    }

    /// The terminal overlay re-detected which coding agent (if any) runs in
    /// `surfaceID`. Only `claude` and `codex` open the hovering box.
    func updateSemanticAgent(surfaceID: UUID, agentID: String?) {
        let previous = semanticAgentBySurface[surfaceID]
        guard previous != agentID else { return }
        if let agentID {
            semanticAgentBySurface[surfaceID] = agentID
        } else {
            semanticAgentBySurface.removeValue(forKey: surfaceID)
        }
        // Keep the sidecar's phrasing ("Claude Code" / "Codex") current.
        if semanticSurfaceID == surfaceID, pendingSemanticSurfaceID == nil, isLive, let agentID {
            audioController?.setSemanticMode(surfaceID: surfaceID.uuidString, agent: agentID)
        }
    }

    /// Whether the hovering box should show for `surfaceID`: semantic mode is
    /// on there and Claude Code or Codex is the foreground program.
    func showsSemanticPromptBox(for surfaceID: UUID) -> Bool {
        isSemanticModeOn(for: surfaceID) && semanticAgentBySurface[surfaceID] != nil
    }

    func sendSemanticCommand(_ command: VoiceSemanticCommand) {
        guard let surfaceID = semanticSurfaceID, isLive else { return }
        audioController?.semanticCommand(command, surfaceID: surfaceID.uuidString)
    }

    private func clearSemanticMode() {
        semanticSurfaceID = nil
        pendingSemanticSurfaceID = nil
        semanticDraft = VoiceSemanticDraft(text: "", stage: .idle, event: nil)
    }

    private func handleSemanticDraft(_ data: [String: Any]) {
        let enabled = data["enabled"] as? Bool ?? true
        let reportedSurface = (data["surface_id"] as? String).flatMap(UUID.init(uuidString:))
        guard let semanticSurfaceID else {
            // The sidecar still has a box for a terminal we already turned off.
            if enabled, reportedSurface != nil, isLive {
                audioController?.setSemanticMode(surfaceID: nil, agent: nil)
            }
            return
        }
        guard enabled, reportedSurface == semanticSurfaceID else {
            // "disabled", or a box for another terminal: the sidecar is
            // behind an on/off flip here; our latest intent wins.
            return
        }
        let stage = VoiceSemanticDraft.Stage(rawValue: data["stage"] as? String ?? "") ?? .idle
        semanticDraft = VoiceSemanticDraft(
            text: data["text"] as? String ?? "",
            stage: stage,
            event: data["event"] as? String
        )
    }

    private static func joined(_ existing: String, _ chunk: String) -> String {
        guard let first = chunk.first else { return existing }
        if existing.isEmpty || existing.last?.isWhitespace == true || first.isWhitespace || first.isPunctuation {
            return existing + chunk
        }
        return existing + " " + chunk
    }
}
