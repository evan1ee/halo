import Foundation

/// Pure-Swift BlurHash decoder producing 8-bit RGBA pixels for inline media placeholders (MEDIA_ATTACHMENTS FR-1).
/// Linux-buildable, zero third-party dependencies.
public enum BlurHashDecoder {
    public struct Image: Sendable, Equatable {
        public let width: Int
        public let height: Int
        /// `width * height * 4` RGBA8 bytes.
        public let rgba: [UInt8]
    }

    private static let base83Characters: [UInt8] = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~".utf8
    )

    private static let decodeTable: [Int] = {
        var table = Array(repeating: -1, count: 128)
        for (index, byte) in base83Characters.enumerated() {
            table[Int(byte)] = index
        }
        return table
    }()

    /// Decodes a BlurHash string into an `width × height` RGBA8 pixel buffer, or returns `nil` if the hash is invalid.
    public static func decode(_ blurHash: String, width: Int = 32, height: Int = 32, punch: Float = 1.0) -> Image? {
        guard width > 0, height > 0 else { return nil }
        let bytes = Array(blurHash.utf8)
        guard bytes.count >= 6 else { return nil }
        guard let sizeFlag = decode83(bytes, start: 0, length: 1) else { return nil }

        let numY = (sizeFlag / 9) + 1
        let numX = (sizeFlag % 9) + 1
        let expectedLength = 4 + 2 * numX * numY
        guard bytes.count == expectedLength else { return nil }

        guard let quantisedMax = decode83(bytes, start: 1, length: 1) else { return nil }
        let maxValue = Float(quantisedMax + 1) / 166.0

        var colors: [(Float, Float, Float)] = []
        colors.reserveCapacity(numX * numY)

        guard let dcValue = decode83(bytes, start: 2, length: 4) else { return nil }
        colors.append(decodeDC(dcValue))

        for i in 1..<(numX * numY) {
            guard let acValue = decode83(bytes, start: 4 + i * 2, length: 2) else { return nil }
            colors.append(decodeAC(acValue, maxValue: maxValue * punch))
        }

        // Precompute cosine tables for fast O(W*H*numX*numY) evaluation.
        var cosX = Array(repeating: Float(0), count: width * numX)
        for x in 0..<width {
            let fx = Float.pi * Float(x) / Float(width)
            for i in 0..<numX {
                cosX[x * numX + i] = cos(fx * Float(i))
            }
        }
        var cosY = Array(repeating: Float(0), count: height * numY)
        for y in 0..<height {
            let fy = Float.pi * Float(y) / Float(height)
            for j in 0..<numY {
                cosY[y * numY + j] = cos(fy * Float(j))
            }
        }

        var rgba = Array(repeating: UInt8(255), count: width * height * 4)
        for y in 0..<height {
            let yBase = y * numY
            for x in 0..<width {
                let xBase = x * numX
                var r: Float = 0
                var g: Float = 0
                var b: Float = 0
                for j in 0..<numY {
                    let cy = cosY[yBase + j]
                    let rowBase = j * numX
                    for i in 0..<numX {
                        let basis = cosX[xBase + i] * cy
                        let c = colors[rowBase + i]
                        r += c.0 * basis
                        g += c.1 * basis
                        b += c.2 * basis
                    }
                }
                let offset = (y * width + x) * 4
                rgba[offset] = linearToSRGB(r)
                rgba[offset + 1] = linearToSRGB(g)
                rgba[offset + 2] = linearToSRGB(b)
                rgba[offset + 3] = 255
            }
        }
        return Image(width: width, height: height, rgba: rgba)
    }

    private static func decode83(_ bytes: [UInt8], start: Int, length: Int) -> Int? {
        var value = 0
        for i in start..<(start + length) {
            let b = Int(bytes[i])
            guard b < 128 else { return nil }
            let digit = decodeTable[b]
            guard digit >= 0 else { return nil }
            value = value * 83 + digit
        }
        return value
    }

    private static func decodeDC(_ value: Int) -> (Float, Float, Float) {
        let r = value >> 16
        let g = (value >> 8) & 255
        let b = value & 255
        return (sRGBToLinear(r), sRGBToLinear(g), sRGBToLinear(b))
    }

    private static func decodeAC(_ value: Int, maxValue: Float) -> (Float, Float, Float) {
        let quantR = value / (19 * 19)
        let quantG = (value / 19) % 19
        let quantB = value % 19
        return (
            signPow(Float(quantR - 9) / 9.0, 2.0) * maxValue,
            signPow(Float(quantG - 9) / 9.0, 2.0) * maxValue,
            signPow(Float(quantB - 9) / 9.0, 2.0) * maxValue
        )
    }

    private static func sRGBToLinear(_ value: Int) -> Float {
        let v = Float(value) / 255.0
        if v <= 0.04045 { return v / 12.92 }
        return pow((v + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ value: Float) -> UInt8 {
        let v = min(max(value, 0.0), 1.0)
        let s: Float = v <= 0.0031308 ? (v * 12.92) : (1.055 * pow(v, 1.0 / 2.4) - 0.055)
        return UInt8(min(max(Int(s * 255.0 + 0.5), 0), 255))
    }

    private static func signPow(_ value: Float, _ exp: Float) -> Float {
        copysign(pow(abs(value), exp), value)
    }
}
