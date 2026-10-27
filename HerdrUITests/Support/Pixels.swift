import XCTest
import UIKit

extension XCTestCase {
    /// Fraction of pixels that differ (beyond a small per-pixel threshold) between two
    /// screenshots, compared at a fixed small resolution so PNG-encoding jitter and
    /// antialiasing don't register as change. 0 = identical, 1 = fully different.
    ///
    /// FAILS THE TEST when either screenshot cannot be decoded. A made-up fraction would
    /// let a "changed" or "unchanged" assertion pass without measuring anything.
    func pixelDiffFraction(_ a: XCUIScreenshot, _ b: XCUIScreenshot,
                           file: StaticString = #filePath, line: UInt = #line) -> Double {
        let w = 90, h = 180
        guard let bufA = rgbaBuffer(a.image, w: w, h: h),
              let bufB = rgbaBuffer(b.image, w: w, h: h) else {
            XCTFail("Could not decode terminal viewport screenshots", file: file, line: line)
            return 0
        }
        var differing = 0
        var i = 0
        while i < bufA.count {
            let d = abs(Int(bufA[i]) - Int(bufB[i]))
                  + abs(Int(bufA[i + 1]) - Int(bufB[i + 1]))
                  + abs(Int(bufA[i + 2]) - Int(bufB[i + 2]))
            if d > 30 { differing += 1 }   // channel-sum threshold: ignores tiny jitter
            i += 4
        }
        return Double(differing) / Double(w * h)
    }

    /// `image` drawn into a `w`×`h` RGBA buffer, or nil if it cannot be decoded. Callers
    /// fail the test on nil.
    func rgbaBuffer(_ image: UIImage, w: Int, h: Int) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &data, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }
}

/// A screenshot's pixels in sRGB, so a colour can be looked up by the hex the app draws it in.
struct ScreenPixels {
    private let bytes: [UInt8]
    private let width: Int
    private let height: Int
    /// Pixels per point.
    private let scale: CGFloat

    init?(_ shot: XCUIScreenshot) {
        guard let image = shot.image.cgImage, shot.image.size.width > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        // CGContext's rows run top-down in memory, the screenshot's order.
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.bytes = bytes
        self.width = width
        self.height = height
        scale = CGFloat(width) / shot.image.size.width
    }

    /// How many pixels inside `rect` (in points) are within `tolerance` per channel of `hex`.
    func count(_ hex: UInt32, in rect: CGRect, tolerance: Int = 14) -> Int {
        let r = Int((hex >> 16) & 0xFF), g = Int((hex >> 8) & 0xFF), b = Int(hex & 0xFF)
        let x0 = max(0, Int(rect.minX * scale)), x1 = min(width, Int(rect.maxX * scale))
        let y0 = max(0, Int(rect.minY * scale)), y1 = min(height, Int(rect.maxY * scale))
        guard x1 > x0, y1 > y0 else { return 0 }
        var hits = 0
        for y in y0..<y1 {
            var i = (y * width + x0) * 4
            for _ in x0..<x1 {
                if abs(Int(bytes[i]) - r) <= tolerance, abs(Int(bytes[i + 1]) - g) <= tolerance,
                   abs(Int(bytes[i + 2]) - b) <= tolerance {
                    hits += 1
                }
                i += 4
            }
        }
        return hits
    }
}
