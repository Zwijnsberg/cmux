import Foundation
@testable import CmuxControlSocket

// Benign defaults for the surface seams added with the voice agent
// (`surface.rename`, `surface.focus_input`, `surface.scroll`), so test fakes
// that conform to the full `ControlCommandContext` umbrella only implement the
// domains they exercise (same pattern as the other ControlCommandContextTestStubs files).

extension ControlSurfaceContext {
    func controlSurfaceRename(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        title: String
    ) -> ControlSurfaceFocusResolution { .tabManagerUnavailable }

    func controlSurfaceFocusInput(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> (resolution: ControlSurfaceFocusResolution, inputFocused: Bool) { (.tabManagerUnavailable, false) }

    func controlSurfaceScroll(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        direction: ControlSurfaceScrollDirection,
        pages: Int
    ) -> ControlSurfaceSendResolution { .tabManagerUnavailable }
}
