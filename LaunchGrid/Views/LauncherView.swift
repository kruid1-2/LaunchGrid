import AppKit
import SwiftUI

struct LauncherView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var pager: PagerViewModel

    let iconCache: IconCache
    let onDismiss: () -> Void
    let onPagerUpdated: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let layout = LaunchpadMetrics.layout(
                for: geometry.size,
                screenInsets: viewModel.screenInsets
            )
            let contentCenterX = layout.contentFrame.midX

            ZStack {
                Rectangle()
                    .fill(.regularMaterial)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                Rectangle()
                    .fill(Color(red: 0.29, green: 0.28, blue: 0.27).opacity(0.64))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                SearchBarView(text: $viewModel.searchText)
                    .frame(width: layout.searchWidth, height: layout.searchHeight)
                    .position(
                        x: contentCenterX,
                        y: layout.contentFrame.minY + layout.topPadding + layout.searchHeight / 2
                    )

                statusView
                    .frame(width: max(1, min(layout.contentFrame.width, 420)), height: layout.statusHeight)
                    .position(
                        x: contentCenterX,
                        y: layout.contentFrame.minY + layout.topPadding + layout.searchHeight + 17
                    )

                pageContainer(layout: layout)
                    .position(
                        x: contentCenterX,
                        y: layout.gridTop + layout.gridHeight / 2
                    )

                PageIndicatorView(
                    pageCount: pager.pageCount,
                    currentPage: pager.currentPage,
                    layout: layout
                )
                .allowsHitTesting(false)
                .position(
                    x: contentCenterX,
                    y: layout.pageIndicatorCenterY
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                refreshPager(layout: layout)
            }
            .onChange(of: viewModel.apps) { _ in
                refreshPager(layout: layout)
            }
            .onChange(of: viewModel.searchText) { _ in
                refreshPager(layout: layout)
            }
            .onChange(of: layout.pageCapacity) { _ in
                refreshPager(layout: layout)
            }
            .onChange(of: viewModel.screenInsets) { _ in
                refreshPager(layout: layout)
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func pageContainer(layout: LaunchpadLayout) -> some View {
        Color.clear
            .frame(width: layout.pageWidth, height: layout.gridHeight)
            .allowsHitTesting(false)
    }

    private func appsForPage(_ pageIndex: Int) -> [AppItem]? {
        guard pager.pages.indices.contains(pageIndex) else {
            return nil
        }

        return pager.pages[pageIndex]
    }

    @ViewBuilder
    private var statusView: some View {
        if viewModel.isScanning {
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.8))
                .frame(height: 20)
        } else if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .frame(height: 20)
        } else {
            Color.clear
                .frame(height: 20)
        }
    }

    private func updatePager(layout: LaunchpadLayout) {
        pager.update(
            apps: viewModel.apps,
            searchText: viewModel.searchText,
            pageCapacity: layout.pageCapacity
        )
    }

    private func refreshPager(layout: LaunchpadLayout) {
        updatePager(layout: layout)
        preloadIcons(layout: layout)
        onPagerUpdated()
    }

    private func preloadIcons(layout: LaunchpadLayout) {
        let pageApps = pager.preloadPageIndexes.flatMap { pageIndex in
            pager.pages[safe: pageIndex] ?? []
        }
        iconCache.preloadIcons(for: pageApps)
    }

}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Notification.Name {
    static let launchGridFocusSearch = Notification.Name("LaunchGridFocusSearch")
}
