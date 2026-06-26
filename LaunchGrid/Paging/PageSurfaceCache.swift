import CoreGraphics
import Foundation

@MainActor
final class PageSurfaceCache {
    struct Signature: Equatable {
        let viewportSize: CGSize
        let layout: LaunchpadLayout
        let pageCount: Int
        let pageIDs: [[String]]
    }

    private var nextGenerationValue = 0

    func nextGeneration() -> Int {
        nextGenerationValue += 1
        return nextGenerationValue
    }

    func signature(
        viewportSize: CGSize,
        layout: LaunchpadLayout,
        pages: [[AppItem]]
    ) -> Signature {
        Signature(
            viewportSize: viewportSize,
            layout: layout,
            pageCount: pages.count,
            pageIDs: pages.map { page in
                page.map(\.id)
            }
        )
    }
}
