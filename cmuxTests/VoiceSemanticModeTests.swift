import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Semantic mode: the per-terminal "Semantic mode" button and the hovering
/// brainstorm box. These cover the app-side state machine in
/// `VoiceAgentSessionState`: when the sidecar is told about the mode, how the
/// box mirrors `semantic_draft` server messages, and what turns it off.
@MainActor
struct VoiceSemanticModeTests {
    @MainActor
    final class RecordingAudioController: VoiceAgentAudioControlling {
        var semanticModeCalls: [(surfaceID: String?, agent: String?)] = []
        var commands: [(command: VoiceSemanticCommand, surfaceID: String)] = []
        var recaps: [String?] = []
        var stops = 0

        func setMuted(_ muted: Bool) {}
        func stop() { stops += 1 }
        func requestRecap(surfaceID: String?) { recaps.append(surfaceID) }
        func setSemanticMode(surfaceID: String?, agent: String?) { semanticModeCalls.append((surfaceID, agent)) }
        func semanticCommand(_ command: VoiceSemanticCommand, surfaceID: String) { commands.append((command, surfaceID)) }
    }

    private func liveState(controller: RecordingAudioController) -> VoiceAgentSessionState {
        let state = VoiceAgentSessionState()
        state.audioController = controller
        state.beginStarting()
        state.isSessionRequested = true
        state.handleBridgeMessage(["type": "status", "status": "listening"])
        #expect(state.isLive)
        return state
    }

    private func draftMessage(surface: UUID, text: String, stage: String, event: String? = nil, enabled: Bool = true) -> [String: Any] {
        var data: [String: Any] = [
            "type": "semantic_draft",
            "surface_id": surface.uuidString,
            "agent": "claude",
            "enabled": enabled,
            "text": text,
            "stage": stage,
        ]
        if let event { data["event"] = event }
        return ["type": "server", "data": data]
    }

    @Test func enablingWhileLiveTellsTheSidecarAtOnce() {
        let controller = RecordingAudioController()
        let state = liveState(controller: controller)
        let surface = UUID()
        state.updateSemanticAgent(surfaceID: surface, agentID: "claude")

        let needsSession = state.enableSemanticMode(surfaceID: surface)

        #expect(!needsSession)
        #expect(state.isSemanticModeOn(for: surface))
        #expect(controller.semanticModeCalls.count == 1)
        #expect(controller.semanticModeCalls.last?.surfaceID == surface.uuidString)
        #expect(controller.semanticModeCalls.last?.agent == "claude")
    }

    @Test func enablingBeforeTheCallIsLiveWaitsForListening() {
        let controller = RecordingAudioController()
        let state = VoiceAgentSessionState()
        state.audioController = controller
        let surface = UUID()

        let needsSession = state.enableSemanticMode(surfaceID: surface)

        #expect(needsSession, "no session was requested yet, so the caller starts one")
        #expect(state.isSemanticModeOn(for: surface))
        #expect(controller.semanticModeCalls.isEmpty)

        state.beginStarting()
        state.isSessionRequested = true
        state.handleBridgeMessage(["type": "status", "status": "connecting"])
        #expect(controller.semanticModeCalls.isEmpty)
        state.handleBridgeMessage(["type": "status", "status": "listening"])
        #expect(controller.semanticModeCalls.count == 1)
        #expect(controller.semanticModeCalls.last?.surfaceID == surface.uuidString)
        #expect(state.pendingSemanticSurfaceID == nil)
    }

    @Test func onlyOneTerminalIsInSemanticModeAtATime() {
        let controller = RecordingAudioController()
        let state = liveState(controller: controller)
        let first = UUID()
        let second = UUID()

        state.enableSemanticMode(surfaceID: first)
        state.enableSemanticMode(surfaceID: second)

        #expect(!state.isSemanticModeOn(for: first))
        #expect(state.isSemanticModeOn(for: second))
        #expect(controller.semanticModeCalls.map(\.surfaceID) == [first.uuidString, second.uuidString])
    }

    @Test func disablingTellsTheSidecarAndEmptiesTheBox() {
        let controller = RecordingAudioController()
        let state = liveState(controller: controller)
        let surface = UUID()
        state.enableSemanticMode(surfaceID: surface)
        state.handleBridgeMessage(draftMessage(surface: surface, text: "make login async", stage: "drafting"))
        #expect(state.semanticDraft.text == "make login async")

        state.disableSemanticMode()

        #expect(state.semanticSurfaceID == nil)
        #expect(state.semanticDraft.text.isEmpty)
        #expect(state.semanticDraft.stage == .idle)
        #expect(controller.semanticModeCalls.last?.surfaceID == nil)
    }

