import AppKit
import CmuxCommandPalette

extension ContentView {
    static func commandPaletteVoiceAgentContributions() -> [CommandPaletteCommandContribution] {
        guard VoiceAgentFeature.isEnabled() else { return [] }
        return [
            CommandPaletteCommandContribution(
                commandId: "palette.toggleVoiceAgent",
                title: { _ in String(localized: "command.toggleVoiceAgent.title", defaultValue: "Toggle Voice Agent") },
                subtitle: { _ in String(localized: "command.toggleVoiceAgent.subtitle", defaultValue: "Talk to cmux to control workspaces, panes, terminals, and the browser") },
                keywords: ["voice", "talk", "speak", "microphone", "mic", "agent", "ultravox", "pipecat"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.toggleVoiceSemanticMode",
                title: { _ in String(localized: "command.toggleVoiceSemanticMode.title", defaultValue: "Toggle Semantic Mode") },
                subtitle: { _ in String(localized: "command.toggleVoiceSemanticMode.subtitle", defaultValue: "Rewrite spoken prompts for Claude Code or Codex in the focused terminal into clean, structured prompts") },
                keywords: ["voice", "semantic", "rewrite", "prompt", "dictate", "claude", "codex", "agent"]
            ),
        ]
    }

    func registerVoiceAgentCommandPaletteHandler(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.toggleVoiceAgent") {
            guard let appDelegate = AppDelegate.shared,
                  appDelegate.performVoiceAgentToggle(preferredWindow: appDelegate.mainWindow(for: windowId)) else {
                NSSound.beep()
                return
            }
        }
        registry.register(commandId: "palette.toggleVoiceSemanticMode") {
            guard let appDelegate = AppDelegate.shared,
                  appDelegate.performVoiceSemanticModeToggleForFocusedTerminal(preferredWindow: appDelegate.mainWindow(for: windowId)) else {
                NSSound.beep()
                return
            }
        }
    }
}
