import AppKit
import UniformTypeIdentifiers

final class IconCache {
    private let cache = NSCache<NSString, NSImage>()
    private let workspace: NSWorkspace
    private let iconQueue = DispatchQueue(label: "com.launchgrid.icon-cache", qos: .utility)
    private let fallbackImage: NSImage

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
        let fallbackImage = workspace.icon(for: .applicationBundle)
        fallbackImage.size = NSSize(width: 128, height: 128)
        self.fallbackImage = fallbackImage
        cache.countLimit = 512
    }

    var placeholderIcon: NSImage {
        fallbackImage
    }

    func loadIcon(for app: AppItem, completion: @escaping (NSImage) -> Void) {
        loadIcon(forPath: app.normalizedPath, completion: completion)
    }

    func loadIcon(forPath path: String, completion: @escaping (NSImage) -> Void) {
        let key = path as NSString

        if let cachedImage = cache.object(forKey: key) {
            DispatchQueue.main.async {
                completion(cachedImage)
            }
            return
        }

        iconQueue.async { [weak self] in
            guard let self else {
                return
            }

            if let cachedImage = self.cache.object(forKey: key) {
                DispatchQueue.main.async {
                    completion(cachedImage)
                }
                return
            }

            let image = self.workspace.icon(forFile: path)
            let finalImage = image.isValid ? image : self.fallbackImage.copy() as? NSImage ?? self.fallbackImage
            finalImage.size = NSSize(width: 128, height: 128)
            self.cache.setObject(finalImage, forKey: key)

            DispatchQueue.main.async {
                completion(finalImage)
            }
        }
    }
}
