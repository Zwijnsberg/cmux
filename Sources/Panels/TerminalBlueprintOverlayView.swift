import AppKit
import SwiftUI
import WebKit

/// What the terminal host needs to show a pane's blueprint: the state, the
/// session that owns the canvas web view, colors, and the focus hand-off.
/// Built by `TerminalPanelView` and pushed through the portal reconciliation
/// snapshot, like the find bar's search state.
struct TerminalBlueprintOverlayBinding {
    let state: TerminalBlueprintState
    let session: TerminalBlueprintWebSession
    let isDark: Bool
    let backgroundColor: NSColor
    let foregroundColor: NSColor
    /// The canvas took pointer focus: release terminal focus and focus the pane.
    let onPointerDown: @MainActor () -> Void
}

/// The blueprint layer of one terminal pane, hosted inside the portal-owned
/// `GhosttySurfaceScrollView` (SwiftUI overlays can fall behind portal-hosted
/// terminals). It draws the bubble in the top-right corner and, while the
/// state is open, the resizable popup anchored under it. Everything outside
/// those two views passes pointer events through to the terminal.
@MainActor
final class TerminalBlueprintOverlayView: NSView {
    static let bubbleSize: CGFloat = 28
    static let bubbleInset: CGFloat = 8

    private(set) var binding: TerminalBlueprintOverlayBinding?
    private var bubble: NSHostingView<TerminalBlueprintBubbleView>?
    private var popup: TerminalBlueprintPopupView?
    private var observationArmed = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = []
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    var stateIdentifier: ObjectIdentifier? {
        binding.map { ObjectIdentifier($0.state) }
    }

    func apply(_ binding: TerminalBlueprintOverlayBinding) {
        let stateChanged = self.binding.map { $0.state !== binding.state } ?? true
        self.binding = binding
        if stateChanged {
            bubble?.removeFromSuperview()
            bubble = nil
            popup?.removeFromSuperview()
            popup = nil
            observationArmed = false
        }
        ensureBubble()
        popup?.apply(binding)
        layoutOverlay()
        armObservation()
    }

    func detach() {
        binding = nil
        bubble?.removeFromSuperview()
        bubble = nil
        popup?.removeFromSuperview()
        popup = nil
    }

    // MARK: - Layout

    /// Places the bubble and the popup for the current pane size and state.
    func layoutOverlay() {
        guard let binding else { return }
        let state = binding.state
        if let bubble {
            bubble.frame = CGRect(
                x: bounds.width - Self.bubbleInset - Self.bubbleSize,
                y: Self.bubbleInset,
                width: Self.bubbleSize,
                height: Self.bubbleSize
            )
        }
        if state.isOpen {
            let popup = ensurePopup(binding)
            let frame = state.layout.popupFrame(in: bounds.size)
            if popup.frame != frame {
                popup.frame = frame
            }
            popup.isHidden = frame.isEmpty
            popup.layoutContent()
        } else if let popup {
            popup.isHidden = true
        }
    }

    private func ensureBubble() {
        guard bubble == nil, let binding else { return }
        let view = NSHostingView(rootView: TerminalBlueprintBubbleView(state: binding.state))
        view.autoresizingMask = []
        addSubview(view)
        bubble = view
    }

    private func ensurePopup(_ binding: TerminalBlueprintOverlayBinding) -> TerminalBlueprintPopupView {
        if let popup {
            popup.apply(binding)
            return popup
        }
        let popup = TerminalBlueprintPopupView(frame: .zero)
        popup.onResize = { [weak self] size in
            guard let self, let binding = self.binding else { return }
            binding.state.setPopupSize(size, paneSize: self.bounds.size)
        }
        popup.apply(binding)
        // Below the bubble so the bubble stays clickable while the popup is open.
        if let bubble {
            addSubview(popup, positioned: .below, relativeTo: bubble)
        } else {
            addSubview(popup)
        }
        self.popup = popup
        return popup
    }

    /// Re-lays out whenever the observable state changes visibility, size,
    /// or badge, without a SwiftUI parent.
    private func armObservation() {
        guard !observationArmed, let state = binding?.state else { return }
        observationArmed = true
        withObservationTracking {
            _ = state.isOpen
            _ = state.layout
            _ = state.hasUnseenAgentUpdate
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observationArmed = false
                self.layoutOverlay()
                self.armObservation()
            }
        }
    }

    // MARK: - Hit testing

    /// Only the bubble and the popup take pointer events; the rest of the
    /// pane belongs to the terminal.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        if let bubble, !bubble.isHidden, bubble.frame.contains(local) {
            return bubble.hitTest(local) ?? bubble
        }
        if let popup, !popup.isHidden, popup.frame.contains(local) {
            return popup.hitTest(local) ?? popup
        }
        return nil
    }
}

