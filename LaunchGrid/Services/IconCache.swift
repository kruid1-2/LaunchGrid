import AppKit
import UniformTypeIdentifiers

final class IconCache {
    private let cache = NSCache<NSString, NSImage>()
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
        cache.countLimit = 512
    }

    func icon(for app: AppItem) -> NSImage {
        icon(forPath: app.normalizedPath)
    }

    func icon(forPath path: String) -> NSImage {
        let key = path as NSString

        if let cachedImage = cache.object(forKey: key) {
            return cachedImage
        }

        let image = workspace.icon(forFile: path)
        let finalImage = image.isValid ? image : workspace.icon(for: .applicationBundle)
        finalImage.size = NSSize(width: 128, height: 128)
        cache.setObject(finalImage, forKey: key)
        return finalImage
    }
}
