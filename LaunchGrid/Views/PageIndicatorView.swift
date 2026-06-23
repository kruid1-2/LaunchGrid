import SwiftUI

struct PageIndicatorView: View {
    let pageCount: Int
    let currentPage: Int
    let layout: LaunchpadLayout

    var body: some View {
        HStack(spacing: layout.dotSpacing) {
            ForEach(0..<pageCount, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(index == currentPage ? 0.92 : 0.32))
                    .frame(width: layout.dotSize, height: layout.dotSize)
                    .shadow(color: .black.opacity(index == currentPage ? 0.28 : 0), radius: 1, x: 0, y: 1)
            }
        }
        .frame(height: 18)
        .opacity(pageCount > 1 ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: pageCount)
        .animation(.easeOut(duration: 0.18), value: currentPage)
        .accessibilityHidden(pageCount <= 1)
    }
}
