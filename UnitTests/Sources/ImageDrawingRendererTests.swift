//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import ImageIO
import PaperKit
import PencilKit
import SwiftUI
import Testing
import UniformTypeIdentifiers

final class ImageDrawingRendererTests {
    @Test
    func canDrawOnlyOnStillImages() throws {
        #expect(try ImageDrawingRenderer.canDraw(onImageAt: resourceURL("test_image.png")))
        #expect(try ImageDrawingRenderer.canDraw(onImageAt: resourceURL("test_rotated_image.jpg")))
        #expect(try !ImageDrawingRenderer.canDraw(onImageAt: resourceURL("test_animated_image.gif")))
        #expect(try !ImageDrawingRenderer.canDraw(onImageAt: resourceURL("test_pdf.pdf")))
        #expect(!ImageDrawingRenderer.canDraw(onImageAt: URL(filePath: "/missing/picture.jpg")))
    }
    
    @Test
    func previewIsSharpButBounded() {
        // Small pictures keep every pixel.
        #expect(ImageDrawingRenderer.previewMaxPixelSize(forPixelSize: CGSize(width: 3024, height: 4032)) == 4032)
        // 48 MP is scaled down to about 16 MP.
        let largePhoto = ImageDrawingRenderer.previewMaxPixelSize(forPixelSize: CGSize(width: 8064, height: 6048))
        #expect(abs(largePhoto * largePhoto * 6048 / 8064 - 16_000_000) < 10000)
        // Very long pictures stop at the texture limit.
        #expect(ImageDrawingRenderer.previewMaxPixelSize(forPixelSize: CGSize(width: 20000, height: 100)) == 8192)
    }
    