    @Test func draftMessagesReplaceTheBoxForTheSemanticTerminalOnly() {
        let controller = RecordingAudioController()
        let state = liveState(controller: controller)
        let surface = UUID()
        let other = UUID()
        state.enableSemanticMode(surfaceID: surface)

        state.handleBridgeMessage(draftMessage(surface: surface, text: "- login async", stage: "drafting"))
        #expect(state.semanticDraft == VoiceSemanticDraft(text: "- login async", stage: .drafting, event: nil))

        state.handleBridgeMessage(draftMessage(surface: surface, text: "- login async\n- add tests", stage: "drafting"))
        #expect(state.semanticDraft.text == "- login async\n- add tests", "each update replaces, never appends")

        state.handleBridgeMessage(draftMessage(surface: other, text: "stale box", stage: "final"))
        #expect(state.semanticDraft.text == "- login async\n- add tests", "another terminal's box is ignored")

        state.handleBridgeMessage(draftMessage(surface: surface, text: "Refactor login to async and add tests.", stage: "final"))
        #expect(state.semanticDraft.stage == .final)

        state.handleBridgeMessage(draftMessage(surface: surface, text: "", stage: "idle", event: "sent"))
        #expect(state.semanticDraft.text.isEmpty)
        #expect(state.semanticDraft.stage == .idle)
        #expect(state.semanticDraft.event == "sent")
        #expect(state.isSemanticModeOn(for: surface), "sending keeps the mode on for the next idea")
    }

    @Test func promptBoxShowsOnlyWhenClaudeOrCodexIsDetected() {
        let controller = RecordingAudioController()
        let state = liveState(controller: controller)
        let surface = UUID()
        state.enableSemanticMode(surfaceID: surface)
        #expect(!state.showsSemanticPromptBox(for: surface))

        state.updateSemanticAgent(surfaceID: surface, agentID: "codex")
        #expect(state.showsSemanticPromptBox(for: surface))
        #expect(controller.semanticModeCalls.last?.agent == "codex", "the sidecar learns the agent's name")

        state.updateSemanticAgent(surfaceID: surface, agentID: nil)
        #expect(!state.showsSemanticPromptBox(for: surface))
        #expect(state.isSemanticModeOn(for: surface), "quitting the agent hides the box but keeps the mode")

        #expect(VoiceSemanticAgentPresence.semanticAgentID(forDefinitionID: "claude") == "claude")
        #expect(VoiceSemanticAgentPresence.semanticAgentID(forDefinitionID: "codex") == "codex")
        #expect(VoiceSemanticAgentPresence.semanticAgentID(forDefinitionID: "opencode") == nil)
        #expect(VoiceSemanticAgentPresence.semanticAgentID(forDefinitionID: nil) == nil)
    }

    @Test func boxButtonsRouteThroughTheSidecar() {
        let controller = RecordingAudioController()
        let state = liveState(controller: controller)
        let surface = UUID()
        state.enableSemanticMode(surfaceID: surface)

        state.sendSemanticCommand(.send)
        state.sendSemanticCommand(.clear)

        #expect(controller.commands.map(\.command) == [.send, .clear])
        #expect(controller.commands.allSatisfy { $0.surfaceID == surface.uuidString })
    }

    @Test func endingTheSessionTurnsSemanticModeOff() {
        let controller = RecordingAudioController()
        let state = liveState(controller: controller)
        let surface = UUID()
        state.enableSemanticMode(surfaceID: surface)
        state.handleBridgeMessage(draftMessage(surface: surface, text: "half an idea", stage: "drafting"))

        state.handleBridgeMessage(["type": "status", "status": "disconnected"])

        #expect(state.semanticSurfaceID == nil)
        #expect(state.semanticDraft.text.isEmpty)
        #expect(!state.isLive)
    }

    @Test func staleSidecarBoxAfterLocalOffIsTurnedOff() {
        let controller = RecordingAudioController()
        let state = liveState(controller: controller)
        let surface = UUID()
        state.enableSemanticMode(surfaceID: surface)
        state.disableSemanticMode()
        controller.semanticModeCalls.removeAll()

        state.handleBridgeMessage(draftMessage(surface: surface, text: "late", stage: "drafting"))

        #expect(state.semanticSurfaceID == nil)
        #expect(controller.semanticModeCalls.count == 1)
        #expect(controller.semanticModeCalls.last?.surfaceID == nil)
    }

    @Test func pillMovesLeftOfTheBlueprintBubbleWhenThatBetaIsOn() {
        #expect(VoiceSemanticModeStyle.buttonTrailingInset(blueprintEnabled: false) == 8)
        #expect(VoiceSemanticModeStyle.buttonTrailingInset(blueprintEnabled: true) == 8 + 28 + 8)
    }

    @Test func promptBottomInsetClearsTheAgentStatusRow() {
        #expect(VoiceSemanticModeStyle.promptBottomInset(cellHeight: 18) == 42)
        #expect(VoiceSemanticModeStyle.promptBottomInset(cellHeight: 0) == 38, "falls back to a typical cell height before metrics arrive")
    }
}
