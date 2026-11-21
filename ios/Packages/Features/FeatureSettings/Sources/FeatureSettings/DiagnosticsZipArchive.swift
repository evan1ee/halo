import Foundation
import HaloFoundation

/// Builds a non-compressed (STORED) `.zip` archive in memory from named entries, without external dependencies
/// (docs/architecture/LOGGING_AND_DIAGNOSTICS.md §3, SETTINGS §3).
public enum DiagnosticsZipArchive {
    public struct Entry: Sendable, Equatable {
        public let filename: String
        public let data: Data

        public init(filename: String, data: Data) {
            self.filename = filename
            self.data = data
        }

        public init(filename: String, text: String) {
            self.init(filename: filename, data: Data(text.utf8))
        }
    }

    /// Creates a standard ZIP archive containing `entries` using the `STORE` method (method 0).
    public static func build(_ entries: [Entry]) -> Data {
        var out = Data()
        var centralDirectory = Data()
        for entry in entries {
            let nameBytes = Data(entry.filename.utf8)
            let content = entry.data
            let crc = crc32(content)
            let size = UInt32(clamping: content.count)
            let localOffset = UInt32(clamping: out.count)

            // Local file header (signature 0x04034b50)
            out.appendUInt32LE(0x0403_4b50)
            out.appendUInt16LE(20) // version needed to extract (2.0)
            out.appendUInt16LE(0x0800) // general purpose bit flag: UTF-8 filename
            out.appendUInt16LE(0) // compression method: 0 (store)
            out.appendUInt16LE(0) // last mod file time
            out.appendUInt16LE(0) // last mod file date
            out.appendUInt32LE(crc)
            out.appendUInt32LE(size) // compressed size
            out.appendUInt32LE(size) // uncompressed size
            out.appendUInt16LE(UInt16(clamping: nameBytes.count))
            out.appendUInt16LE(0) // extra field length
            out.append(nameBytes)
            out.append(content)

            // Central directory file header (signature 0x02014b50)
            centralDirectory.appendUInt32LE(0x0201_4b50)
            centralDirectory.appendUInt16LE(20) // version made by
            centralDirectory.appendUInt16LE(20) // version needed to extract
            centralDirectory.appendUInt16LE(0x0800) // UTF-8 filename
            centralDirectory.appendUInt16LE(0) // compression method: store
            centralDirectory.appendUInt16LE(0) // mod time
            centralDirectory.appendUInt16LE(0) // mod date
            centralDirectory.appendUInt32LE(crc)
            centralDirectory.appendUInt32LE(size)
            centralDirectory.appendUInt32LE(size)
            centralDirectory.appendUInt16LE(UInt16(clamping: nameBytes.count))
            centralDirectory.appendUInt16LE(0) // extra field length
            centralDirectory.appendUInt16LE(0) // file comment length
            centralDirectory.appendUInt16LE(0) // disk number start
            centralDirectory.appendUInt16LE(0) // internal file attributes
            centralDirectory.appendUInt32LE(0) // external file attributes
            centralDirectory.appendUInt32LE(localOffset)
            centralDirectory.append(nameBytes)
        }

        let centralOffset = UInt32(clamping: out.count)
        let centralSize = UInt32(clamping: centralDirectory.count)
        let count = UInt16(clamping: entries.count)
        out.append(centralDirectory)

        // End of central directory record (signature 0x06054b50)
        out.appendUInt32LE(0x0605_4b50)
        out.appendUInt16LE(0) // number of this disk
        out.appendUInt16LE(0) // disk where central directory starts
        out.appendUInt16LE(count) // number of central directory records on this disk
        out.appendUInt16LE(count) // total number of central directory records
        out.appendUInt32LE(centralSize)
        out.appendUInt32LE(centralOffset)
        out.appendUInt16LE(0) // comment length
        return out
    }

    /// Standard IEEE 802.3 CRC-32 checksum used by ZIP archives.
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            var index = (crc ^ UInt32(byte)) & 0xff
            for _ in 0..<8 {
                index = (index & 1) != 0 ? (index >> 1) ^ 0xedb8_8320 : (index >> 1)
            }
            crc = (crc >> 8) ^ index
        }
        return crc ^ 0xffff_ffff
    }
}

extension Data {
    fileprivate mutating func appendUInt16LE(_ value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    fileprivate mutating func appendUInt32LE(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
