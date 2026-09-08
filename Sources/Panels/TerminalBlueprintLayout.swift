import Foundation

/// How the blueprint popup sits over its terminal pane.
///
/// The popup is anchored to the pane's top-right corner, under the bubble
/// button. `fitted` is the default coverage: the pane minus a buffer on every
/// side so the terminal stays partly visible. Once the user drags a resize
/// handle the size is kept as fractions of the pane (`floating`), so a
/// narrower split keeps the same proportions. `enlarged` fills the pane.
enum TerminalBlueprintLayout: Equatable, Sendable {
    case fitted
    case floating(widthFraction: Double, heightFraction: Double)
    case enlarged

    /// Space left around the popup in the default (`fitted`) layout.
    static let sideInset = 24.0
    static let bottomInset = 24.0
    /// Room above the popup for the bubble row.
    static let topInset = 44.0
    /// The popup never shrinks below this size, whatever the fractions say.
    static let minimumPopupSize = CGSize(width: 240, height: 160)
    static let minimumFraction = 0.2
    static let maximumFraction = 1.0
    /// Height of the popup's header bar.
    static let headerHeight = 30.0

    static func clampedFraction(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return maximumFraction }
        return min(maximumFraction, max(minimumFraction, fraction))
    }

    var isEnlarged: Bool {
        if case .enlarged = self { return true }
        return false
    }

    /// The popup's frame inside a pane of `paneSize`, in the pane's
    /// coordinate space with the origin at the top-left (y grows downward).
    func popupFrame(in paneSize: CGSize) -> CGRect {
        guard paneSize.width.isFinite, paneSize.height.isFinite, paneSize.width > 0, paneSize.height > 0 else {
            return .zero
        }
        let available = CGSize(
            width: max(0, paneSize.width - Self.sideInset * 2),
            height: max(0, paneSize.height - Self.topInset - Self.bottomInset)
        )
        var size: CGSize
        switch self {
        case .fitted:
            size = available
        case .floating(let widthFraction, let heightFraction):
            size = CGSize(
                width: available.width * Self.clampedFraction(widthFraction),
                height: available.height * Self.clampedFraction(heightFraction)
            )
        case .enlarged:
            size = CGSize(width: paneSize.width, height: max(0, paneSize.height - Self.topInset))
        }
        size.width = min(max(size.width, min(Self.minimumPopupSize.width, available.width)), paneSize.width)
        size.height = min(max(size.height, min(Self.minimumPopupSize.height, available.height)), paneSize.height - Self.topInset)
        let inset = isEnlarged ? 0 : Self.sideInset
        return CGRect(
            x: paneSize.width - inset - size.width,
            y: Self.topInset,
            width: size.width,
            height: size.height
        )
    }

    /// The layout that gives a popup of `size` in a pane of `paneSize`,
    /// as fractions of the fitted area so it scales with the pane.
    static func floating(size: CGSize, in paneSize: CGSize) -> TerminalBlueprintLayout {
        let available = CGSize(
            width: max(1, paneSize.width - sideInset * 2),
            height: max(1, paneSize.height - topInset - bottomInset)
        )
        return .floating(
            widthFraction: clampedFraction(size.width / available.width),
            heightFraction: clampedFraction(size.height / available.height)
        )
    }
}

extension TerminalBlueprintLayout: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case widthFraction
        case heightFraction
    }

    private enum Kind: String, Codable {
        case fitted
        case floating
        case enlarged
        // Layouts of the former drawer design decode to the default coverage.
        case collapsed
        case split
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .fitted
        switch kind {
        case .fitted, .collapsed, .split:
            self = .fitted
        case .enlarged:
            self = .enlarged
        case .floating:
            let width = try container.decodeIfPresent(Double.self, forKey: .widthFraction) ?? Self.maximumFraction
            let height = try container.decodeIfPresent(Double.self, forKey: .heightFraction) ?? Self.maximumFraction
            self = .floating(widthFraction: Self.clampedFraction(width), heightFraction: Self.clampedFraction(height))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fitted:
            try container.encode(Kind.fitted, forKey: .kind)
        case .floating(let width, let height):
            try container.encode(Kind.floating, forKey: .kind)
            try container.encode(width, forKey: .widthFraction)
            try container.encode(height, forKey: .heightFraction)
        case .enlarged:
            try container.encode(Kind.enlarged, forKey: .kind)
        }
    }
}
