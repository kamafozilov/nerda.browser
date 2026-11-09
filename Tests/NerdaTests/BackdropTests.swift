import CoreGraphics
import Foundation
import Testing
@testable import Nerda

/// The pixels of `image`, top row first: red, green, blue and alpha, premultiplied.
private func pixels(of image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
}

/// A picture `width` × `height`, each pixel as `color` says, the top row first.
private func picture(width: Int, height: Int, color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (red, green, blue) = color(x, y)
            bytes[(y * width + x) * 4 ..< (y * width + x) * 4 + 3] = [red, green, blue]
        }
    }
    let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    return context.makeImage()!
}

/// A new tab's picture, made once, is the page's size, its middle kept the
/// right way up, half see-through at the top and nearly gone at the bottom.
@Test func newTabPictureIsMadeForThePageAsItWouldBeDrawn() throws {
    // Red over blue, tall, on a wide page: only the middle shows, red above.
    let tall = picture(width: 100, height: 200) { _, y in y < 100 ? (255, 0, 0) : (0, 0, 255) }
    let canvas = Backdrop.Canvas(size: CGSize(width: 100, height: 50), scale: 2)
    let made = try #require(Backdrop.composite(of: tall, for: canvas))
    #expect(made.width == 200 && made.height == 100)
    let bytes = pixels(of: made)
    let top = Array(bytes[400 ..< 404])
    #expect(abs(Int(top[3]) - 140) <= 2)
    #expect(abs(Int(top[0]) - Int(top[3])) <= 2 && top[2] <= 2)
    let bottom = Array(bytes[(99 * 200 + 100) * 4 ..< (99 * 200 + 100) * 4 + 4])
    #expect(abs(Int(bottom[3]) - 14) <= 2)
    #expect(bottom[2] >= bottom[3] - 2 && bottom[0] <= 2)
}

/// Sharp at the top, under the field, and blurred toward the bottom.
@Test func newTabPictureIsBlurredOnlyTowardTheBottom() throws {
    let stripes = picture(width: 400, height: 400) { x, _ in (x / 4) % 2 == 0 ? (255, 255, 255) : (0, 0, 0) }
    let made = try #require(Backdrop.composite(of: stripes, for: Backdrop.Canvas(size: CGSize(width: 200, height: 200), scale: 2)))
    let bytes = pixels(of: made)
    func spread(row: Int) -> Int {
        let values = (180 ..< 220).map { Int(bytes[(row * 400 + $0) * 4]) }
        return values.max()! - values.min()!
    }
    #expect(spread(row: 10) > 120)
    #expect(spread(row: 390) <= 2)
}
