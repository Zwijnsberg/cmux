import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Command+Option chord that starts or ends the voice session. It must
/// fire only for a clean tap of exactly those two modifiers, however they are
/// pressed and released, and never when they were part of another shortcut.
struct VoiceAgentGlobalHotkeyTests {
    private typealias Event = ModifierChordDetector.Event

    private func run(_ events: [Event], chord: NSEvent.ModifierFlags = [.command, .option]) -> [Bool] {
        var detector = ModifierChordDetector(chord: chord)
        return events.map { detector.handle($0) }
    }

    @Test func firesOnceWhenBothModifiersAreTappedAndReleased() {
        let fired = run([
            .flagsChanged([.command]),
            .flagsChanged([.command, .option]),
            .flagsChanged([.option]),
            .flagsChanged([]),
        ])
        #expect(fired == [false, false, false, true])
    }

    @Test func orderOfPressAndReleaseDoesNotMatter() {
        #expect(run([.flagsChanged([.option]), .flagsChanged([.command, .option]), .flagsChanged([.command]), .flagsChanged([])]).last == true)
        #expect(run([.flagsChanged([.command, .option]), .flagsChanged([])]).last == true)
    }

    @Test func aKeyPressDuringTheChordCancelsIt() {
        // ⌘⌥+Space belongs to another shortcut; releasing the modifiers afterwards must not toggle the mic.
        let fired = run([
            .flagsChanged([.command, .option]),
            .keyDown,
            .flagsChanged([.command]),
            .flagsChanged([]),
        ])
        #expect(fired.allSatisfy { !$0 })
    }

    @Test func anExtraModifierCancelsUntilEverythingIsReleased() {
        let fired = run([
            .flagsChanged([.command, .option]),
            .flagsChanged([.command, .option, .shift]),
            .flagsChanged([.command, .option]),  // back to the chord, but the tap is spoiled
            .flagsChanged([]),
        ])
        #expect(fired.allSatisfy { !$0 })
    }

    @Test func aSingleModifierOrAnotherPairNeverFires() {
        #expect(run([.flagsChanged([.command]), .flagsChanged([])]).allSatisfy { !$0 })
        #expect(run([.flagsChanged([.command, .shift]), .flagsChanged([])]).allSatisfy { !$0 })
        #expect(run([.flagsChanged([.control, .option]), .flagsChanged([])]).allSatisfy { !$0 })
    }

    @Test func keyPressesWithoutModifiersAreIgnored() {
        var detector = ModifierChordDetector()
        #expect(detector.handle(.keyDown) == false)
        #expect(detector.handle(.flagsChanged([.command, .option])) == false)
        #expect(detector.handle(.flagsChanged([])) == true, "typing earlier does not spoil a later tap")
    }

    @Test func detectorResetsAfterFiringSoTheNextTapWorks() {
        var detector = ModifierChordDetector()
        _ = detector.handle(.flagsChanged([.command, .option]))
        #expect(detector.handle(.flagsChanged([])) == true)
        _ = detector.handle(.flagsChanged([.command, .option]))
        #expect(detector.handle(.flagsChanged([])) == true)
    }

    @Test func untrackedFlagsSuchAsCapsLockDoNotCount() {
        let fired = run([
            .flagsChanged([.command, .option, .capsLock, .numericPad]),
            .flagsChanged([.capsLock]),
        ])
        #expect(fired == [false, true])
    }

    @Test func hotkeySettingDefaultsOnUnderTheVoiceBeta() {
        let suite = "cmux-voice-hotkey-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(VoiceAgentFeature.isGlobalHotkeyEnabled(defaults: defaults) == true)
        defaults.set(false, forKey: VoiceAgentFeature.globalHotkeyKey)
        #expect(VoiceAgentFeature.isGlobalHotkeyEnabled(defaults: defaults) == false)
    }
}
