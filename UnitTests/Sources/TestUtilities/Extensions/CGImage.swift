//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CoreGraphics

extension CGImage {
    /// The sRGB colour of one pixel, counting from the top-left corner.
    func pixel(atX x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) { // swiftlint:disable:this large_tuple
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                fatalError("Failed creating a 1 × 1 context")
            }
            context.interpolationQuality = .none
            // Core Graphics counts from the bottom-left corner, so shift the requested pixel onto the context.
            context.draw(self, in: CGRect(x: -x, y: -(height - 1 - y), width: width, height: height))
        }
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }
    
    /// A transparent image of `size` pixels, with `rect` (top-left origin, in pixels) filled with `color`.
    static func testImage(size: CGSize, filling rect: CGRect, with color: CGColor) -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Failed creating a \(size) context")
        }
        context.setFillColor(color)
        context.fill(CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height))
        guard let image = context.makeImage() else {
            fatalError("Failed making the test image")
        }
        return image
    }
}
