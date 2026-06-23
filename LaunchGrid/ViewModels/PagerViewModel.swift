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
    private var transitionTask: Task<Void, Never>?

    var visiblePageIndexes: [Int] {
        guard pageCount > 0 else {
            return []
        }

        let lowerBound = max(0, currentPage - 1)
        let upperBound = min(pageCount - 1, currentPage + 1)
        return Array(lowerBound...upperBound)
    }

    var isInteractionLocked: Bool {
        isPageTransitioning || abs(pageOffset) > 1
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
        pages = Self.chunk(filteredApps, capacity: capacity)
        pageCount = pages.count
        clampCurrentPage()
        pageOffset = 0
        rebuildCount += 1
    }

    func setDragOffset(_ offset: CGFloat, limit: CGFloat) {
        guard !isPageTransitioning else {
            return
        }

        pageOffset = min(max(offset, -limit), limit)
    }

    func cancelDrag(animationDuration: TimeInterval) {
        withAnimation(.easeOut(duration: animationDuration * 0.72)) {
            pageOffset = 0
        }
    }

    func stepPage(_ step: Int, animationDuration: TimeInterval) {
        guard !isPageTransitioning, pageCount > 1 else {
            return
        }

        let targetPage = min(max(currentPage + step, 0), pageCount - 1)
        guard targetPage != currentPage else {
            cancelDrag(animationDuration: animationDuration)
            return
        }

        transitionTask?.cancel()
        isPageTransitioning = true

        withAnimation(.easeInOut(duration: animationDuration)) {
            currentPage = targetPage
            pageOffset = 0
        }

        transitionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((animationDuration + 0.08) * 1_000_000_000))
            await MainActor.run {
                guard let self else {
                    return
                }

                self.isPageTransitioning = false
            }
        }
    }

    private func clampCurrentPage() {
        currentPage = min(max(currentPage, 0), max(pageCount - 1, 0))
    }

    private static func chunk(_ apps: [AppItem], capacity: Int) -> [[AppItem]] {
        guard !apps.isEmpty else {
            return [[]]
        }

        var pages: [[AppItem]] = []
        pages.reserveCapacity(Int(ceil(Double(apps.count) / Double(capacity))))

        var startIndex = apps.startIndex
        while startIndex < apps.endIndex {
            let endIndex = apps.index(startIndex, offsetBy: capacity, limitedBy: apps.endIndex) ?? apps.endIndex
            pages.append(Array(apps[startIndex..<endIndex]))
            startIndex = endIndex
        }

        return pages
    }
}
