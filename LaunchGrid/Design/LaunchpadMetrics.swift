import CoreGraphics
import Foundation

struct LaunchpadLayout: Equatable {
    let columns: Int
    let rows: Int
    let pageCapacity: Int

    let iconSize: CGFloat
    let labelWidth: CGFloat
    let labelHeight: CGFloat
    let labelFontSize: CGFloat
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let columnSpacing: CGFloat
    let rowSpacing: CGFloat
    let gridWidth: CGFloat
    let gridHeight: CGFloat
    let pageWidth: CGFloat

    let searchWidth: CGFloat
    let searchHeight: CGFloat
    let topPadding: CGFloat
    let statusHeight: CGFloat
    let gridTopGap: CGFloat
    let bottomPadding: CGFloat
    let dotSize: CGFloat
    let dotSpacing: CGFloat

    let pageAnimationDuration: TimeInterval
    let scrollThreshold: CGFloat
    let maxDragOffset: CGFloat
    let clickCancelDistance: CGFloat
}

enum LaunchpadMetrics {
    static func layout(for size: CGSize) -> LaunchpadLayout {
        let iconSize = scaled(base: 92, compact: 82, size: size)
        let labelFontSize = scaled(base: 13.5, compact: 12.5, size: size)
        let cellWidth = scaled(base: 136, compact: 122, size: size)
        let cellHeight = scaled(base: 136, compact: 124, size: size)
        let columnSpacing = scaled(base: 39, compact: 28, size: size)
        let rowSpacing = scaled(base: 30, compact: 22, size: size)
        let topPadding = scaled(base: 31, compact: 24, size: size)
        let gridTopGap = scaled(base: 44, compact: 32, size: size)
        let bottomPadding = scaled(base: 46, compact: 34, size: size)
        let statusHeight: CGFloat = 24
        let searchHeight = scaled(base: 36, compact: 34, size: size)
        let gridMaxWidth = scaled(base: 1186, compact: 820, size: size)

        let horizontalInset = max(90, min(190, size.width * 0.11))
        let availableWidth = max(320, min(size.width - horizontalInset * 2, gridMaxWidth))
        let rawColumns = Int(floor((availableWidth + columnSpacing) / (cellWidth + columnSpacing)))
        let columns = min(7, max(3, rawColumns))

        let reservedHeight = topPadding + searchHeight + statusHeight + gridTopGap + bottomPadding + 22
        let availableGridHeight = max(cellHeight * 2, size.height - reservedHeight)
        let rawRows = Int(floor((availableGridHeight + rowSpacing) / (cellHeight + rowSpacing)))
        let preferredRows = size.height >= 620 ? 5 : rawRows
        let rows = min(5, max(2, preferredRows))

        let gridWidth = CGFloat(columns) * cellWidth + CGFloat(max(columns - 1, 0)) * columnSpacing
        let gridHeight = CGFloat(rows) * cellHeight + CGFloat(max(rows - 1, 0)) * rowSpacing
        let pageWidth = max(size.width, gridWidth)
        let pageCapacity = max(1, columns * rows)

        return LaunchpadLayout(
            columns: columns,
            rows: rows,
            pageCapacity: pageCapacity,
            iconSize: iconSize,
            labelWidth: cellWidth,
            labelHeight: 36,
            labelFontSize: labelFontSize,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            columnSpacing: columnSpacing,
            rowSpacing: rowSpacing,
            gridWidth: gridWidth,
            gridHeight: gridHeight,
            pageWidth: pageWidth,
            searchWidth: min(max(size.width * 0.18, 250), 280),
            searchHeight: searchHeight,
            topPadding: topPadding,
            statusHeight: statusHeight,
            gridTopGap: gridTopGap,
            bottomPadding: bottomPadding,
            dotSize: 8,
            dotSpacing: 8,
            pageAnimationDuration: 0.28,
            scrollThreshold: max(72, min(96, size.width * 0.055)),
            maxDragOffset: min(120, max(70, size.width * 0.09)),
            clickCancelDistance: 9
        )
    }

    private static func scaled(base: CGFloat, compact: CGFloat, size: CGSize) -> CGFloat {
        size.width < 1200 || size.height < 820 ? compact : base
    }
}
