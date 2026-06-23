import Foundation

@MainActor
final class LauncherViewModel: ObservableObject {
    @Published private(set) var apps: [AppItem] = []
    @Published var searchText = ""
    @Published var isScanning = false
    @Published var errorMessage: String?

    private let scanner: AppScanner
    private let launcher: AppLauncher
    private var hasLoadedApplications = false

    init(scanner: AppScanner = AppScanner()) {
        self.scanner = scanner
        self.launcher = AppLauncher()
    }

    var filteredApps: [AppItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return apps
        }

        return apps.filter { app in
            app.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || app.bundleIdentifier?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    func loadApplicationsIfNeeded() {
        guard !hasLoadedApplications else {
            return
        }

        hasLoadedApplications = true
        reloadApplications()
    }

    func reloadApplications() {
        isScanning = true
        errorMessage = nil

        Task {
            let scannedApps = await scanner.scanApplications()
            apps = scannedApps
            isScanning = false

            if scannedApps.isEmpty {
                errorMessage = "No applications were found."
            }
        }
    }

    func clearSearch() {
        searchText = ""
    }

    func launch(_ app: AppItem, onSuccess: @escaping () -> Void) {
        errorMessage = nil

        launcher.launch(app) { [weak self] result in
            switch result {
            case .success:
                onSuccess()
            case .failure(let error):
                self?.errorMessage = "Could not open \(app.name): \(error.localizedDescription)"
            }
        }
    }

    func launchFirstResult(onSuccess: @escaping () -> Void) {
        guard let firstApp = filteredApps.first else {
            return
        }

        launch(firstApp, onSuccess: onSuccess)
    }
}
