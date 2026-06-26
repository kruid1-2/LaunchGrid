// LEGACY RUNTIME NOTE: This SwiftUI page type is not used by the visible launcher
// paging surface. The active renderer is PagingSurfaceController + PageSurfaceView.
import SwiftUI

struct AppGridView: View {
    let apps: [AppItem]
    let layout: LaunchpadLayout
    let iconCache: IconCache
    let canLaunchApps: Bool
    let onLaunch: (AppItem) -> Void

    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: layout.rowSpacing) {
            ForEach(apps) { app in
                AppIconView(
                    app: app,
                    layout: layout,
                    iconCache: iconCache,
                    canLaunch: canLaunchApps,
                    action: {
                        onLaunch(app)
                    }
                )
                .equatable()
            }
        }
        .frame(width: layout.gridWidth, height: layout.gridHeight, alignment: .topLeading)
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(layout.cellWidth), spacing: layout.columnSpacing, alignment: .top),
            count: layout.columns
        )
    }
}
