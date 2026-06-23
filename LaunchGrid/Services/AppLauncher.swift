import AppKit

@MainActor
final class AppLauncher {
    enum LaunchError: LocalizedError {
        case didNotReturnRunningApplication
        case failed(Error)

        var errorDescription: String? {
            switch self {
            case .didNotReturnRunningApplication:
                return "The application did not report a running process."
            case .failed(let error):
                return error.localizedDescription
            }
        }
    }

    func launch(_ app: AppItem, completion: @escaping (Result<Void, LaunchError>) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(
            at: app.applicationURL,
            configuration: configuration
        ) { runningApplication, error in
            Task { @MainActor in
                if let error {
                    completion(.failure(.failed(error)))
                    return
                }

                guard let runningApplication else {
                    completion(.failure(.didNotReturnRunningApplication))
                    return
                }

                runningApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                completion(.success(()))
            }
        }
    }
}
