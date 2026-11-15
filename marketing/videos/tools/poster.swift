// poster.swift — 从 MP4 抽一帧存 JPEG 封面
// usage: swift poster.swift <in.mp4> <seconds> <out.jpg>
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 4, let t = Double(args[2]) else { print("usage: poster.swift in.mp4 seconds out.jpg"); exit(1) }
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)
        let cg = try gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
        let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL, UTType.jpeg.identifier as CFString, 1, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)!
        CGImageDestinationAddImage(dst, cg, nil)
        CGImageDestinationFinalize(dst)
        print("poster \(args[3])")
    } catch { print("fail \(args[1]): \(error.localizedDescription)"); exit(1) }
    sem.signal()
}
sem.wait()
