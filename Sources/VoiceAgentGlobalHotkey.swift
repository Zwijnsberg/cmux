import AppKit
import ApplicationServices
import CmuxSettingsUI
import Foundation

/// Recognizes a modifier-only chord (Command+Option by default) pressed and
/// released on its own: both modifiers go down, no other key or modifier
/// joins them, and they come back up. Pure state machine, no AppKit calls, so
/// it is unit-tested directly.
///
/// A chord in progress is cancelled by any key press (⌘⌥+Space is someone
/// else's shortcut, not ours) or by an extra modifier (⌘⌥⇧). A cancelled
/// chord only resets once every tracked modifier is up again.
struct ModifierChordDetector: Equatable {
    enum Event: Equatable {
        case flagsChanged(NSEvent.ModifierFlags)
        case keyDown
    }

    /// The modifiers the chord consists of.
    let chord: NSEvent.ModifierFlags

    /// The modifiers considered when deciding whether something *else* is held.
    static let trackedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    private(set) var pressed: NSEvent.ModifierFlags = []
    private(set) var armed = false
    private(set) var cancelled = false

    init(chord: NSEvent.ModifierFlags = [.command, .option]) {
        self.chord = chord.intersection(Self.trackedModifiers)
    }

    /// Feeds one event. Returns true when the chord completed and the action should fire.
    mutating func handle(_ event: Event) -> Bool {
        switch event {
        case .keyDown:
            if !pressed.isEmpty {
                cancelled = true
                armed = false
            }
            return false
        case .flagsChanged(let flags):
            pressed = flags.intersection(Self.trackedModifiers)
            if pressed.isEmpty {
                let fire = armed && !cancelled
                armed = false
                cancelled = false
                return fire
            }
            if cancelled {
                return false
            }
            if pressed == chord {
                armed = true
            } else if !pressed.isStrictSubset(of: chord) {
                // An extra modifier joined (or a different chord entirely).
                cancelled = true
                armed = false
            }
            // A strict subset is the chord being pressed or released one
            // modifier at a time; nothing to decide yet.
            return false
        }
    }
}

/// Watches for the voice chord from any app (global monitor) and inside cmux
/// (local monitor) and toggles the voice session, exactly like the sidebar
/// mic button. macOS delivers global key events only to apps trusted for
/// Accessibility; without that permission the chord works while cmux is
/// frontmost and the toggle in Settings asks for the permission.
final class VoiceAgentGlobalHotkeyController {
    static let shared = VoiceAgentGlobalHotkeyController()

    /// Two fires closer than this are one shaky tap.
    static let debounceInterval: TimeInterval = 0.5

    private var detector = ModifierChordDetector()
    private var globalMonitors: [Any] = []
    private var localMonitor: Any?
    private var defaultsObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var lastFire: Date = .distantPast
    private var promptedForAccessibility = false
    private var installed = false

    private init() {}

    func start() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        // Accessibility may be granted while cmux runs; re-arm on activation.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    static var isEnabled: Bool {
        VoiceAgentFeature.isEnabled() && VoiceAgentFeature.isGlobalHotkeyEnabled()
    }

    nonisolated static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt that offers to open Privacy & Security ›
    /// Accessibility. Called once per enable, never at launch.
    nonisolated static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func refresh() {
        guard Self.isEnabled else {
            uninstall()
            promptedForAccessibility = false
            return
        }
        if !Self.isAccessibilityTrusted(), !promptedForAccessibility, NSApp.isActive {
            promptedForAccessibility = true
            Self.requestAccessibility()
        }
        install()
    }

    private func install() {
        guard !installed else { return }
        installed = true
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
        }) {
            globalMonitors.append(monitor)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func uninstall() {
        for monitor in globalMonitors {
            NSEvent.removeMonitor(monitor)
        }
        globalMonitors.removeAll()
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
        installed = false
        detector = ModifierChordDetector()
    }

    private func handle(_ event: NSEvent) {
        let chordEvent: ModifierChordDetector.Event
        switch event.type {
        case .flagsChanged:
            chordEvent = .flagsChanged(event.modifierFlags)
        case .keyDown:
            chordEvent = .keyDown
        default:
            return
        }
        guard detector.handle(chordEvent) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.fire()
        }
    }

    @MainActor
    private func fire() {
        let now = Date()
        guard now.timeIntervalSince(lastFire) >= Self.debounceInterval else { return }
        lastFire = now
        // Stand down while a shortcut recorder is armed, exactly like the
        // system-wide hotkey: a chord being recorded must not toggle the mic.
        if KeyboardShortcutRecorderActivity.isAnyRecorderActive || RecorderHostButton.isActivelyRecording {
            return
        }
        // A short click so a background toggle is audible before the greeting
        // (or, when ending, at all).
        NSSound(named: NSSound.Name("Tink"))?.play()
        _ = AppDelegate.shared?.performVoiceAgentToggle(preferredWindow: nil)
    }
}
