import Foundation

struct AppItem: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleIdentifier: String?
    let applicationURL: URL
    let normalizedPath: String

    init(
        name: String,
        bundleIdentifier: String?,
        applicationURL: URL,
        normalizedPath: String
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.applicationURL = applicationURL
        self.normalizedPath = normalizedPath
        self.id = bundleIdentifier?.isEmpty == false ? bundleIdentifier! : normalizedPath
    }
}
