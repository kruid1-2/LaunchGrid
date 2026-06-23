import SwiftUI

struct AppPageView: View {
    let apps: [AppItem]
    let layout: LaunchpadLayout
    let iconCache: IconCache
    let canLaunchApps: Bool
    let onLaunch: (AppItem) -> Void

    var body: some View {
        ZStack {
            if apps.isEmpty {
                Text("No applications found")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.76))
                    .shadow(color: .black.opacity(0.65), radius: 2, x: 0, y: 1)
            } else {
                AppGridView(
                    apps: apps,
                    layout: layout,
                    iconCache: iconCache,
                    canLaunchApps: canLaunchApps,
                    onLaunch: onLaunch
                )
            }
        }
        .frame(width: layout.pageWidth, height: layout.gridHeight)
    }
}
