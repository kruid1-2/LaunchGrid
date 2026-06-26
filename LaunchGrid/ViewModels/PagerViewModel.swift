import Foundation
import SwiftUI

@MainActor
final class PagerViewModel: ObservableObject {
    @Published private(set) var pages: [[AppItem]] = [[]]
    @Published private(set) var pageCount = 1
    @Published private(set) var filteredCount = 0
    @Published private(set) var rebuildCount = 0
    @Published var currentPage = 0
    @Published var pageOffset: CGFloat = 0
    @Published var isPageTransitioning = false

    private var lastApps: [AppItem] = []
    private var lastQuery = ""
    private var lastPageCapacity = 0
    private var rememberedUnfilteredPage = 0

    var preloadPageIndexes: [Int] {
        guard pageCount > 0 else {
            return []
        }

        return compactPageIndexes([currentPage - 1, currentPage, currentPage + 1])
    }

    var visiblePageIndexes: [Int] {
        compactPageIndexes([currentPage - 1, currentPage, currentPage + 1])
    }

    var isInteractionLocked: Bool {
        isPageTransitioning
    }

    func update(apps: [AppItem], searchText: String, pageCapacity: Int) {
        let capacity = max(1, pageCapacity)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard apps != lastApps || query != lastQuery || capacity != lastPageCapacity else {
            return
        }

        let wasSearching = !lastQuery.isEmpty
        let isSearching = !query.isEmpty

        if !wasSearching && isSearching {
            rememberedUnfilteredPage = currentPage
            currentPage = 0
        } else if wasSearching && !isSearching {
            currentPage = rememberedUnfilteredPage
        } else if wasSearching && isSearching && query != lastQuery {
            currentPage = 0
        }

        lastApps = apps
        lastQuery = query
        lastPageCapacity = capacity

        let filteredApps: [AppItem]
        if query.isEmpty {
            filteredApps = apps
        } else {
            filteredApps = apps.filter { app in
                app.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || app.bundleIdentifier?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }

        filteredCount = filteredApps.count
        let nextPages = Self.chunk(filteredApps, capacity: capacity)
        pages = nextPages.isEmpty ? [[]] : nextPages
        pageCount = pages.count
        clampCurrentPage()
        pageOffset = 0
        rebuildCount += 1
    }

    func setInteractiveOffset(_ offset: CGFloat) {
        guard !isPageTransitioning else {
            return
        }

        pageOffset = offset
    }

    func cancelDrag(animationDuration: TimeInterval) {
        withAnimation(.timingCurve(0.22, 0.72, 0.0, 1.0, duration: animationDuration)) {
            pageOffset = 0
        }
    }

    func stepPage(_ direction: PagingDirection, pageWidth: CGFloat, animationDuration: TimeInterval) {
        guard !isPageTransitioning, pageCount > 1 else {
            return
        }

        let step = direction.step
        let targetPage = min(max(currentPage + step, 0), pageCount - 1)
        guard targetPage != currentPage else {
            cancelDrag(animationDuration: animationDuration)
            return
        }

        isPageTransitioning = true
        let targetOffset: CGFloat = direction == .next ? -pageWidth : pageWidth

        withAnimation(.timingCurve(0.22, 0.72, 0.0, 1.0, duration: animationDuration)) {
            pageOffset = targetOffset
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) { [weak self] in
            Task { @MainActor in
                guard let self else {
                    return
                }

                self.currentPage = targetPage
                self.pageOffset = 0
                self.isPageTransitioning = false
            }
        }
    }

    func beginSnapshotPageTransition() {
        isPageTransitioning = true
        pageOffset = 0
    }

    func completeSnapshotPageTransition(_ direction: PagingDirection) {
        let targetPage = min(max(currentPage + direction.step, 0), pageCount - 1)
        guard targetPage != currentPage else {
            pageOffset = 0
            isPageTransitioning = false
            return
        }

        currentPage = targetPage
        pageOffset = 0
        isPageTransitioning = false
    }

    func completeSurfacePageTransition(_ direction: PagingDirection) {
        let targetPage = min(max(currentPage + direction.step, 0), pageCount - 1)
        guard targetPage != currentPage else {
            return
        }

        currentPage = targetPage
    }

    private func clampCurrentPage() {
        currentPage = min(max(currentPage, 0), max(pageCount - 1, 0))
    }

    private func compactPageIndexes(_ indexes: [Int]) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(indexes.count)

        for index in indexes where index >= 0 && index < pageCount && !result.contains(index) {
            result.append(index)
        }

        return result
    }

    private static func chunk(_ apps: [AppItem], capacity: Int) -> [[AppItem]] {
        guard !apps.isEmpty else {
            return []
        }

        var pages: [[AppItem]] = []
        pages.reserveCapacity(Int(ceil(Double(apps.count) / Double(capacity))))

        var startIndex = apps.startIndex
        while startIndex < apps.endIndex {
            let endIndex = apps.index(startIndex, offsetBy: capacity, limitedBy: apps.endIndex) ?? apps.endIndex
            pages.append(Array(apps[startIndex..<endIndex]))
            startIndex = endIndex
        }

        return pages.filter { !$0.isEmpty }
    }
}
