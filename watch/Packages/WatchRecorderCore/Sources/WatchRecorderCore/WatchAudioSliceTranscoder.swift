#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// 将手表传回的压缩切片（`.m4a`）或兼容音频文件本地转码为标准 `16kHz / 16-bit / Mono PCM WAV`，
/// 直接对接 `app/` 端侧 SenseVoice + Silero VAD + CAM++ 管线，全程离线本机完成。
public enum WatchAudioSliceTranscoder {
    /// 转码音频至 16kHz / 16-bit / Mono PCM WAV，并返回实际音频时长（毫秒）。
    @discardableResult
    public static func transcodeTo16kMonoWav(
        sourceURL: URL,
        destinationURL: URL
    ) throws -> Int64 {
        let inputFile = try AVAudioFile(forReading: sourceURL)
        let inputFormat = inputFile.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(WavFileCodec.defaultSampleRate),
            channels: AVAudioChannelCount(WavFileCodec.defaultChannels),
            interleaved: true
        ) else {
            throw NSError(
                domain: "RCWatchTranscoder",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无法创建 16kHz 单声道 PCM 输出格式"]
            )
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(
                domain: "RCWatchTranscoder",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "无法初始化音频重采样转换器"]
            )
        }

        let inputCapacity: AVAudioFrameCount = 4096
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputCapacity) else {
            throw NSError(
                domain: "RCWatchTranscoder",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "无法分配音频输入缓冲区"]
            )
        }

        var pcmData = Data()
        let ratio = targetFormat.sampleRate / max(1, inputFormat.sampleRate)
        let outputCapacity = AVAudioFrameCount(ceil(Double(inputCapacity) * ratio) + 512)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw NSError(
                domain: "RCWatchTranscoder",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "无法分配音频输出缓冲区"]
            )
        }

        var reachedEOF = false
        while !reachedEOF {
            inputBuffer.frameLength = 0
            let remaining = inputFile.length - inputFile.framePosition
            if remaining <= 0 {
                reachedEOF = true
            } else {
                let framesToRead = AVAudioFrameCount(min(AVAudioFramePosition(inputCapacity), remaining))
                try inputFile.read(into: inputBuffer, frameCount: framesToRead)
                if inputBuffer.frameLength == 0 {
                    reachedEOF = true
                }
            }

            var didFeedChunk = false
            var convError: NSError?
            outputBuffer.frameLength = 0
            let status = converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
                if reachedEOF {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if didFeedChunk {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                didFeedChunk = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if let convError {
                throw convError
            }
            if outputBuffer.frameLength > 0, let ptr = outputBuffer.int16ChannelData?.pointee {
                let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
                pcmData.append(Data(bytes: ptr, count: byteCount))
            }
            if status == .endOfStream || status == .error {
                break
            }
        }

        let wavData = WavFileCodec.wrapPCM16Mono(pcmData)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try wavData.write(to: destinationURL, options: [.atomic])

        let frameCount = Double(pcmData.count / MemoryLayout<Int16>.size)
        let durationMs = Int64((frameCount / Double(WavFileCodec.defaultSampleRate) * 1000.0).rounded())
        return max(0, durationMs)
    }
}
#endif