/// The floating canvas: a header bar, the session-owned web view, and resize
/// handles on the left edge, bottom edge, and bottom-left corner (the popup
/// is anchored top-right).
@MainActor
final class TerminalBlueprintPopupView: NSView {
    static let cornerRadius: CGFloat = 10
    static let handleThickness: CGFloat = 7
    static let cornerHandleSize: CGFloat = 16

    var onResize: ((CGSize) -> Void)?

    private var binding: TerminalBlueprintOverlayBinding?
    private var header: NSHostingView<TerminalBlueprintPopupHeaderView>?
    private weak var webView: WKWebView?
    private let leftHandle = TerminalBlueprintResizeHandleView(axis: .horizontal)
    private let bottomHandle = TerminalBlueprintResizeHandleView(axis: .vertical)
    private let cornerHandle = TerminalBlueprintResizeHandleView(axis: .both)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        autoresizingMask = []
        setAccessibilityIdentifier("TerminalBlueprintPopup")
        for handle in [leftHandle, bottomHandle, cornerHandle] {
            handle.onDrag = { [weak self] delta in
                guard let self else { return }
                let start = handle.dragStartSize
                self.onResize?(CGSize(width: start.width - delta.x, height: start.height + delta.y))
            }
            handle.sizeProvider = { [weak self] in self?.bounds.size ?? .zero }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func apply(_ binding: TerminalBlueprintOverlayBinding) {
        self.binding = binding
        layer?.backgroundColor = binding.backgroundColor.cgColor
        layer?.borderColor = binding.foregroundColor.withAlphaComponent(0.18).cgColor
        if header == nil {
            let view = NSHostingView(rootView: TerminalBlueprintPopupHeaderView(
                state: binding.state,
                foreground: Color(nsColor: binding.foregroundColor)
            ))
            view.autoresizingMask = []
            addSubview(view)
            header = view
        } else {
            header?.rootView = TerminalBlueprintPopupHeaderView(
                state: binding.state,
                foreground: Color(nsColor: binding.foregroundColor)
            )
        }
        binding.session.ensureLoaded(state: binding.state, isDark: binding.isDark)
        binding.session.coordinator.applyTheme(isDark: binding.isDark)
        if let webView = binding.session.webView, webView !== self.webView {
            self.webView?.removeFromSuperview()
            webView.removeFromSuperview()
            webView.autoresizingMask = []
            addSubview(webView, positioned: .below, relativeTo: header)
            self.webView = webView
        }
        (webView as? TerminalBlueprintWebView)?.onPointerDown = { [weak self] in
            guard let self, let binding = self.binding else { return }
            binding.onPointerDown()
            if let webView = self.webView, webView.window?.firstResponder !== webView {
                webView.window?.makeFirstResponder(webView)
            }
        }
        for handle in [leftHandle, bottomHandle, cornerHandle] where handle.superview == nil {
            addSubview(handle, positioned: .above, relativeTo: nil)
        }
    }

    func layoutContent() {
        let headerHeight = TerminalBlueprintLayout.headerHeight
        header?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        webView?.frame = CGRect(
            x: 0,
            y: headerHeight,
            width: bounds.width,
            height: max(0, bounds.height - headerHeight)
        )
        let t = Self.handleThickness
        let c = Self.cornerHandleSize
        leftHandle.frame = CGRect(x: 0, y: 0, width: t, height: max(0, bounds.height - c))
        bottomHandle.frame = CGRect(x: c, y: bounds.height - t, width: max(0, bounds.width - c), height: t)
        cornerHandle.frame = CGRect(x: 0, y: bounds.height - c, width: c, height: c)
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    /// Clicks on the popup chrome never reach the terminal below.
    override func mouseDown(with event: NSEvent) {
        binding?.onPointerDown()
    }
}

/// A drag strip that reports the pointer delta since the drag began.
@MainActor
final class TerminalBlueprintResizeHandleView: NSView {
    enum Axis {
        case horizontal
        case vertical
        case both
    }

    let axis: Axis
    var onDrag: ((CGPoint) -> Void)?
    var sizeProvider: (() -> CGSize)?
    private(set) var dragStartSize: CGSize = .zero
    private var dragStartPoint: CGPoint = .zero

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        autoresizingMask = []
        setAccessibilityIdentifier("TerminalBlueprintResizeHandle")
        toolTip = String(localized: "blueprint.header.resize", defaultValue: "Drag to resize the blueprint")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch axis {
        case .horizontal: cursor = .resizeLeftRight
        case .vertical: cursor = .resizeUpDown
        case .both: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartSize = sizeProvider?() ?? .zero
        dragStartPoint = locationInWindow(event)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = locationInWindow(event)
        var delta = CGPoint(x: point.x - dragStartPoint.x, y: -(point.y - dragStartPoint.y))
        switch axis {
        case .horizontal: delta.y = 0
        case .vertical: delta.x = 0
        case .both: break
        }
        onDrag?(delta)
    }

    private func locationInWindow(_ event: NSEvent) -> CGPoint {
        event.locationInWindow
    }
}

// MARK: - SwiftUI chrome

/// The round button in the pane's corner. A dot marks an agent update the
/// user has not looked at.
struct TerminalBlueprintBubbleView: View {
    let state: TerminalBlueprintState

    var body: some View {
        Button {
            state.perform(.toggle)
        } label: {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(.regularMaterial)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                Image(systemName: state.isOpen ? "xmark" : "rectangle.and.pencil.and.ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if state.hasUnseenAgentUpdate, !state.isOpen {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                        .offset(x: 1, y: -1)
                }
            }
            .frame(width: TerminalBlueprintOverlayView.bubbleSize, height: TerminalBlueprintOverlayView.bubbleSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityIdentifier("TerminalBlueprintBubble")
    }

    private var helpText: String {
        if state.isOpen {
            return String(localized: "blueprint.bubble.helpClose", defaultValue: "Close Blueprint")
        }
        if state.hasUnseenAgentUpdate {
            return String(localized: "blueprint.bubble.helpUpdated", defaultValue: "Open Blueprint (updated by agent)")
        }
        return String(localized: "blueprint.bubble.help", defaultValue: "Open Blueprint")
    }
}

/// The popup's header bar: title, agent badge, and the actions.
struct TerminalBlueprintPopupHeaderView: View {
    let state: TerminalBlueprintState
    let foreground: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.and.pencil.and.ellipsis")
                .font(.system(size: 11, weight: .medium))
            Text(String(localized: "blueprint.header.title", defaultValue: "Blueprint"))
                .font(.system(size: 11, weight: .semibold))
            if state.updatedBy == .agent, state.revision > 0 {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                    Text(String(localized: "blueprint.header.updatedByAgent", defaultValue: "Updated by agent"))
                        .font(.system(size: 10))
                }
                .foregroundStyle(foreground.opacity(0.75))
            }
            if let errorMessage = state.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundStyle(Color.red)
                    .accessibilityIdentifier("TerminalBlueprintErrorBanner")
            }
            Spacer(minLength: 8)
            headerButton(
                systemName: "arrow.up.left.and.down.right.magnifyingglass",
                help: String(localized: "blueprint.menu.zoomToFit", defaultValue: "Zoom to Fit"),
                identifier: "TerminalBlueprintZoomButton"
            ) {
                state.perform(.zoomToFit)
            }
            headerButton(
                systemName: state.layout.isEnlarged
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                help: state.layout.isEnlarged
                    ? String(localized: "blueprint.header.restore", defaultValue: "Restore Size")
                    : String(localized: "blueprint.header.enlarge", defaultValue: "Fill Pane"),
                identifier: "TerminalBlueprintEnlargeButton"
            ) {
                state.perform(state.layout.isEnlarged ? .restore : .enlarge)
            }
            Menu {
                Button(String(localized: "blueprint.menu.sendToTerminal", defaultValue: "Send to Terminal")) {
                    state.perform(.sendToTerminal)
                }
                .disabled(state.revision == 0 && state.elementCount == 0)
                Button(String(localized: "blueprint.menu.clear", defaultValue: "Clear Canvas")) {
                    state.perform(.clear)
                }
                Divider()
                Button(String(localized: "blueprint.menu.resetSize", defaultValue: "Reset Size")) {
                    state.resetPopupSize()
                }
                Divider()
                Button(String(localized: "blueprint.menu.close", defaultValue: "Close Blueprint")) {
                    state.perform(.close)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "blueprint.header.more", defaultValue: "More Blueprint Actions"))
            .accessibilityIdentifier("TerminalBlueprintMoreMenu")
            headerButton(
                systemName: "xmark",
                help: String(localized: "blueprint.menu.close", defaultValue: "Close Blueprint"),
                identifier: "TerminalBlueprintCloseButton"
            ) {
                state.perform(.close)
            }
        }
        .foregroundStyle(foreground.opacity(0.85))
        .padding(.horizontal, 10)
        .frame(height: CGFloat(TerminalBlueprintLayout.headerHeight))
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("TerminalBlueprintHeader")
    }

    private func headerButton(
        systemName: String,
        help: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityIdentifier(identifier)
    }
}
