import SwiftUI
import AppKit
import QuickLookThumbnailing
import BRAWBridge
import CZCommanderCore

/// Background thumbnail generation for the Thumbs view.
/// - `.braw` clips: first frame decoded through the Blackmagic RAW API (if a decoder is installed)
/// - everything else: macOS QuickLook (images, video, PDF, documents, any installed QL extension)
/// Results are cached in memory by path + modification date + size.
final class ThumbnailLoader: @unchecked Sendable {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, NSImage>()
    /// Blackmagic RAW decoding is CPU/GPU heavy and serialized inside the bridge.
    private let brawQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    private init() {
        cache.countLimit = 1500
    }

    static func cacheKey(for item: FileItem, pixelSize: Int) -> String {
        "\(item.fullPath)|\(item.modificationDate.timeIntervalSince1970)|\(item.size)|\(pixelSize)"
    }

    func cachedImage(for item: FileItem, pixelSize: Int) -> NSImage? {
        cache.object(forKey: Self.cacheKey(for: item, pixelSize: pixelSize) as NSString)
    }

    func thumbnail(for item: FileItem, pointSize: CGFloat) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixelSize = Int((pointSize * scale).rounded())
        let key = Self.cacheKey(for: item, pixelSize: pixelSize) as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let image: NSImage?
        if item.ext.lowercased() == "braw" {
            image = await brawThumbnail(path: item.fullPath, pixelSize: pixelSize)
        } else {
            image = await quickLookThumbnail(path: item.fullPath, pointSize: pointSize, scale: scale)
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private func brawThumbnail(path: String, pixelSize: Int) async -> NSImage? {
        await withCheckedContinuation { continuation in
            brawQueue.addOperation {
                guard let cg = CZBRAWCreateThumbnail(path, Int32(pixelSize)) else {
                    continuation.resume(returning: nil)
                    return
                }
                let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                continuation.resume(returning: image)
            }
        }
    }

    private func quickLookThumbnail(path: String, pointSize: CGFloat, scale: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: pointSize, height: pointSize),
            scale: scale,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.nsImage)
            }
        }
    }
}

/// Thumbnail cell image: shows the cached / generated thumbnail, or the file-type icon meanwhile.
struct AsyncThumbnailView: View {
    let item: FileItem
    let pointSize: CGFloat
    let fallbackSymbol: String
    let fallbackColor: Color

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSymbol)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
                    .foregroundColor(fallbackColor)
            }
        }
        .task(id: ThumbnailLoader.cacheKey(for: item, pixelSize: Int(pointSize))) {
            guard !item.isDirectory, !item.isParentDirectoryEntry else { return }
            if let hit = ThumbnailLoader.shared.cachedImage(for: item, pixelSize: Int(pointSize * (NSScreen.main?.backingScaleFactor ?? 2))) {
                image = hit
                return
            }
            image = nil
            let result = await ThumbnailLoader.shared.thumbnail(for: item, pointSize: pointSize)
            if !Task.isCancelled { image = result }
        }
    }
}
