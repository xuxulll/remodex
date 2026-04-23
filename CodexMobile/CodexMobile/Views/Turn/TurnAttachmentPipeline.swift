// FILE: TurnAttachmentPipeline.swift
// Purpose: Normalizes picked images into payload+thumbnail and caches decoded previews.
// Layer: View Helper
// Exports: TurnAttachmentPipeline, TurnComposerImageAttachment, TurnComposerImageAttachmentState
// Depends on: SwiftUI, CodexImageAttachment

import SwiftUI
#if os(iOS)
#if os(iOS)
import UIKit
#endif
#elseif os(macOS)
import AppKit
#endif

#if os(iOS)
typealias TurnPlatformImage = UIImage
#elseif os(macOS)
typealias TurnPlatformImage = NSImage
#endif

enum TurnAttachmentPipeline {
    static let thumbnailSide: CGFloat = 70
    static let thumbnailCornerRadius: CGFloat = 12

    private static let maxPayloadDimension: CGFloat = 1600
    private static let payloadCompressionQuality: CGFloat = 0.8
    private static let thumbnailCompressionQuality: CGFloat = 0.8
    private static let thumbnailCache = NSCache<NSString, TurnPlatformImage>()

    // Builds both payload and preview formats from raw picker data.
    static func makeAttachment(from sourceData: Data) -> CodexImageAttachment? {
        guard let normalizedJPEGData = normalizePayloadJPEG(from: sourceData),
              let thumbnailBase64 = makeThumbnailBase64JPEG(from: normalizedJPEGData) else {
            return nil
        }

        let payloadDataURL = "data:image/jpeg;base64,\(normalizedJPEGData.base64EncodedString())"
        return CodexImageAttachment(
            thumbnailBase64JPEG: thumbnailBase64,
            payloadDataURL: payloadDataURL,
            sourceURL: nil
        )
    }

    // Decodes/returns cached thumbnails so scrolling does not repeatedly decode base64.
    static func thumbnailImage(fromBase64 value: String) -> TurnPlatformImage? {
        guard !value.isEmpty else {
            return nil
        }

        let cacheKey = value as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }

        guard let data = Data(base64Encoded: value),
              let image = imageFromData(data) else {
            return nil
        }

        thumbnailCache.setObject(image, forKey: cacheKey)
        return image
    }

    // Converts any image source into a normalized JPEG payload to keep network and memory predictable.
    private static func normalizePayloadJPEG(from sourceData: Data) -> Data? {
        #if os(iOS)
        guard let image = UIImage(data: sourceData) else {
            return nil
        }

        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return nil
        }

        let longestSide = max(sourceSize.width, sourceSize.height)
        let scale = min(1, maxPayloadDimension / longestSide)
        let targetSize = CGSize(width: floor(sourceSize.width * scale), height: floor(sourceSize.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)

        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        return rendered.jpegData(compressionQuality: payloadCompressionQuality)
        #elseif os(macOS)
        guard let image = NSImage(data: sourceData) else {
            return nil
        }

        let size = image.size
        guard size.width > 0, size.height > 0 else {
            return nil
        }

        let longestSide = max(size.width, size.height)
        let scale = min(1, maxPayloadDimension / longestSide)
        let targetSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let resized = resizedImage(image, targetSize: targetSize)
        return jpegData(from: resized, compression: payloadCompressionQuality)
        #endif
    }

    // Produces the exact 70x70 cover thumbnail shown in composer and user bubble.
    private static func makeThumbnailBase64JPEG(from imageData: Data) -> String? {
        #if os(iOS)
        guard let image = UIImage(data: imageData) else {
            return nil
        }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: thumbnailSide, height: thumbnailSide))
        let rendered = renderer.image { _ in
            let sourceSize = image.size
            let scale = max(thumbnailSide / sourceSize.width, thumbnailSide / sourceSize.height)
            let scaledSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
            let origin = CGPoint(
                x: (thumbnailSide - scaledSize.width) / 2,
                y: (thumbnailSide - scaledSize.height) / 2
            )
            image.draw(in: CGRect(origin: origin, size: scaledSize))
        }

        guard let jpegData = rendered.jpegData(compressionQuality: thumbnailCompressionQuality) else {
            return nil
        }
        return jpegData.base64EncodedString()
        #elseif os(macOS)
        guard let image = NSImage(data: imageData) else {
            return nil
        }

        let canvasSize = CGSize(width: thumbnailSide, height: thumbnailSide)
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return nil
        }

        let scale = max(thumbnailSide / sourceSize.width, thumbnailSide / sourceSize.height)
        let scaledSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let origin = CGPoint(
            x: (thumbnailSide - scaledSize.width) / 2,
            y: (thumbnailSide - scaledSize.height) / 2
        )

        let thumbnail = NSImage(size: canvasSize)
        thumbnail.lockFocus()
        image.draw(in: CGRect(origin: origin, size: scaledSize))
        thumbnail.unlockFocus()

        guard let data = jpegData(from: thumbnail, compression: thumbnailCompressionQuality) else {
            return nil
        }
        return data.base64EncodedString()
        #endif
    }

    private static func imageFromData(_ data: Data) -> TurnPlatformImage? {
        #if os(iOS)
        return UIImage(data: data)
        #elseif os(macOS)
        return NSImage(data: data)
        #endif
    }

    #if os(macOS)
    private static func resizedImage(_ image: NSImage, targetSize: CGSize) -> NSImage {
        let resized = NSImage(size: targetSize)
        resized.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: targetSize))
        resized.unlockFocus()
        return resized
    }

    private static func jpegData(from image: NSImage, compression: CGFloat) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: compression]
        )
    }
    #endif
}
