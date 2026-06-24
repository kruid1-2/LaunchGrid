import SwiftUI

struct LauncherView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var pager: PagerViewModel

    let iconCache: IconCache
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let layout = LaunchpadMetrics.layout(
                for: geometry.size,
                screenInsets: viewModel.screenInsets
            )
            let contentCenterX = layout.contentFrame.midX
            let debugWidth = min(max(1, layout.contentFrame.width - 32), 430)

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
                .position(
                    x: contentCenterX,
                    y: layout.pageIndicatorCenterY
                )

                pagingDebugOverlay(layout: layout)
                    .frame(width: debugWidth, alignment: .leading)
                    .position(
                        x: layout.contentFrame.minX + 16 + debugWidth / 2,
                        y: layout.contentFrame.minY + 72
                    )

            }
            .onAppear {
                updatePager(layout: layout)
                preloadIcons(layout: layout)
            }
            .onChange(of: viewModel.apps) { _ in
                updatePager(layout: layout)
                preloadIcons(layout: layout)
            }
            .onChange(of: viewModel.searchText) { _ in
                updatePager(layout: layout)
                preloadIcons(layout: layout)
            }
            .onChange(of: layout.pageCapacity) { _ in
                updatePager(layout: layout)
                preloadIcons(layout: layout)
            }
            .onChange(of: viewModel.screenInsets) { _ in
                updatePager(layout: layout)
                preloadIcons(layout: layout)
            }
            .onChange(of: pager.currentPage) { _ in
                preloadIcons(layout: layout)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func pageContainer(layout: LaunchpadLayout) -> some View {
        HStack(spacing: 0) {
            ForEach([pager.currentPage - 1, pager.currentPage, pager.currentPage + 1], id: \.self) { pageIndex in
                if let apps = appsForPage(pageIndex) {
                    AppPageView(
                        apps: apps,
                        layout: layout,
                        iconCache: iconCache,
                        canLaunchApps: !pager.isInteractionLocked,
                        onLaunch: { app in
                            guard !pager.isInteractionLocked else {
                                return
                            }

                            viewModel.launch(app, onSuccess: onDismiss)
                        }
                    )
                } else {
                    Color.clear
                        .frame(width: layout.pageWidth, height: layout.gridHeight)
                }
            }
        }
        .frame(width: layout.pageWidth * 3, height: layout.gridHeight, alignment: .leading)
        .offset(x: -layout.pageWidth + pager.pageOffset)
        .frame(width: layout.pageWidth, height: layout.gridHeight)
        .clipped()
    }

    private func appsForPage(_ pageIndex: Int) -> [AppItem]? {
        guard pager.pages.indices.contains(pageIndex) else {
            return nil
        }

        return pager.pages[pageIndex]
    }

    private func pagingDebugOverlay(layout: LaunchpadLayout) -> some View {
        let currentPageItems = pager.pages[safe: pager.currentPage]?.count ?? 0
        let text = "page \(pager.currentPage + 1)/\(pager.pageCount)  offset \(Int(pager.pageOffset))  apps \(currentPageItems)/\(pager.filteredCount)  cap \(layout.pageCapacity)"

        return Text(text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.48), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(.white.opacity(0.24), lineWidth: 1)
            )
            .allowsHitTesting(false)
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
