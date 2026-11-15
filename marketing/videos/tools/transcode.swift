// transcode.swift — 用 AVAssetExportSession 把大码率 MP4 转成 web 友好体积（H.264 1080p）
// usage: swift transcode.swift <in.mp4> <out.mp4>
import AVFoundation

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: transcode.swift in.mp4 out.mp4"); exit(1) }
let src = URL(fileURLWithPath: args[1]), dst = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: dst)
let asset = AVURLAsset(url: src)
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        guard let session = try await AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            print("no session for \(args[1])"); exit(1)
        }
        session.outputURL = dst
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        if session.status == .completed {
            let sz = (try? FileManager.default.attributesOfItem(atPath: args[2])[.size] as? Int) ?? 0
            print("transcode \(args[2]) \(sz ?? 0)")
        } else { print("fail \(args[1]): \(String(describing: session.error))"); exit(1) }
    } catch { print("fail \(args[1]): \(error)"); exit(1) }
    sem.signal()
}
sem.wait()
