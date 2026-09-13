import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Semantic mode: the per-terminal "Semantic mode" pill that switches the
/// voice agent between verbatim and rewritten prompts. These cover the
/// app-side state in `VoiceAgentSessionState`: when the sidecar is told about
/// the mode and what turns it off.
@MainActor
struct VoiceSemanticModeTests {
    @MainActor
    final class RecordingAudioController: VoiceAgentAudioControlling {
        var semanticModeCalls: [String?] = []
        var recaps: [String?] = []
        var stops = 0

        func setMuted(_ muted: Bool) {}
        func stop() { stops += 1 }
        func requestRecap(surfaceID: String?) { recaps.append(surfaceID) }
        func setSemanticMode(surfaceID: String?) { semanticModeCalls.append(surfaceID) }
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

    @Test func enablingWhileLiveTellsTheSidecarAtOnce() {
        let controller = RecordingAudioController()
        let state = liveState(controller: controller)
        let surface = UUID()

        let needsSession = state.enableSemanticMode(surfaceID: surface)

        #expect(!needsSession)
        #expect(state.isSemanticModeOn(for: surface))
        #expect(controller.semanticModeCalls == [surface.uuidString])
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
        #expect(controller.semanticModeCalls == [surface.uuidString])
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
        #expect(controller.semanticModeCalls == [first.uuidString, second.uuidString])
    }

    @Test func disablingTellsTheSidecar() {
        let controller = RecordingAudioController()
        let state = liveState(controller: controller)
        let surface = UUID()
        state.enableSemanticMode(surfaceID: surface)

        state.disableSemanticMode()

        #expect(state.semanticSurfaceID == nil)
        #expect(controller.semanticModeCalls == [surface.uuidString, nil])
    }

    @Test func endingTheSessionTurnsSemanticModeOff() {
        let controller = RecordingAudioController()
        let state = liveState(controller: controller)
        let surface = UUID()
        state.enableSemanticMode(surfaceID: surface)

        state.handleBridgeMessage(["type": "status", "status": "disconnected"])

        #expect(state.semanticSurfaceID == nil)
        #expect(!state.isLive)
    }

    @Test func staleSidecarModeAfterLocalOffIsTurnedOff() {
        let controller = RecordingAudioController()
        let state = liveState(controller: controller)
        let surface = UUID()
        state.enableSemanticMode(surfaceID: surface)
        state.disableSemanticMode()
        controller.semanticModeCalls.removeAll()

        state.handleBridgeMessage(["type": "server", "data": ["type": "semantic_mode", "surface_id": surface.uuidString, "enabled": true]])

        #expect(state.semanticSurfaceID == nil)
        #expect(controller.semanticModeCalls == [nil])
    }

    @Test func pillMovesLeftOfTheBlueprintBubbleWhenThatBetaIsOn() {
        #expect(VoiceSemanticModeStyle.buttonTrailingInset(blueprintEnabled: false) == 8)
        // 8pt inset + 28pt bubble + 8pt gap; a literal because `#expect` infers mixed arithmetic as Int.
        #expect(VoiceSemanticModeStyle.buttonTrailingInset(blueprintEnabled: true) == 44)
    }
}
