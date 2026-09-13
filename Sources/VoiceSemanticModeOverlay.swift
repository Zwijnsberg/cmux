import AppKit
import SwiftUI

/// Semantic mode: the "Semantic mode" pill hovering in the top-right of every
/// terminal. It is a per-terminal switch on how the voice agent turns
/// "tell Claude…" into a prompt: on, the agent rewrites the words into a
/// clean, well-structured prompt before sending; off, they go in verbatim.
///
/// The pill is an AppKit-hosted SwiftUI view mounted by
/// `GhosttySurfaceScrollView` (the same portal layer as the terminal find bar)
/// so it stays above the terminal through split and workspace churn. The
/// hosting view is sized to the pill, so clicks anywhere else still reach the
/// terminal. State lives in `VoiceAgentSessionState` (one source of truth for
/// the pill, the palette command, and the sidecar).
enum VoiceSemanticModeStyle {
    static let pink = Color(red: 0.94, green: 0.40, blue: 0.78)
    static let purple = Color(red: 0.62, green: 0.38, blue: 0.95)
    static let gradient = LinearGradient(colors: [pink, purple], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let buttonInset: CGFloat = 8
    /// The pill shares the corner with the Blueprint bubble (`TerminalBlueprintOverlayView`)
    /// when that beta is on; it moves left of the bubble instead of covering it.
    static func buttonTrailingInset(blueprintEnabled: Bool) -> CGFloat {
        guard blueprintEnabled else { return buttonInset }
        return buttonInset + TerminalBlueprintOverlayView.bubbleSize + TerminalBlueprintOverlayView.bubbleInset
    }
}

/// The pill in the terminal's top-right corner.
struct VoiceSemanticModeButton: View {
    let surfaceID: UUID
    @AppStorage(VoiceAgentFeature.enabledKey) private var isVoiceEnabled = false
    @State private var isHovering = false

    private var state: VoiceAgentSessionState { VoiceAgentSessionState.shared }
    private var isOn: Bool { state.isSemanticModeOn(for: surfaceID) }

    var body: some View {
        if isVoiceEnabled {
            pill
        }
    }

    private var pill: some View {
        Button {
            _ = AppDelegate.shared?.performVoiceSemanticModeToggle(surfaceID: surfaceID)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                Text(String(localized: "voiceSemantic.button.title", defaultValue: "Semantic mode"))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? Color.white : Color.primary.opacity(isHovering ? 0.75 : 0.45))
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background {
                if isOn {
                    Capsule().fill(VoiceSemanticModeStyle.gradient)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(Color.primary.opacity(isHovering ? 0.10 : 0.05))
                }
            }
            .overlay {
                Capsule().strokeBorder(
                    isOn ? Color.white.opacity(0.35) : Color.primary.opacity(0.10),
                    lineWidth: 1
                )
            }
            .shadow(color: isOn ? VoiceSemanticModeStyle.pink.opacity(0.55) : .clear, radius: 8)
            .opacity(isOn ? 1 : (isHovering ? 0.95 : 0.7))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.18), value: isOn)
        .safeHelp(isOn
            ? String(localized: "voiceSemantic.button.help.on", defaultValue: "Turn off semantic mode: prompts go to the agent as you said them")
            : String(localized: "voiceSemantic.button.help.off", defaultValue: "Turn on semantic mode: the voice agent rewrites what you say into a clean prompt for Claude Code or Codex before sending it"))
        .accessibilityLabel(String(localized: "voiceSemantic.button.title", defaultValue: "Semantic mode"))
        .accessibilityValue(isOn
            ? String(localized: "voiceSemantic.button.state.on", defaultValue: "On")
            : String(localized: "voiceSemantic.button.state.off", defaultValue: "Off"))
        .accessibilityIdentifier("VoiceSemanticModeButton")
    }
}

/// Owns the pill's hosting view for one terminal and keeps it in the
/// top-right corner. Created once per `GhosttySurfaceScrollView`.
@MainActor
final class VoiceSemanticOverlayController {
    private let buttonHost: NSHostingView<VoiceSemanticModeButton>
    private let buttonTrailingConstraint: NSLayoutConstraint
    private var installedSurfaceID: UUID?

    init(container: NSView) {
        buttonHost = NSHostingView(rootView: VoiceSemanticModeButton(surfaceID: UUID()))
        buttonHost.translatesAutoresizingMaskIntoConstraints = false
        buttonHost.wantsLayer = true
        buttonHost.layer?.backgroundColor = NSColor.clear.cgColor
        buttonHost.setAccessibilityElement(false)
        container.addSubview(buttonHost)
        buttonTrailingConstraint = buttonHost.trailingAnchor.constraint(
            equalTo: container.trailingAnchor,
            constant: -VoiceSemanticModeStyle.buttonTrailingInset(blueprintEnabled: TerminalBlueprintFeature.isEnabled())
        )
        NSLayoutConstraint.activate([
            buttonHost.topAnchor.constraint(equalTo: container.topAnchor, constant: VoiceSemanticModeStyle.buttonInset),
            buttonTrailingConstraint,
        ])
        // Hidden until a surface is attached; an empty SwiftUI body has no
        // size, so the host never intercepts terminal clicks while idle.
        buttonHost.isHidden = true
    }

    var hostViews: [NSView] { [buttonHost] }

    /// Point the pill at the terminal currently shown in the container.
    func attach(surfaceID: UUID?) {
        guard installedSurfaceID != surfaceID else { return }
        installedSurfaceID = surfaceID
        guard let surfaceID else {
            buttonHost.isHidden = true
            return
        }
        buttonHost.rootView = VoiceSemanticModeButton(surfaceID: surfaceID)
        buttonHost.isHidden = false
    }

    /// Called from the container's geometry pass: keeps the pill clear of the
    /// Blueprint bubble when that beta is toggled at runtime.
    func layout() {
        let trailing = -VoiceSemanticModeStyle.buttonTrailingInset(blueprintEnabled: TerminalBlueprintFeature.isEnabled())
        if abs(buttonTrailingConstraint.constant - trailing) > 0.5 {
            buttonTrailingConstraint.constant = trailing
        }
    }
}
