import AppKit
import SwiftUI

/// Semantic mode: the "Semantic mode" pill hovering in the top-right of every
/// terminal, and the pink brainstorm box that hovers over Claude Code's or
/// Codex's input while the mode is on there.
///
/// Both are AppKit-hosted SwiftUI views mounted by `GhosttySurfaceScrollView`
/// (the same portal layer as the terminal find bar) so they stay above the
/// terminal through split and workspace churn. Each hosting view is sized to
/// its content, so clicks anywhere else still reach the terminal.
///
/// State lives in `VoiceAgentSessionState` (one source of truth for the
/// button, the palette command, and the sidecar); the sidecar owns the text.
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
    static let promptHorizontalInset: CGFloat = 14
    static let promptMaxWidth: CGFloat = 760
    /// The box sits above the agent's status line (Claude Code draws one row
    /// of hints under its input box) plus a little air.
    static func promptBottomInset(cellHeight: CGFloat) -> CGFloat {
        let rows = cellHeight > 0 ? cellHeight : 16
        return rows * 2 + 6
    }
}

/// Which coding agents open the hovering box. Other agents get the button
/// (the mode still shapes prompts) but no box, because their input rows
/// are not where this overlay expects them.
enum VoiceSemanticAgentPresence {
    static let semanticAgentIDs: Set<String> = ["claude", "codex"]

    /// `claude` / `codex` for a detected agent definition id, else nil.
    nonisolated static func semanticAgentID(forDefinitionID id: String?) -> String? {
        guard let id, semanticAgentIDs.contains(id) else { return nil }
        return id
    }

    /// Verifies the foreground process of a terminal off the main thread.
    nonisolated static func detect(foregroundPID: Int?) -> String? {
        guard let foregroundPID else { return nil }
        return semanticAgentID(forDefinitionID: CmuxTopProcessSnapshot.codingAgentDefinition(foregroundPID: foregroundPID)?.id)
    }
}

/// The pill in the terminal's top-right corner.
struct VoiceSemanticModeButton: View {
    let surfaceID: UUID
    /// The terminal's foreground process, polled while the mode is on here.
    let foregroundPID: @MainActor () -> Int?
    @AppStorage(VoiceAgentFeature.enabledKey) private var isVoiceEnabled = false
    @State private var isHovering = false

    private var state: VoiceAgentSessionState { VoiceAgentSessionState.shared }
    private var isOn: Bool { state.isSemanticModeOn(for: surfaceID) }

    var body: some View {
        if isVoiceEnabled {
            pill
                .task(id: isOn) {
                    guard isOn else { return }
                    await monitorAgent()
                }
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
            ? String(localized: "voiceSemantic.button.help.on", defaultValue: "Turn off semantic mode")
            : String(localized: "voiceSemantic.button.help.off", defaultValue: "Turn on semantic mode: think out loud and the voice agent shapes one prompt for Claude Code or Codex here"))
        .accessibilityLabel(String(localized: "voiceSemantic.button.title", defaultValue: "Semantic mode"))
        .accessibilityValue(isOn
            ? String(localized: "voiceSemantic.button.state.on", defaultValue: "On")
            : String(localized: "voiceSemantic.button.state.off", defaultValue: "Off"))
        .accessibilityIdentifier("VoiceSemanticModeButton")
    }

    /// Polls the terminal's foreground process while the mode is on here and
    /// reports whether Claude Code or Codex owns it. Cancelled by SwiftUI the
    /// moment the mode turns off or the view goes away.
    @MainActor
    private func monitorAgent() async {
        let state = self.state
        while !Task.isCancelled {
            let pid = foregroundPID()
            let agentID = await Task.detached(priority: .utility) {
                VoiceSemanticAgentPresence.detect(foregroundPID: pid)
            }.value
            if Task.isCancelled { break }
            state.updateSemanticAgent(surfaceID: surfaceID, agentID: agentID)
            try? await Task.sleep(for: .seconds(1))
        }
        state.updateSemanticAgent(surfaceID: surfaceID, agentID: nil)
    }
}

