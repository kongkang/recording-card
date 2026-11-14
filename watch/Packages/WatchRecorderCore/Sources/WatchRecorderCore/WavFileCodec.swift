import Foundation

/// 与 `app/` 主工程 `LiveAudioRecorder` 对齐的 16kHz / 16-bit / Mono Little-Endian PCM WAV 编解码工具。
public enum WavFileCodec {
    public static let headerByteCount = 44
    public static let defaultSampleRate: UInt32 = 16_000
    public static let defaultChannels: UInt16 = 1
    public static let defaultBitsPerSample: UInt16 = 16

    /// 生成标准 44 字节 RIFF/WAVE PCM 文件头（16kHz / 16bit / 单声道）。
    public static func makeHeader(
        pcmDataByteCount: UInt32,
        sampleRate: UInt32 = defaultSampleRate,
        channels: UInt16 = defaultChannels,
        bitsPerSample: UInt16 = defaultBitsPerSample
    ) -> Data {
        let blockAlign = channels &* (bitsPerSample / 8)
        let byteRate = sampleRate &* UInt32(blockAlign)
        let chunkSize = 36 &+ pcmDataByteCount

        var data = Data()
        data.reserveCapacity(headerByteCount)
        data.append(contentsOf: "RIFF".utf8)
        appendUInt32LE(chunkSize, to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendUInt32LE(16, to: &data)
        appendUInt16LE(1, to: &data) // PCM = 1
        appendUInt16LE(channels, to: &data)
        appendUInt32LE(sampleRate, to: &data)
        appendUInt32LE(byteRate, to: &data)
        appendUInt16LE(blockAlign, to: &data)
        appendUInt16LE(bitsPerSample, to: &data)
        data.append(contentsOf: "data".utf8)
        appendUInt32LE(pcmDataByteCount, to: &data)
        return data
    }

    /// 封装完整 16kHz Mono 16-bit PCM WAV 数据块。
    public static func wrapPCM16Mono(
        _ pcmBytes: Data,
        sampleRate: UInt32 = defaultSampleRate
    ) -> Data {
        var out = makeHeader(
            pcmDataByteCount: UInt32(clamping: pcmBytes.count),
            sampleRate: sampleRate,
            channels: 1,
            bitsPerSample: 16
        )
        out.append(pcmBytes)
        return out
    }

    public struct WavHeaderInfo: Equatable, Sendable {
        public let audioFormat: UInt16
        public let channels: UInt16
        public let sampleRate: UInt32
        public let bitsPerSample: UInt16
        public let dataByteCount: UInt32

        public init(
            audioFormat: UInt16,
            channels: UInt16,
            sampleRate: UInt32,
            bitsPerSample: UInt16,
            dataByteCount: UInt32
        ) {
            self.audioFormat = audioFormat
            self.channels = channels
            self.sampleRate = sampleRate
            self.bitsPerSample = bitsPerSample
            self.dataByteCount = dataByteCount
        }
    }

    /// 校验标准 44 字节 PCM WAV 头字段。
    public static func parseHeader(_ data: Data) -> WavHeaderInfo? {
        guard data.count >= headerByteCount else { return nil }
        guard String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF",
              String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE",
              String(data: data.subdata(in: 12..<16), encoding: .ascii) == "fmt ",
              String(data: data.subdata(in: 36..<40), encoding: .ascii) == "data" else {
            return nil
        }
        return WavHeaderInfo(
            audioFormat: readUInt16LE(data, at: 20),
            channels: readUInt16LE(data, at: 22),
            sampleRate: readUInt32LE(data, at: 24),
            bitsPerSample: readUInt16LE(data, at: 34),
            dataByteCount: readUInt32LE(data, at: 40)
        )
    }

    /// 对齐主端 `LiveAudioSlice.sliceKey` 命名规则：`LIVE_WATCH_<sessionTag>_0001.WAV`。
    public static func liveWatchWavFileName(sessionId: String, sliceIndex: Int) -> String {
        let sanitized = sessionId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "live-", with: "")
            .replacingOccurrences(of: "watch-", with: "")
        let tag = sanitized.isEmpty ? "session" : sanitized
        let seq = String(format: "%04d", max(1, sliceIndex + 1))
        return "LIVE_WATCH_\(tag)_\(seq).WAV"
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
