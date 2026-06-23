import Foundation

struct AppScanner {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func scanApplications() async -> [AppItem] {
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let rootPaths = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            homeDirectory.appendingPathComponent("Applications").path
        ]

        let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

        return await Task.detached(priority: .utility) {
            var scanner = ScanAccumulator(fileManager: .default)

            for path in rootPaths {
                scanner.scanDirectory(URL(fileURLWithPath: path))
            }

            scanner.addApplicationIfValid(finderURL)

            return scanner.items.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }.value
    }
}

private struct ScanAccumulator {
    private(set) var items: [AppItem] = []
    private var seenKeys = Set<String>()
    private let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    mutating func scanDirectory(_ directoryURL: URL) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return
        }

        for case let fileURL as URL in enumerator {
            if isHidden(fileURL) {
                enumerator.skipDescendants()
                continue
            }

            guard fileURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                continue
            }

            addApplicationIfValid(fileURL)
            enumerator.skipDescendants()
        }
    }

    mutating func addApplicationIfValid(_ appURL: URL) {
        guard fileManager.fileExists(atPath: appURL.path), !isHidden(appURL) else {
            return
        }

        let normalizedPath = appURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard let appItem = makeAppItem(from: appURL, normalizedPath: normalizedPath) else {
            return
        }

        guard !isClearlyInternalApplication(appItem.name) else {
            return
        }

        let dedupeKey = appItem.bundleIdentifier?.isEmpty == false
            ? "bundle:\(appItem.bundleIdentifier!)"
            : "path:\(normalizedPath)"

        guard !seenKeys.contains(dedupeKey) else {
            return
        }

        seenKeys.insert(dedupeKey)
        items.append(appItem)
    }

    private func makeAppItem(from appURL: URL, normalizedPath: String) -> AppItem? {
        let bundle = Bundle(url: appURL)
        let localizedInfo = bundle?.localizedInfoDictionary
        let info = bundle?.infoDictionary

        let displayName = localizedInfo?["CFBundleDisplayName"] as? String
            ?? info?["CFBundleDisplayName"] as? String
        let bundleName = localizedInfo?["CFBundleName"] as? String
            ?? info?["CFBundleName"] as? String
        let fallbackName = appURL.deletingPathExtension().lastPathComponent
        let name = [displayName, bundleName, fallbackName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? fallbackName

        return AppItem(
            name: name,
            bundleIdentifier: bundle?.bundleIdentifier,
            applicationURL: appURL,
            normalizedPath: normalizedPath
        )
    }

    private func isHidden(_ url: URL) -> Bool {
        if url.lastPathComponent.hasPrefix(".") {
            return true
        }

        do {
            return try url.resourceValues(forKeys: [.isHiddenKey]).isHidden == true
        } catch {
            return false
        }
    }

    private func isClearlyInternalApplication(_ name: String) -> Bool {
        let internalMarkers = [
            "Helper",
            "Updater",
            "Agent",
            "Crash Reporter"
        ]

        return internalMarkers.contains { marker in
            name.range(of: marker, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
