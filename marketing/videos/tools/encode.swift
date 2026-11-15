// encode.swift — PNG 帧序列 + WAV → H.264/AAC MP4（AVAssetWriter，无需 ffmpeg）
// usage: swift encode.swift --frames DIR --fps 30 [--audio music.wav] --out out.mp4
import Foundation
import AVFoundation
import CoreMedia
import ImageIO

func argv(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

guard let framesDir = argv("--frames"), let fpsStr = argv("--fps"), let outPath = argv("--out") else {
    print("usage: swift encode.swift --frames DIR --fps N [--audio wav] --out mp4")
    exit(1)
}
let fps = Int32(fpsStr) ?? 30
let bitrate = Int32(argv("--bitrate") ?? "") ?? 12_000_000

let fm = FileManager.default
let urls = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: framesDir), includingPropertiesForKeys: nil))?
    .filter { $0.pathExtension.lowercased() == "png" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
guard !urls.isEmpty else { print("no png frames in \(framesDir)"); exit(1) }
print("frames: \(urls.count)")

func decode(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
}
guard let first = decode(urls[0]) else { print("decode first frame failed"); exit(1) }
let width = first.width, height = first.height
guard width % 2 == 0 && height % 2 == 0 else { print("odd dimensions \(width)x\(height)"); exit(1) }
print("size: \(width)x\(height) @\(fps)fps")

let outURL = URL(fileURLWithPath: outPath)
try? fm.removeItem(at: outURL)
let writer = try! AVAssetWriter(outputURL: outURL, fileType: .mp4)

let vSettings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: Int(bitrate),
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2
    ]
]
let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
vInput.expectsMediaDataInRealTime = false
writer.add(vInput)
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height
])

// ---- audio (LPCM wav in → AAC out) ----
var aInput: AVAssetWriterInput? = nil
var audioBuffers: [CMSampleBuffer] = []
if let wavPath = argv("--audio") {
    let data = try! Data(contentsOf: URL(fileURLWithPath: wavPath))
    var i = 12
    var sampleRate: UInt32 = 44100
    var channels: UInt16 = 2
    var pcm: [Int16] = []
    while i + 8 <= data.count {
        let chunkId = String(bytes: data[i..<i+4], encoding: .ascii) ?? ""
        let chunkSize = Int(data[i+4]) | Int(data[i+5]) << 8 | Int(data[i+6]) << 16 | Int(data[i+7]) << 24
        let bodyStart = i + 8
        let bodyEnd = min(bodyStart + chunkSize, data.count)
        if chunkId == "fmt " && bodyEnd - bodyStart >= 16 {
            channels = UInt16(data[bodyStart+2]) | UInt16(data[bodyStart+3]) << 8
            sampleRate = UInt32(data[bodyStart+4]) | UInt32(data[bodyStart+5]) << 8 | UInt32(data[bodyStart+6]) << 16 | UInt32(data[bodyStart+7]) << 24
        } else if chunkId == "data" {
            pcm = data.subdata(in: bodyStart..<bodyEnd).withUnsafeBytes { (p: UnsafeRawBufferPointer) in
                Array(p.bindMemory(to: Int16.self))
            }
        }
        i = bodyStart + chunkSize + (chunkSize % 2)
    }
    guard !pcm.isEmpty else { print("no pcm data in wav"); exit(1) }
    print("audio: \(pcm.count) samples (\(channels)ch @ \(sampleRate)Hz, \(String(format: "%.1f", Double(pcm.count) / (Double(channels) * Double(sampleRate))))s)")

    var asbd = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
        mBytesPerPacket: UInt32(channels) * 2, mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels) * 2,
        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
    var fmt: CMAudioFormatDescription?
    let st = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
    guard st == noErr, let fmtDesc = fmt else { print("format desc fail \(st)"); exit(1) }

    let aSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: Double(sampleRate),
        AVNumberOfChannelsKey: Int(channels),
        AVEncoderBitRateKey: 160_000
    ]
    let inp = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
    inp.expectsMediaDataInRealTime = false
    writer.add(inp)
    aInput = inp

    let chunkFrames = 16384
    let totalFrames = pcm.count / Int(channels)
    var framePos = 0
    while framePos < totalFrames {
        let n = min(chunkFrames, totalFrames - framePos)
        let byteLen = n * Int(channels) * 2
        var bb: CMBlockBuffer?
        let cst = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteLen, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteLen, flags: 0, blockBufferOut: &bb)
        guard cst == kCMBlockBufferNoErr, let block = bb else { print("blockbuf fail \(cst)"); exit(1) }
        let appended = pcm.withUnsafeBufferPointer { (ptr: UnsafeBufferPointer<Int16>) -> OSStatus in
            let base = ptr.baseAddress! + framePos * Int(channels)
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteLen)
        }
        guard appended == kCMBlockBufferNoErr else { print("replace fail"); exit(1) }
        var sb: CMSampleBuffer?
        let pts = CMTime(value: CMTimeValue(framePos), timescale: CMTimeScale(sampleRate))
        let sst = CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fmtDesc, sampleCount: CMItemCount(n), presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb)
        guard sst == noErr, let buf = sb else { print("samplebuf fail \(sst)"); exit(1) }
        audioBuffers.append(buf)
        framePos += n
    }
}

// ---- pixel buffer pool ----
var pool: [CVPixelBuffer] = []
var poolIdx = 0
for _ in 0..<4 {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ]
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    pool.append(pb!)
}

func drawInto(_ img: CGImage, _ pb: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    guard let cg = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
    cg.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
}

writer.startWriting()
writer.startSession(atSourceTime: .zero)

let done = DispatchGroup()
done.enter()
let videoWork = DispatchWorkItem {
    for (i, url) in urls.enumerated() {
        guard let img = decode(url) else { print("decode fail \(url)"); continue }
        while !vInput.isReadyForMoreMediaData { usleep(2000) }
        let pb = pool[poolIdx % pool.count]; poolIdx += 1
        drawInto(img, pb)
        let t = CMTime(value: CMTimeValue(i), timescale: fps)
        if !adaptor.append(pb, withPresentationTime: t) {
            print("append video fail at \(i): \(String(describing: writer.error))")
            break
        }
        if i % 300 == 0 { print("  video \(i)/\(urls.count)") }
    }
    vInput.markAsFinished()
    done.leave()
}
DispatchQueue(label: "video").async(execute: videoWork)

if let inp = aInput {
    done.enter()
    let audioWork = DispatchWorkItem {
        for sb in audioBuffers {
            while !inp.isReadyForMoreMediaData { usleep(2000) }
            if !inp.append(sb) { print("append audio fail: \(String(describing: writer.error))"); break }
        }
        inp.markAsFinished()
        done.leave()
    }
    DispatchQueue(label: "audio").async(execute: audioWork)
}

done.wait()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
if writer.status == .completed { print("encoded → \(outPath)") }
else { print("encode failed: \(writer.status.rawValue) \(String(describing: writer.error))"); exit(1) }
