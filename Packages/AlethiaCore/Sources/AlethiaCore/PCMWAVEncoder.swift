import Foundation

/// Mono 16-bit PCM WAV encoder used for ASR uploads and meeting archives.
public enum PCMWAVEncoder {
    public static func encode(pcm: [Float], sampleRate: Int) throws -> Data {
        var data = Data()
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * bitsPerSample / 8
        var samples = Data(capacity: pcm.count * 2)
        for s in pcm {
            let clipped = max(-1.0, min(1.0, s))
            var value = Int16((clipped * Float(Int16.max)).rounded())
            samples.append(Data(bytes: &value, count: 2))
        }
        let dataSize = UInt32(samples.count)
        func appendASCII(_ string: String) { data.append(contentsOf: string.utf8) }
        func appendU16(_ v: UInt16) { var le = v.littleEndian; data.append(Data(bytes: &le, count: 2)) }
        func appendU32(_ v: UInt32) { var le = v.littleEndian; data.append(Data(bytes: &le, count: 4)) }

        appendASCII("RIFF")
        appendU32(36 + dataSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendU32(16)
        appendU16(1) // PCM
        appendU16(channels)
        appendU32(UInt32(sampleRate))
        appendU32(byteRate)
        appendU16(blockAlign)
        appendU16(bitsPerSample)
        appendASCII("data")
        appendU32(dataSize)
        data.append(samples)
        return data
    }

    public static func write(pcm: [Float], sampleRate: Int, to url: URL) throws {
        let data = try encode(pcm: pcm, sampleRate: sampleRate)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
