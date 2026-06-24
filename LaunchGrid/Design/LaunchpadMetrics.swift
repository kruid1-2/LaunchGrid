import CoreGraphics
import Foundation

struct LaunchpadScreenInsets: Equatable {
    let top: CGFloat
    let left: CGFloat
    let bottom: CGFloat
    let right: CGFloat

    static let zero = LaunchpadScreenInsets(top: 0, left: 0, bottom: 0, right: 0)

    init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        self.top = max(0, top)
        self.left = max(0, left)
        self.bottom = max(0, bottom)
        self.right = max(0, right)
    }

    init(screenFrame: CGRect, visibleFrame: CGRect) {
        self.init(
            top: screenFrame.maxY - visibleFrame.maxY,
            left: visibleFrame.minX - screenFrame.minX,
            bottom: visibleFrame.minY - screenFrame.minY,
            right: screenFrame.maxX - visibleFrame.maxX
        )
    }

    func clamped(to size: CGSize) -> LaunchpadScreenInsets {
        LaunchpadScreenInsets(
            top: min(top, size.height * 0.18),
            left: min(left, size.width * 0.42),
            bottom: min(bottom, size.height * 0.32),
            right: min(right, size.width * 0.42)
        )
    }
}

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
    let contentFrame: CGRect
    let gridWidth: CGFloat
    let gridHeight: CGFloat
    let pageWidth: CGFloat

    let searchWidth: CGFloat
    let searchHeight: CGFloat
    let topPadding: CGFloat
    let statusHeight: CGFloat
    let gridTopGap: CGFloat
    let bottomPadding: CGFloat
    let gridTop: CGFloat
    let pageIndicatorCenterY: CGFloat
    let dotSize: CGFloat
    let dotSpacing: CGFloat

    let pageAnimationDuration: TimeInterval
    let scrollThreshold: CGFloat
    let clickCancelDistance: CGFloat
}

enum LaunchpadMetrics {
    static func layout(
        for size: CGSize,
        screenInsets rawScreenInsets: LaunchpadScreenInsets = .zero
    ) -> LaunchpadLayout {
        let screenInsets = rawScreenInsets.clamped(to: size)
        let isShortDisplay = size.height <= 1100
        let iconSize: CGFloat = scaled(base: 90, compact: 80, size: size, compactWhenShort: true)
        let labelFontSize: CGFloat = scaled(base: 13.5, compact: 12.5, size: size, compactWhenShort: true)
        let cellWidth: CGFloat = scaled(base: 136, compact: 124, size: size, compactWhenShort: false)
        let cellHeight: CGFloat = isShortDisplay ? 120 : 132
        let columnSpacing: CGFloat = scaled(base: 40, compact: 32, size: size, compactWhenShort: false)
        let topProtection = min(screenInsets.top, isShortDisplay ? 12 : 16)
        let contentFrame = CGRect(
            x: screenInsets.left,
            y: topProtection,
            width: max(320, size.width - screenInsets.left - screenInsets.right),
            height: max(320, size.height - topProtection - screenInsets.bottom)
        )
        let topPadding: CGFloat = isShortDisplay ? 24 : 30
        let gridTopGap: CGFloat = isShortDisplay ? 24 : 36
        let bottomPadding: CGFloat = isShortDisplay ? 18 : 22
        let statusHeight: CGFloat = 24
        let searchHeight: CGFloat = scaled(base: 36, compact: 34, size: size, compactWhenShort: true)
        let gridMaxWidth: CGFloat = scaled(base: 1500, compact: 1320, size: size, compactWhenShort: false)

        let horizontalInset = max(72, min(190, contentFrame.width * 0.11))
        let availableWidth = max(320, min(contentFrame.width - horizontalInset * 2, gridMaxWidth))
        let rawColumns = Int(floor((availableWidth + columnSpacing) / (cellWidth + columnSpacing)))
        let columns = min(7, max(3, rawColumns))

        let gridTop = contentFrame.minY + topPadding + searchHeight + gridTopGap
        let pageIndicatorBottomGap: CGFloat = screenInsets.bottom > 24 ? 24 : (isShortDisplay ? 56 : 66)
        let pageIndicatorCenterY = max(
            gridTop + cellHeight * 2,
            contentFrame.maxY - pageIndicatorBottomGap
        )
        let maxGridBottom = pageIndicatorCenterY - (isShortDisplay ? 54 : 62)
        let availableGridHeight = max(cellHeight * 2, maxGridBottom - gridTop)
        let minimumRowSpacing: CGFloat = isShortDisplay ? 20 : 26
        let rawRows = Int(floor((availableGridHeight + minimumRowSpacing) / (cellHeight + minimumRowSpacing)))
        let preferredRows = availableGridHeight >= cellHeight * 5 + minimumRowSpacing * 4 ? 5 : rawRows
        let rows = min(5, max(2, preferredRows))
        let rowSpacing: CGFloat
        if rows > 1 {
            let distributedSpacing = (availableGridHeight - CGFloat(rows) * cellHeight) / CGFloat(rows - 1)
            rowSpacing = min(isShortDisplay ? 46 : 58, max(minimumRowSpacing, distributedSpacing))
        } else {
            rowSpacing = 0
        }

        let gridWidth = CGFloat(columns) * cellWidth + CGFloat(max(columns - 1, 0)) * columnSpacing
        let gridHeight = CGFloat(rows) * cellHeight + CGFloat(max(rows - 1, 0)) * rowSpacing
        let pageWidth = max(contentFrame.width, gridWidth)
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
            contentFrame: contentFrame,
            gridWidth: gridWidth,
            gridHeight: gridHeight,
            pageWidth: pageWidth,
            searchWidth: min(max(contentFrame.width * 0.18, 250), 280),
            searchHeight: searchHeight,
            topPadding: topPadding,
            statusHeight: statusHeight,
            gridTopGap: gridTopGap,
            bottomPadding: bottomPadding,
            gridTop: gridTop,
            pageIndicatorCenterY: pageIndicatorCenterY,
            dotSize: 8,
            dotSpacing: 8,
            pageAnimationDuration: 0.20,
            scrollThreshold: max(64, min(108, contentFrame.width * 0.045)),
            clickCancelDistance: 10
        )
    }

    private static func scaled(
        base: CGFloat,
        compact: CGFloat,
        size: CGSize,
        compactWhenShort: Bool
    ) -> CGFloat {
        size.width < 1200 || (compactWhenShort && size.height <= 1100) ? compact : base
    }
}
