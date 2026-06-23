import AppKit
import SwiftUI

struct LauncherView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @StateObject private var pager = PagerViewModel()

    let iconCache: IconCache
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let layout = LaunchpadMetrics.layout(for: geometry.size)

            ZStack {
                BackgroundClickView(onClick: onDismiss)
                    .ignoresSafeArea()

                Rectangle()
                    .fill(.regularMaterial)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                Rectangle()
                    .fill(Color(red: 0.29, green: 0.28, blue: 0.27).opacity(0.64))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    SearchBarView(text: $viewModel.searchText)
                        .frame(width: layout.searchWidth, height: layout.searchHeight)
                        .padding(.top, layout.topPadding)

                    statusView
                        .frame(height: layout.statusHeight)
                        .padding(.top, 12)

                    ZStack {
                        Color.clear
                            .contentShape(Rectangle())

                        ForEach(pager.visiblePageIndexes, id: \.self) { pageIndex in
                            AppPageView(
                                apps: pager.pages[safe: pageIndex] ?? [],
                                layout: layout,
                                iconCache: iconCache,
                                canLaunchApps: !pager.isInteractionLocked,
                                onLaunch: { app in
                                    viewModel.launch(app, onSuccess: onDismiss)
                                }
                            )
                            .offset(x: CGFloat(pageIndex - pager.currentPage) * layout.pageWidth + pager.pageOffset)
                        }
                    }
                    .contentShape(Rectangle())
                    .simultaneousGesture(pageDragGesture(layout: layout))
                    .frame(width: layout.pageWidth, height: layout.gridHeight)
                    .clipped()
                    .padding(.top, layout.gridTopGap)

                    Spacer(minLength: 0)

                    PageIndicatorView(
                        pageCount: pager.pageCount,
                        currentPage: pager.currentPage,
                        layout: layout
                    )
                    .padding(.bottom, layout.bottomPadding)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                PagingEventView(
                    currentPage: pager.currentPage,
                    pageCount: pager.pageCount,
                    isTransitioning: pager.isPageTransitioning,
                    pageWidth: layout.pageWidth,
                    threshold: layout.scrollThreshold,
                    maxDragOffset: layout.maxDragOffset,
                    onDrag: { offset in
                        pager.setDragOffset(offset, limit: layout.maxDragOffset)
                    },
                    onCommit: { step in
                        pager.stepPage(step, animationDuration: layout.pageAnimationDuration)
                    },
                    onCancel: {
                        pager.cancelDrag(animationDuration: layout.pageAnimationDuration)
                    }
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            .onAppear {
                updatePager(layout: layout)
            }
            .onChange(of: viewModel.apps) { _, _ in
                updatePager(layout: layout)
            }
            .onChange(of: viewModel.searchText) { _, _ in
                updatePager(layout: layout)
            }
            .onChange(of: layout.pageCapacity) { _, _ in
                updatePager(layout: layout)
            }
        }
        .preferredColorScheme(.dark)
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

    private func pageDragGesture(layout: LaunchpadLayout) -> some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { value in
                guard !pager.isPageTransitioning else {
                    return
                }

                guard abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }

                pager.setDragOffset(
                    resistedPageOffset(value.translation.width),
                    limit: layout.maxDragOffset
                )
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    pager.cancelDrag(animationDuration: layout.pageAnimationDuration)
                    return
                }

                let projected = abs(value.predictedEndTranslation.width) > abs(value.translation.width)
                    ? value.predictedEndTranslation.width
                    : value.translation.width

                guard abs(projected) >= layout.scrollThreshold else {
                    pager.cancelDrag(animationDuration: layout.pageAnimationDuration)
                    return
                }

                pager.stepPage(
                    projected < 0 ? 1 : -1,
                    animationDuration: layout.pageAnimationDuration
                )
            }
    }

    private func resistedPageOffset(_ offset: CGFloat) -> CGFloat {
        if (pager.currentPage == 0 && offset > 0)
            || (pager.currentPage >= pager.pageCount - 1 && offset < 0) {
            return offset * 0.28
        }

        return offset
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct BackgroundClickView: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> ClickCatchingView {
        let view = ClickCatchingView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: ClickCatchingView, context: Context) {
        nsView.onClick = onClick
    }
}

private final class ClickCatchingView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

extension Notification.Name {
    static let launchGridFocusSearch = Notification.Name("LaunchGridFocusSearch")
}