    @Test
    func markupRendersWhereItWasDrawnInTrueColours() async throws {
        let url = try copyResourceToTemporaryDirectory("test_image.png") // 240 × 240.
        var markup = PaperMarkup(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        markup.append(contentsOf: blackLineDrawing(atY: 25))
        
        // The editor makes the drawing in a dark sheet.
        var drawing: ImageDrawing?
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            drawing = ImageDrawing(markup: markup)
        }
        try await ImageDrawingRenderer.draw(#require(drawing), ontoImageAt: url)
        
        let image = try decodedImage(at: url)
        let onLine = image.pixel(atX: 120, y: 60)
        #expect(onLine.red < 60 && onLine.green < 60 && onLine.blue < 60, "Black ink must stay black, near the top where it was drawn.")
        let belowLine = image.pixel(atX: 120, y: 180)
        #expect(!(belowLine.red < 60 && belowLine.green < 60 && belowLine.blue < 60), "The ink must not be flipped to the bottom.")
    }
    
    @Test
    func markupOnAVeryWidePanoramaRenders() async throws {
        // Wider than the 8192 (simulator) and 16384 (device) pixel texture limits.
        let url = try writePicture(width: 20000, height: 100, color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        var markup = PaperMarkup(bounds: CGRect(x: 0, y: 0, width: 1000, height: 5))
        markup.append(contentsOf: blackLineDrawing(from: 100, to: 990, atY: 2.5))
        
        try await ImageDrawingRenderer.draw(ImageDrawing(markup: markup), ontoImageAt: url)
        
        let image = try decodedImage(at: url)
        #expect(image.width == 20000)
        #expect(image.height == 100)
        for x in [10000, 19000] {
            let onLine = image.pixel(atX: x, y: 50)
            #expect(onLine.red < 60 && onLine.green < 60 && onLine.blue < 60, "The line must be drawn, not lost, at x = \(x).")
        }
        let beforeLine = image.pixel(atX: 500, y: 50)
        #expect(beforeLine.blue > 200, "The panorama must show through.")
    }
    
    @Test
    func drawingOnARotatedPhotoKeepsItUpright() async throws {
        let url = try copyResourceToTemporaryDirectory("test_rotated_image.jpg") // Stored as 4272 × 2848, with EXIF orientation 8.
        #expect(ImageDrawingRenderer.orientedPixelSize(ofImageAt: url) == CGSize(width: 2848, height: 4272))
        
        // A red top-left quarter, which also pins the top-left origin drawings get.
        try await ImageDrawingRenderer.draw(redDrawing(filling: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)), ontoImageAt: url)
        
        let source = try #require(CGImageSourceCreateWithURL(url as NSURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 2848)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 4272)
        #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        let quarterCentre = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)).pixel(atX: 712, y: 1068)
        #expect(quarterCentre.red > 200 && quarterCentre.green < 60 && quarterCentre.blue < 60)
    }
    
    @Test
    func drawingOnADisplayP3PhotoKeepsItsColourSpace() async throws {
        let url = try copyResourceToTemporaryDirectory("portrait_test_image.jpg") // 3024 × 4032, Display P3.
        
        try await ImageDrawingRenderer.draw(redDrawing(filling: CGRect(x: 0, y: 0, width: 0.25, height: 0.25)), ontoImageAt: url)
        
        let image = try decodedImage(at: url)
        #expect(image.width == 3024)
        #expect(image.height == 4032)
        #expect(image.colorSpace?.name == CGColorSpace.displayP3)
    }
    
    @Test
    func drawingOnAnExtendedRangePictureFallsBackToSRGB() async throws {
        let url = try writeExtendedRangePicture(width: 64, height: 32)
        
        try await ImageDrawingRenderer.draw(redDrawing(filling: CGRect(x: 0, y: 0, width: 0.5, height: 1)), ontoImageAt: url)
        
        let image = try decodedImage(at: url)
        #expect(image.width == 64)
        #expect(image.height == 32)
        let inDrawing = image.pixel(atX: 16, y: 16)
        #expect(inDrawing.red > 200 && inDrawing.green < 60 && inDrawing.blue < 60)
    }
    
    // MARK: - Private
    
    private func resourceURL(_ name: String) throws -> URL {
        try #require(Bundle(for: Self.self).url(forResource: name, withExtension: nil))
    }
    
    private func decodedImage(at url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as NSURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    
    /// A black line across a canvas, from `startX` to `endX`.
    private func blackLineDrawing(from startX: CGFloat = 10, to endX: CGFloat = 90, atY y: CGFloat) -> PKDrawing {
        let points = stride(from: startX, through: endX, by: 10).enumerated().map { index, x in
            PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: Double(index) / 100, size: CGSize(width: 10, height: 10),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black),
                                            path: PKStrokePath(controlPoints: points, creationDate: .now))])
    }
    
    /// A drawing that fills `unitRect`, given as a fraction of the frame from its top-left corner, with red.
    private func redDrawing(filling unitRect: CGRect) -> ImageDrawing {
        ImageDrawing { context, frame in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: frame.minX + unitRect.minX * frame.width, y: frame.minY + unitRect.minY * frame.height,
                                width: unitRect.width * frame.width, height: unitRect.height * frame.height))
        }
    }
    
    /// A PNG of `width` × `height` pixels filled with `color`.
    private func writePicture(width: Int, height: Int, color: CGColor) throws -> URL {
        let size = CGSize(width: width, height: height)
        return try write(CGImage.testImage(size: size, filling: CGRect(origin: .zero, size: size), with: color), as: .png)
    }
    
    /// A TIFF of 16-bit floats in the extended sRGB colour space, the kind of picture an 8-bit context can't be made for.
    private func writeExtendedRangePicture(width: Int, height: Int) throws -> URL {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedSRGB))
        let bitmapInfo = CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0,
                                             space: colorSpace, bitmapInfo: bitmapInfo))
        try context.setFillColor(#require(CGColor(colorSpace: colorSpace, components: [0.2, 0.4, 1.4, 1])))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try write(#require(context.makeImage()), as: .tiff)
    }
    
    private func write(_ picture: CGImage, as type: UTType) throws -> URL {
        let url = try temporaryFileURL(pathExtension: type.preferredFilenameExtension ?? "")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, picture, nil)
        try #require(CGImageDestinationFinalize(destination))
        return url
    }
    
    /// Copies a test asset to a uniquely named file, so the test can overwrite it.
    private func copyResourceToTemporaryDirectory(_ resource: String) throws -> URL {
        let assetURL = try resourceURL(resource)
        let url = try temporaryFileURL(pathExtension: assetURL.pathExtension)
        try FileManager.default.copyItem(at: assetURL, to: url)
        return url
    }
    
    private func temporaryFileURL(pathExtension: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.self)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(UUID().uuidString).\(pathExtension)")
    }
}
