import SwiftUI

struct AppGridView: View {
    let apps: [AppItem]
    let iconCache: IconCache
    let onLaunch: (AppItem) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 112, maximum: 136), spacing: 26, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .center, spacing: 30) {
                ForEach(apps) { app in
                    AppIconView(
                        app: app,
                        image: iconCache.icon(for: app),
                        action: {
                            onLaunch(app)
                        }
                    )
                }
            }
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
    }
}
