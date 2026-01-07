import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum PaddingBlur {
    private static let logScaleFactor: Double = 9.0
    private static let logDenominator = log(1.0 + logScaleFactor)
    private static let context = CIContext()

    static func apply(to image: CGImage, focusRect: CGRect, flipY: Bool) -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 1, height > 1 else { return image }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let focus = focusRect.integral.intersection(bounds)
        guard !focus.isEmpty else { return image }

        let maxPad = max(
            max(focus.minX, bounds.width - focus.maxX),
            max(focus.minY, bounds.height - focus.maxY)
        )
        guard maxPad > 0 else { return image }

        let input = CIImage(cgImage: image)
        let radius = max(1.0, maxPad)
        let blurred = input
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius])
            .cropped(to: input.extent)

        guard let mask = makeMask(width: width, height: height, focusRect: focus, flipY: flipY) else {
            return image
        }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = blurred
        blend.backgroundImage = input
        blend.maskImage = mask

        guard let output = blend.outputImage else { return image }
        return context.createCGImage(output, from: input.extent) ?? image
    }

    private static func makeMask(width: Int, height: Int, focusRect: CGRect, flipY: Bool) -> CIImage? {
        let rowBytes = width
        var data = Data(count: rowBytes * height)

        let minX = Double(focusRect.minX)
        let maxX = Double(focusRect.maxX)
        let minY = Double(focusRect.minY)
        let maxY = Double(focusRect.maxY)
        let widthD = Double(width)
        let heightD = Double(height)

        let leftPad = max(1.0, minX)
        let rightPad = max(1.0, widthD - maxX)
        let minYPad = max(1.0, minY)
        let maxYPad = max(1.0, heightD - maxY)

        var xWeights = [UInt8](repeating: 0, count: width)
        for x in 0..<width {
            let xCoord = Double(x) + 0.5
            let ratio: Double
            if xCoord < minX {
                ratio = (minX - xCoord) / leftPad
            } else if xCoord > maxX {
                ratio = (xCoord - maxX) / rightPad
            } else {
                ratio = 0
            }
            xWeights[x] = weightForRatio(ratio)
        }

        var yWeights = [UInt8](repeating: 0, count: height)
        for y in 0..<height {
            let yCoord = flipY ? (Double(y) + 0.5) : (heightD - 1.0 - Double(y) + 0.5)
            let ratio: Double
            if yCoord < minY {
                ratio = (minY - yCoord) / minYPad
            } else if yCoord > maxY {
                ratio = (yCoord - maxY) / maxYPad
            } else {
                ratio = 0
            }
            yWeights[y] = weightForRatio(ratio)
        }

        data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<height {
                let rowStart = base + y * rowBytes
                let yWeight = yWeights[y]
                for x in 0..<width {
                    let value = max(xWeights[x], yWeight)
                    rowStart[x] = value
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        guard let mask = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: rowBytes,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }
        return CIImage(cgImage: mask)
    }

    private static func weightForRatio(_ ratio: Double) -> UInt8 {
        let clamped = min(1.0, max(0.0, ratio))
        let weight = log(1.0 + logScaleFactor * clamped) / logDenominator
        let scaled = Int((weight * 255.0).rounded())
        return UInt8(clamping: scaled)
    }
}
