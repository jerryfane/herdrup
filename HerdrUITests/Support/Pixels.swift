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
