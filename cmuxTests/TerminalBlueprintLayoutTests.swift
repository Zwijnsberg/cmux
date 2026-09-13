import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("TerminalBlueprintLayout")
struct TerminalBlueprintLayoutTests {
    private let pane = CGSize(width: 1000, height: 800)

    @Test("fractions clamp into the allowed range")
    func clampsFractions() {
        #expect(TerminalBlueprintLayout.clampedFraction(0.02) == TerminalBlueprintLayout.minimumFraction)
        #expect(TerminalBlueprintLayout.clampedFraction(1.5) == TerminalBlueprintLayout.maximumFraction)
        #expect(TerminalBlueprintLayout.clampedFraction(0.5) == 0.5)
        #expect(TerminalBlueprintLayout.clampedFraction(.nan) == TerminalBlueprintLayout.maximumFraction)
    }

    @Test("the fitted popup covers the pane minus the buffers, anchored top-right")
    func fittedFrame() {
        let frame = TerminalBlueprintLayout.fitted.popupFrame(in: pane)
        #expect(frame == CGRect(x: 24, y: 44, width: 952, height: 732))
        #expect(frame.maxX == pane.width - TerminalBlueprintLayout.sideInset)
    }

    @Test("a narrower pane gives a narrower popup with the same fractions")
    func floatingScalesWithPane() {
        let layout = TerminalBlueprintLayout.floating(widthFraction: 0.5, heightFraction: 0.5)
        let wide = layout.popupFrame(in: pane)
        let narrow = layout.popupFrame(in: CGSize(width: 600, height: 800))
        #expect(wide.width == 476)
        #expect(narrow.width == 276)
        #expect(wide.height == narrow.height)
        // Still anchored to the right buffer.
        #expect(narrow.maxX == 600 - TerminalBlueprintLayout.sideInset)
    }

    @Test("enlarged fills the pane below the bubble row")
    func enlargedFrame() {
        let frame = TerminalBlueprintLayout.enlarged.popupFrame(in: pane)
        #expect(frame == CGRect(x: 0, y: 44, width: 1000, height: 756))
        #expect(TerminalBlueprintLayout.enlarged.isEnlarged)
        #expect(!TerminalBlueprintLayout.fitted.isEnlarged)
    }

    @Test("tiny fractions keep the minimum popup size when the pane allows it")
    func minimumSize() {
        let frame = TerminalBlueprintLayout.floating(widthFraction: 0.2, heightFraction: 0.2).popupFrame(in: pane)
        #expect(frame.width == TerminalBlueprintLayout.minimumPopupSize.width)
        #expect(frame.height == TerminalBlueprintLayout.minimumPopupSize.height)
        let cramped = TerminalBlueprintLayout.fitted.popupFrame(in: CGSize(width: 200, height: 150))
        #expect(cramped.width <= 200)
        #expect(cramped.height <= 150 - TerminalBlueprintLayout.topInset)
    }

    @Test("degenerate pane sizes give an empty frame")
    func degenerateContainer() {
        #expect(TerminalBlueprintLayout.fitted.popupFrame(in: .zero) == .zero)
        #expect(TerminalBlueprintLayout.enlarged.popupFrame(in: CGSize(width: CGFloat.nan, height: 10)) == .zero)
    }

    @Test("a dragged size round-trips through fractions of the same pane")
    func floatingFromSize() {
        let layout = TerminalBlueprintLayout.floating(size: CGSize(width: 476, height: 366), in: pane)
        #expect(layout == .floating(widthFraction: 0.5, heightFraction: 0.5))
        #expect(layout.popupFrame(in: pane).size == CGSize(width: 476, height: 366))
    }

    @Test("layouts round-trip through JSON", arguments: [
        TerminalBlueprintLayout.fitted,
        .floating(widthFraction: 0.33, heightFraction: 0.8),
        .enlarged,
    ])
    func codableRoundTrip(layout: TerminalBlueprintLayout) throws {
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(TerminalBlueprintLayout.self, from: data)
        #expect(decoded == layout)
    }

    @Test("drawer-era layouts decode to the default coverage and fractions clamp")
    func lenientDecoding() throws {
        for legacy in [#"{"kind":"split","fraction":0.4}"#, #"{"kind":"collapsed"}"#, #"{}"#] {
            let decoded = try JSONDecoder().decode(TerminalBlueprintLayout.self, from: Data(legacy.utf8))
            #expect(decoded == .fitted, "\(legacy)")
        }
        let huge = try JSONDecoder().decode(
            TerminalBlueprintLayout.self,
            from: Data(#"{"kind":"floating","widthFraction":4,"heightFraction":0.01}"#.utf8)
        )
        #expect(huge == .floating(widthFraction: TerminalBlueprintLayout.maximumFraction, heightFraction: TerminalBlueprintLayout.minimumFraction))
    }
}
