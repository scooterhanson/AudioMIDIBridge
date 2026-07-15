import SwiftUI

/// Central font sizing for the whole app — every size here is +2pt over
/// SwiftUI's normal semantic default (e.g. .caption is ~10pt, so
/// AppFont.caption is 12pt). Use these instead of the bare `.caption` /
/// `.headline` / etc. styles so a "make everything 2pt bigger" request has
/// one place to live instead of scattered literal sizes.
enum AppFont {
    static let caption: Font = .system(size: 12)
    static let captionMonospaced: Font = .system(size: 12, design: .monospaced)
    static let subheadline: Font = .system(size: 13)
    static let body: Font = .system(size: 15)
    static let bodyMonospaced: Font = .system(size: 15, design: .monospaced)
    static let headline: Font = .system(size: 15, weight: .semibold)
    static let title3: Font = .system(size: 17)
    static let title2: Font = .system(size: 19)
}
