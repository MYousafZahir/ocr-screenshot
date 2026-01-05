import CoreGraphics

enum ImageUpscaler {
    static func upscale(_ image: CGImage, scale: Int) -> CGImage {
        guard scale > 1 else { return image }
        let width = image.width * scale
        let height = image.height * scale

        if let context = makeContext(for: image, width: width, height: height) {
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            if let scaled = context.makeImage() {
                return scaled
            }
        }

        if let fallback = makeFallbackContext(width: width, height: height) {
            fallback.interpolationQuality = .high
            fallback.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return fallback.makeImage() ?? image
        }

        return image
    }

    private static func makeContext(for image: CGImage, width: Int, height: Int) -> CGContext? {
        guard let colorSpace = image.colorSpace else { return nil }
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: image.bitmapInfo.rawValue
        )
    }

    private static func makeFallbackContext(width: Int, height: Int) -> CGContext? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )
    }
}
