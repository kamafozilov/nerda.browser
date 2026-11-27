import Foundation

/// A recording as a WAV file: 32-bit float, one channel.
enum Wave {
    static func write(_ samples: [Float], rate: Int, to file: URL) throws {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 4
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(3)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 4)); put(UInt16(4)); put(UInt16(32))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: file)
    }
}
