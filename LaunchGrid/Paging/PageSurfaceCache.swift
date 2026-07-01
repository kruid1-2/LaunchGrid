import CoreGraphics
import Foundation

@MainActor
final class PageSurfaceCache {
    struct Signature: Equatable {
        let viewportSize: CGSize
        let layout: LaunchpadLayout
        let pageCount: Int
        let pageIDs: [[String]]
    }

    private var nextGenerationValue = 0

    func nextGeneration() -> Int {
        nextGenerationValue += 1
        return nextGenerationValue
    }

    func signature(
        viewportSize: CGSize,
        layout: LaunchpadLayout,
        pages: [[AppItem]]
    ) -> Signature {
        Signature(
            viewportSize: viewportSize,
            layout: layout,
            pageCount: pages.count,
            pageIDs: pages.map { page in
                page.map(\.id)
            }
        )
    }
}

struct PageSurfaceSnapshot {
    let image: CGImage
    let pointSize: CGSize
    let pixelSize: CGSize
    let scale: CGFloat

    var byteCost: Int {
        image.bytesPerRow * image.height
    }
}

@MainActor
final class PageSnapshotCache {
    struct Key: Hashable, CustomStringConvertible {
        let pageIndex: Int
        let contentSignature: String
        let layoutSignature: String
        let pointWidth: Int
        let pointHeight: Int
        let scale: Int
        let appearanceSignature: String
        let iconSignature: String

        var description: String {
            "page=\(pageIndex) content=\(Self.shortDigest(contentSignature)) layout=\(Self.shortDigest(layoutSignature)) size=\(pointWidth)x\(pointHeight) scale=\(scale) appearance=\(appearanceSignature) icons=\(Self.shortDigest(iconSignature))"
        }

        private static func shortDigest(_ text: String) -> String {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            return String(hash, radix: 16)
        }
    }

    struct Entry {
        let key: Key
        let snapshot: PageSurfaceSnapshot
        var lastAccess: UInt64
    }

    struct Summary {
        let count: Int
        let estimatedBytes: Int
    }

    private let countLimit: Int
    private let byteLimit: Int
    private var clock: UInt64 = 0
    private var entries: [Key: Entry] = [:]
    private var estimatedBytes = 0

    init(countLimit: Int = 7, byteLimit: Int = 256 * 1024 * 1024) {
        self.countLimit = countLimit
        self.byteLimit = byteLimit
    }

    var summary: Summary {
        Summary(count: entries.count, estimatedBytes: estimatedBytes)
    }

    func entry(for key: Key) -> Entry? {
        guard var entry = entries[key] else {
            return nil
        }

        clock += 1
        entry.lastAccess = clock
        entries[key] = entry
        return entry
    }

    func insert(
        snapshot: PageSurfaceSnapshot,
        for key: Key,
        protectedKeys: Set<Key>
    ) -> [Entry] {
        if var existing = entries[key] {
            clock += 1
            existing.lastAccess = clock
            entries[key] = existing
            return []
        }

        clock += 1
        let entry = Entry(key: key, snapshot: snapshot, lastAccess: clock)
        entries[key] = entry
        estimatedBytes += snapshot.byteCost
        return evictIfNeeded(protectedKeys: protectedKeys.union([key]))
    }

    func removeAll() {
        entries.removeAll()
        estimatedBytes = 0
    }

    private func evictIfNeeded(protectedKeys: Set<Key>) -> [Entry] {
        var evicted: [Entry] = []
        while entries.count > countLimit || estimatedBytes > byteLimit {
            guard let key = entries
                .filter({ !protectedKeys.contains($0.key) })
                .min(by: { $0.value.lastAccess < $1.value.lastAccess })?
                .key,
                let entry = entries.removeValue(forKey: key)
            else {
                break
            }

            estimatedBytes -= entry.snapshot.byteCost
            evicted.append(entry)
        }
        return evicted
    }
}