/// The pink box hovering over the agent's input while semantic mode is on
/// there and Claude Code or Codex is running.
struct VoiceSemanticPromptBox: View {
    let surfaceID: UUID
    /// Fixed by the hosting view so the text wraps to the terminal's width.
    var width: CGFloat

    private var state: VoiceAgentSessionState { VoiceAgentSessionState.shared }

    var body: some View {
        if state.showsSemanticPromptBox(for: surfaceID) {
            box
                .frame(width: max(width, 120))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var draft: VoiceSemanticDraft { state.semanticDraft }
    private var hasText: Bool { !draft.text.isEmpty }

    private var box: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: state.isLive ? "waveform" : "waveform.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VoiceSemanticModeStyle.gradient)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: state.isLive && draft.stage != .final)
                Text(stageLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VoiceSemanticModeStyle.pink)
                    .accessibilityIdentifier("VoiceSemanticStageLabel")
                Spacer(minLength: 8)
                if hasText {
                    boxButton(
                        String(localized: "voiceSemantic.action.clear", defaultValue: "Clear"),
                        systemImage: "xmark",
                        prominent: false
                    ) {
                        AppDelegate.shared?.performVoiceSemanticCommand(.clear)
                    }
                    .accessibilityIdentifier("VoiceSemanticClearButton")
                    boxButton(
                        String(localized: "voiceSemantic.action.send", defaultValue: "Send"),
                        systemImage: "arrow.up",
                        prominent: true
                    ) {
                        AppDelegate.shared?.performVoiceSemanticCommand(.send)
                    }
                    .accessibilityIdentifier("VoiceSemanticSendButton")
                }
            }
            Text(hasText ? draft.text : placeholder)
                .font(.system(size: 12.5))
                .foregroundStyle(hasText ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(14)
                .textSelection(.enabled)
                .accessibilityIdentifier("VoiceSemanticDraftText")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(
                LinearGradient(
                    colors: [VoiceSemanticModeStyle.pink.opacity(0.22), VoiceSemanticModeStyle.purple.opacity(0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(VoiceSemanticModeStyle.pink.opacity(draft.stage == .final ? 0.9 : 0.55), lineWidth: 1)
        }
        .shadow(color: VoiceSemanticModeStyle.pink.opacity(0.35), radius: 12, y: 2)
        .animation(.easeInOut(duration: 0.18), value: draft)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "voiceSemantic.accessibility.box", defaultValue: "Semantic mode draft"))
        .accessibilityIdentifier("VoiceSemanticPromptBox")
    }

    private var stageLabel: String {
        switch draft.stage {
        case .idle:
            return String(localized: "voiceSemantic.stage.idle", defaultValue: "Listening")
        case .drafting:
            return String(localized: "voiceSemantic.stage.drafting", defaultValue: "Drafting")
        case .final:
            return String(localized: "voiceSemantic.stage.final", defaultValue: "Ready to send?")
        }
    }

    private var placeholder: String {
        if !state.isLive {
            return String(localized: "voiceSemantic.placeholder.connecting", defaultValue: "Connecting the voice agent…")
        }
        return String(
            localized: "voiceSemantic.placeholder.idle",
            defaultValue: "Speak your idea. The box fills in as you talk and is rewritten when you change your mind."
        )
    }

    private func boxButton(_ title: String, systemImage: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.8))
                .padding(.vertical, 4)
                .padding(.horizontal, 9)
                .background {
                    if prominent {
                        Capsule().fill(VoiceSemanticModeStyle.gradient)
                    } else {
                        Capsule().fill(Color.primary.opacity(0.08))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .safeHelp(title)
    }
}

/// Owns the two hosting views for one terminal and keeps them positioned:
/// the pill at the top-right, the box across the bottom above the agent's
/// input rows. Created once per `GhosttySurfaceScrollView`.
@MainActor
final class VoiceSemanticOverlayController {
    private let buttonHost: NSHostingView<VoiceSemanticModeButton>
    private let promptHost: NSHostingView<VoiceSemanticPromptBox>
    private let promptBottomConstraint: NSLayoutConstraint
    private let buttonTrailingConstraint: NSLayoutConstraint
    private var installedSurfaceID: UUID?
    private var promptWidth: CGFloat = 0
    private let foregroundPID: @MainActor () -> Int?

    init(container: NSView, foregroundPID: @escaping @MainActor () -> Int?) {
        self.foregroundPID = foregroundPID
        let placeholder = UUID()
        buttonHost = NSHostingView(rootView: VoiceSemanticModeButton(surfaceID: placeholder, foregroundPID: foregroundPID))
        promptHost = NSHostingView(rootView: VoiceSemanticPromptBox(surfaceID: placeholder, width: 0))
        for host in [buttonHost, promptHost] as [NSView] {
            host.translatesAutoresizingMaskIntoConstraints = false
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.clear.cgColor
            host.setAccessibilityElement(false)
            container.addSubview(host)
        }
        promptBottomConstraint = promptHost.bottomAnchor.constraint(
            equalTo: container.bottomAnchor,
            constant: -VoiceSemanticModeStyle.promptBottomInset(cellHeight: 0)
        )
        buttonTrailingConstraint = buttonHost.trailingAnchor.constraint(
            equalTo: container.trailingAnchor,
            constant: -VoiceSemanticModeStyle.buttonTrailingInset(blueprintEnabled: TerminalBlueprintFeature.isEnabled())
        )
        NSLayoutConstraint.activate([
            buttonHost.topAnchor.constraint(equalTo: container.topAnchor, constant: VoiceSemanticModeStyle.buttonInset),
            buttonTrailingConstraint,
            promptHost.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            promptBottomConstraint,
        ])
        // Hidden until a surface is attached; an empty SwiftUI body has no
        // size, so the hosts never intercept terminal clicks while idle.
        buttonHost.isHidden = true
        promptHost.isHidden = true
    }

    var hostViews: [NSView] { [buttonHost, promptHost] }

    /// Point the overlays at the terminal currently shown in the container.
    func attach(surfaceID: UUID?) {
        guard installedSurfaceID != surfaceID else { return }
        installedSurfaceID = surfaceID
        guard let surfaceID else {
            buttonHost.isHidden = true
            promptHost.isHidden = true
            return
        }
        buttonHost.rootView = VoiceSemanticModeButton(surfaceID: surfaceID, foregroundPID: foregroundPID)
        promptHost.rootView = VoiceSemanticPromptBox(surfaceID: surfaceID, width: promptWidth)
        buttonHost.isHidden = false
        promptHost.isHidden = false
    }

    /// Called from the container's geometry pass: the box wraps to the
    /// terminal width and floats above the agent's input rows.
    func layout(containerBounds: CGRect, cellHeight: CGFloat) {
        let width = min(VoiceSemanticModeStyle.promptMaxWidth, max(0, containerBounds.width - 2 * VoiceSemanticModeStyle.promptHorizontalInset))
        if abs(width - promptWidth) > 0.5 {
            promptWidth = width
            if let installedSurfaceID {
                promptHost.rootView = VoiceSemanticPromptBox(surfaceID: installedSurfaceID, width: width)
            }
        }
        let inset = -VoiceSemanticModeStyle.promptBottomInset(cellHeight: cellHeight)
        if abs(promptBottomConstraint.constant - inset) > 0.5 {
            promptBottomConstraint.constant = inset
        }
        let trailing = -VoiceSemanticModeStyle.buttonTrailingInset(blueprintEnabled: TerminalBlueprintFeature.isEnabled())
        if abs(buttonTrailingConstraint.constant - trailing) > 0.5 {
            buttonTrailingConstraint.constant = trailing
        }
    }
}
