import AppKit
import CmuxCommandPalette

extension ContentView {
    static func commandPaletteBlueprintContributions() -> [CommandPaletteCommandContribution] {
        guard TerminalBlueprintFeature.isEnabled() else { return [] }
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }
        return [
            CommandPaletteCommandContribution(
                commandId: "palette.terminalToggleBlueprint",
                title: constant(String(localized: "command.toggleBlueprint.title", defaultValue: "Toggle Blueprint")),
                subtitle: constant(String(localized: "command.toggleBlueprint.subtitle", defaultValue: "Show or hide the diagram popup over the focused terminal")),
                keywords: ["blueprint", "canvas", "diagram", "sketch", "draw", "excalidraw", "whiteboard", "terminal"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSendBlueprint",
                title: constant(String(localized: "command.sendBlueprint.title", defaultValue: "Send Blueprint to Terminal")),
                subtitle: constant(String(localized: "command.sendBlueprint.subtitle", defaultValue: "Paste the canvas (PNG path and Mermaid) into the focused terminal's prompt")),
                keywords: ["blueprint", "canvas", "send", "prompt", "paste", "mermaid", "diagram", "agent"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.terminalEnlargeBlueprint",
                title: constant(String(localized: "command.enlargeBlueprint.title", defaultValue: "Enlarge or Restore Blueprint")),
                subtitle: constant(String(localized: "command.enlargeBlueprint.subtitle", defaultValue: "Fill the pane with the blueprint popup, or go back to its remembered size")),
                keywords: ["blueprint", "canvas", "enlarge", "maximize", "restore", "diagram"]
            ),
        ]
    }

    func registerBlueprintCommandPaletteHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.terminalToggleBlueprint") {
            if !tabManager.performBlueprintAction(.toggle) {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalSendBlueprint") {
            if !tabManager.performBlueprintAction(.sendToTerminal) {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalEnlargeBlueprint") {
            let isEnlarged = tabManager.selectedTerminalPanel?.blueprint.layout.isEnlarged ?? false
            if !tabManager.performBlueprintAction(isEnlarged ? .restore : .enlarge) {
                NSSound.beep()
            }
        }
    }
}
