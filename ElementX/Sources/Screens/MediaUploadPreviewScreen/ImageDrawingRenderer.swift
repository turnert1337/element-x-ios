//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ImageIO
import PaperKit
import SwiftUI
import UniformTypeIdentifiers

/// A finished drawing that draws itself into a context with a top-left origin, stretched over `frame`.
nonisolated struct ImageDrawing: Sendable {
    let draw: @Sendable (CGContext, CGRect) async -> Void
}

@available(iOS 26, *)
nonisolated extension ImageDrawing {
    /// Draws `markup` in light-mode colours, its bounds stretched over the frame.
    init(markup: PaperMarkup) {
        draw = { context, frame in
            let bounds = markup.bounds
            context.saveGState()
            // PaperKit draws the markup at its own size, whatever the frame, so map its bounds onto the frame.
            context.translateBy(x: frame.minX, y: frame.minY)
            context.scaleBy(x: frame.width / bounds.width, y: frame.height / bounds.height)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            await markup.draw(in: context, frame: bounds, options: RenderingOptions(darkUserInterfaceStyle: false))
            context.restoreGState()
        }
    }
}

nonisolated enum ImageDrawingRendererError: Error {
    case failedLoadingImage
    case failedDrawing
    case failedWritingImage(Error)
}

nonisolated enum ImageDrawingRenderer {
    /// Whether the image at `url` can be drawn on: an image type that decodes to exactly one frame.
    static func canDraw(onImageAt url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let size = orientedPixelSize(of: source) else {
            return false
        }
        return size.width > 0 && size.height > 0
    }
    
    /// The image's size in pixels once its EXIF orientation is applied.
    static func orientedPixelSize(ofImageAt url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return orientedPixelSize(of: source)
    }
    
    /// The longest side to decode the drawing preview at: sharp when zoomed in, without going past the texture limit or decoding a huge photo.
    static func previewMaxPixelSize(forPixelSize pixelSize: CGSize) -> CGFloat {
        let longestSide = max(pixelSize.width, pixelSize.height)
        let maxPixelCount: CGFloat = 16_000_000
        let scale = min(1, (maxPixelCount / (pixelSize.width * pixelSize.height)).squareRoot())
        return min(longestSide * scale, 8192)
    }
    
    /// An upright copy of the image, at most `maxPixelSize` pixels on its longest side, to show while drawing.
    static func previewImage(ofImageAt url: URL, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = uprightImage(of: source, maxPixelSize: maxPixelSize) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
    
    /// Draws `drawing`, stretched over the whole image, onto the image at `url`, and overwrites the file with a JPEG.
    @concurrent static func draw(_ drawing: ImageDrawing, ontoImageAt url: URL) async throws(ImageDrawingRendererError) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let size = orientedPixelSize(of: source),
              let photo = uprightImage(of: source, maxPixelSize: max(size.width, size.height)) else {
            throw .failedLoadingImage
        }
        
        let bounds = CGRect(x: 0, y: 0, width: photo.width, height: photo.height)
        // An 8-bit context can't be made in an extended range colour space (float and HDR pictures), so fall back to sRGB.
        guard let context = makeContext(width: photo.width, height: photo.height, colorSpace: photo.colorSpace)
            ?? makeContext(width: photo.width, height: photo.height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw .failedDrawing
        }
        context.draw(photo, in: bounds)
        // Drawings expect UIKit's top-left origin.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        await drawing.draw(context, bounds)
        
        let data = NSMutableData()
        guard let drawnImage = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw .failedDrawing
        }
        CGImageDestinationAddImage(destination, drawnImage, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw .failedDrawing
        }
        
        do {
            try (data as Data).write(to: url, options: .atomic)
        } catch {
            throw .failedWritingImage(error)
        }
    }
    
    // MARK: - Private
    
    private static func orientedPixelSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int,
              var height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        
        if let orientation = properties[kCGImagePropertyOrientation] as? UInt32, (5...8).contains(orientation) {
            swap(&width, &height)
        }
        
        return CGSize(width: width, height: height)
    }
    
    private static func makeContext(width: Int, height: Int, colorSpace: CGColorSpace?) -> CGContext? {
        guard let colorSpace, colorSpace.model == .rgb, colorSpace.supportsOutput else {
            return nil
        }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    
    /// Decodes the first image with its EXIF orientation applied, scaled down so that its longest side is at most `maxPixelSize`.
    private static func uprightImage(of source: CGImageSource, maxPixelSize: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
