import AVFoundation
import Foundation
import WatchRecorderCore

/// 将手表推回来的 `.m4a`（16kHz AAC）本地解码为标准 `16kHz / 16-bit / Mono PCM WAV`，
/// 对齐 `app/` 主工程本地转写管线契约，不走任何云端接口。
enum AudioSliceTranscoder {
    static func transcodeTo16kMonoWav(sourceM4AURL: URL, destinationWavURL: URL) throws -> Int64 {
        let inputFile = try AVAudioFile(forReading: sourceM4AURL)
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
            at: destinationWavURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try wavData.write(to: destinationWavURL, options: [.atomic])
        return Int64(wavData.count)
    }

    /// 若共享 App Group 容器（`group.com.reai.recordingcard`）可用，
    /// 同步投递一份标准 16kHz WAV 与描述 JSON 到 `watch_inbox/`，供主端 App 直接拾取转写。
    static func copyToSharedWatchInboxIfAvailable(
        wavURL: URL,
        descriptor: WatchSliceDescriptor
    ) -> Bool {
        guard let groupRoot = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WatchConstants.appGroupId
        ) else {
            return false
        }
        let inboxDir = groupRoot.appendingPathComponent("watch_inbox", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
            let targetWav = inboxDir.appendingPathComponent(descriptor.canonicalWavFileName, isDirectory: false)
            if FileManager.default.fileExists(atPath: targetWav.path) {
                try FileManager.default.removeItem(at: targetWav)
            }
            try FileManager.default.copyItem(at: wavURL, to: targetWav)

            let metaURL = inboxDir.appendingPathComponent("\(descriptor.sliceId).json", isDirectory: false)
            let metaData = try JSONEncoder().encode(descriptor)
            try metaData.write(to: metaURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }
}
