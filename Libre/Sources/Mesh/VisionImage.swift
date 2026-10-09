// VisionImage.swift
// Pasa (Mac AI peer): shrinks a photo before it goes to the local vision model, so the model reads
// fewer image tokens and answers faster. JPEG out, longest edge at most VisionPolicy.maxEdgePixels.

import Foundation
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

enum VisionImage {
    /// Downscaled JPEG, or nil when the bytes are not an image ImageIO can read.
    static func downscale(_ data: Data, maxEdge: Int = VisionPolicy.maxEdgePixels, quality: Double = 0.8) -> Data? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
        #else
        return nil
        #endif
    }
}
