import HaloDomain
import Testing

@Suite("BlurHashDecoder (MEDIA_ATTACHMENTS FR-1)")
struct BlurHashDecoderTests {
    @Test("decodes a standard BlurHash into an RGBA8 buffer of the requested size")
    func decodesValidHash() throws {
        // Canonical BlurHash test vector from the BlurHash specification.
        let image = try #require(BlurHashDecoder.decode("LEHV6nWB2yk8pyo0adR*.7kCMdnj", width: 16, height: 12))
        #expect(image.width == 16)
        #expect(image.height == 12)
        #expect(image.rgba.count == 16 * 12 * 4)
        // Alpha channel is always opaque.
        for i in stride(from: 3, to: image.rgba.count, by: 4) {
            #expect(image.rgba[i] == 255)
        }
        // Not all pixels are identical black/white.
        let distinctR = Set(stride(from: 0, to: image.rgba.count, by: 4).map { image.rgba[$0] })
        #expect(distinctR.count > 1)
    }

    @Test("returns nil for empty, truncated, malformed, or zero-size inputs")
    func rejectsInvalidInputs() {
        #expect(BlurHashDecoder.decode("") == nil)
        #expect(BlurHashDecoder.decode("abc") == nil)
        #expect(BlurHashDecoder.decode("LEHV6nWB2yk8") == nil) // wrong length for 4x3 components
        #expect(BlurHashDecoder.decode("LEHV6nWB2yk8pyo0adR*.7kCMdnj", width: 0, height: 16) == nil)
        #expect(BlurHashDecoder.decode("LEHV6nWB2yk8pyo0adR*.7kCMdnj", width: 16, height: 0) == nil)
        #expect(BlurHashDecoder.decode("000000") != nil) // minimal 1x1 valid hash (6 chars)
        #expect(BlurHashDecoder.decode("00000 ") == nil) // space is not in base83 alphabet
    }
}
