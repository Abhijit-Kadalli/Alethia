import Foundation

/// 16-bit PCM WAV encoding/decoding for mono Float32 audio.
public enum WAVCodec {
    public static let headerSize = 44

    public static func header(sampleRate: Int, dataBytes: Int, channels: Int = 1) -> Data {
        var data = Data(capacity: headerSize)
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLE(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(channels))
        data.appendLE(UInt32(sampleRate))
        data.appendLE(UInt32(byteRate))
        data.appendLE(UInt16(blockAlign))
        data.appendLE(UInt16(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        data.appendLE(UInt32(dataBytes))
        return data
    }

    /// Converts Float32 samples in −1…1 to little-endian Int16 bytes.
    public static func pcm16Bytes(from samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1, min(1, s))
            let v = Int16(clamped * Float(Int16.max))
            data.appendLE(UInt16(bitPattern: v))
        }
        return data
    }

    public static func encode(pcm: [Float], sampleRate: Int) -> Data {
        let body = pcm16Bytes(from: pcm)
        var data = header(sampleRate: sampleRate, dataBytes: body.count)
        data.append(body)
        return data
    }

    public static func write(pcm: [Float], sampleRate: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(pcm: pcm, sampleRate: sampleRate).write(to: url, options: .atomic)
    }

    public struct Decoded: Sendable {
        public var samples: [Float]
        public var sampleRate: Int
        public var channels: Int
    }

    /// Decodes 16-bit PCM WAV (interleaved channels are averaged to mono).
    public static func decode(_ data: Data) throws -> Decoded {
        guard data.count >= headerSize,
              String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF",
              String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE" else {
            throw AlethiaError.invalidInput("Not a WAV file")
        }
        var offset = 12
        var sampleRate = 16_000
        var channels = 1
        var bits = 16
        var pcmData: Data?
        while offset + 8 <= data.count {
            let chunkID = String(data: data.subdata(in: offset..<offset + 4), encoding: .ascii) ?? ""
            let chunkSize = Int(data.readLE(UInt32.self, at: offset + 4))
            let bodyStart = offset + 8
            let bodyEnd = min(bodyStart + chunkSize, data.count)
            if chunkID == "fmt " {
                let format = data.readLE(UInt16.self, at: bodyStart)
                guard format == 1 else { throw AlethiaError.invalidInput("Only PCM WAV is supported") }
                channels = Int(data.readLE(UInt16.self, at: bodyStart + 2))
                sampleRate = Int(data.readLE(UInt32.self, at: bodyStart + 4))
                bits = Int(data.readLE(UInt16.self, at: bodyStart + 14))
            } else if chunkID == "data" {
                pcmData = data.subdata(in: bodyStart..<bodyEnd)
                break
            }
            offset = bodyStart + chunkSize + (chunkSize % 2)
        }
        guard let pcmData, bits == 16, channels >= 1 else {
            throw AlethiaError.invalidInput("Unsupported WAV layout")
        }
        let frameCount = pcmData.count / (2 * channels)
        var samples = [Float](repeating: 0, count: frameCount)
        pcmData.withUnsafeBytes { raw in
            let int16 = raw.bindMemory(to: Int16.self)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for c in 0..<channels {
                    sum += Float(Int16(littleEndian: int16[frame * channels + c]))
                }
                samples[frame] = sum / Float(channels) / Float(Int16.max)
            }
        }
        return Decoded(samples: samples, sampleRate: sampleRate, channels: channels)
    }

    public static func read(_ url: URL) throws -> Decoded {
        try decode(Data(contentsOf: url))
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        guard offset + MemoryLayout<T>.size <= count else { return 0 }
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { dest in
            copyBytes(to: dest, from: offset..<offset + MemoryLayout<T>.size)
        }
        return T(littleEndian: value)
    }
}
