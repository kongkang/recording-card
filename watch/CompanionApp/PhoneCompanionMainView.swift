import SwiftUI
import WatchRecorderCore

struct PhoneCompanionMainView: View {
    @ObservedObject var controller: PhoneWatchSessionController
    @State private var guideExpanded = true

    var body: some View {
        NavigationStack {
            List {
                statusSection
                controlsSection
                watchFaceGuideSection
                receivedSlicesSection
            }
            .navigationTitle("手表录音笔")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        controller.refreshWatchStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新手表状态")
                }
            }
        }
    }

    private var statusSection: some View {
        Section("手表连接与运行状态") {
            HStack {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 10, height: 10)
                Text(connectionTitle)
                    .font(.headline)
                Spacer()
                if controller.watchStatus.batteryPercent >= 0 {
                    Label(
                        "\(controller.watchStatus.batteryPercent)%",
                        systemImage: controller.watchStatus.isCharging ? "battery.100.bolt" : "battery.75"
                    )
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("腕上录音")
                Spacer()
                if controller.watchStatus.isRecording {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text(formatClock(controller.watchStatus.elapsedSec))
                            .font(.body.monospacedDigit().weight(.semibold))
                    }
                } else {
                    Text("未录音")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("手表本地待传切片")
                Spacer()
                Text("\(controller.watchStatus.pendingSliceCount) 段")
                    .foregroundStyle(controller.watchStatus.pendingSliceCount > 0 ? .orange : .secondary)
            }

            if controller.watchStatus.isRecording {
                HStack {
                    Text("息屏保活通道")
                    Spacer()
                    Text(keepAliveLabel(controller.watchStatus.keepAliveMode))
                        .foregroundStyle(.secondary)
                }
            }

            if let banner = controller.bannerMessage {
                Text(banner)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let error = controller.errorMessage ?? controller.watchStatus.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var controlsSection: some View {
        Section("远程控制（纯本地直连，不经服务器）") {
            Button {
                if controller.watchStatus.isRecording {
                    controller.stopWatchRecording()
                } else {
                    controller.startWatchRecording()
                }
            } label: {
                HStack {
                    Spacer()
                    if controller.isCommandBusy {
                        ProgressView()
                            .padding(.trailing, 6)
                    }
                    Image(systemName: controller.watchStatus.isRecording ? "stop.circle.fill" : "record.circle")
                    Text(controller.watchStatus.isRecording ? "停止手表录音" : "开启手表录音")
                        .fontWeight(.semibold)
                    Spacer()
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(controller.watchStatus.isRecording ? .red : .accentColor)
            .disabled(controller.isCommandBusy || !controller.isPaired)

            HStack(spacing: 12) {
                Button {
                    controller.markOnWatch()
                } label: {
                    Label("打重点", systemImage: "bookmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!controller.watchStatus.isRecording)

                Button {
                    controller.requestWatchSync()
                } label: {
                    Label("催传切片", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!controller.isPaired)
            }
        }
    }

    private var watchFaceGuideSection: some View {
        Section {
            DisclosureGroup("添加到表盘以持续开启、持续录音", isExpanded: $guideExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. 长按 Apple Watch 表盘 → 点「编辑」→ 滑到「复杂功能」。")
                    Text("2. 选中角落或矩形槽位，添加「录音卡」，可常驻查看录音状态并一键开停录。")
                    Text("3. 手表无网络/脱离手机时自动将 60s AAC 切片存在腕上本地，靠近手机后自动按序回传为 16kHz WAV。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            }
        }
    }

    private var receivedSlicesSection: some View {
        Section("手机已收到的本地 WAV 切片（\(controller.receivedSlices.count)）") {
            if controller.receivedSlices.isEmpty {
                Text("暂无已传输切片。开启手表录音满 60 秒或停止录音后，切片将通过 WatchConnectivity 自动本地落盘到这里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.receivedSlices) { slice in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("第 \(slice.sliceIndex + 1) 片 · \(slice.wavFileName)")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            if slice.offlineRecorded {
                                Text("离线补传")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.15))
                                    .foregroundStyle(.orange)
                                    .clipShape(Capsule())
                            }
                        }

                        Text(summarySubtitle(for: slice))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !slice.marksOffsetMs.isEmpty {
                            let markLabels = slice.marksOffsetMs.map { "\($0 / 1000)s" }.joined(separator: "、")
                            Text("重点标记（相对起点）：\(markLabels)")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }

                        HStack(spacing: 12) {
                            Button {
                                controller.togglePlayback(for: slice)
                            } label: {
                                Label(
                                    controller.playingSliceId == slice.sliceId ? "停止试听" : "试听 WAV",
                                    systemImage: controller.playingSliceId == slice.sliceId ? "stop.fill" : "play.fill"
                                )
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            ShareLink(item: controller.wavURL(for: slice)) {
                                Label("导出", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Spacer()
                            if slice.exportedToSharedInbox {
                                Text("已入共享收件箱")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .swipeActions {
                        Button(role: .destructive) {
                            controller.deleteSlice(slice)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private var statusDotColor: Color {
        if !controller.isPaired { return .gray }
        if !controller.isWatchAppInstalled { return .orange }
        return controller.isReachable ? .green : .yellow
    }

    private var connectionTitle: String {
        if !controller.isPaired { return "未配对 Apple Watch" }
        if !controller.isWatchAppInstalled { return "手表端 App 未安装" }
        return controller.isReachable ? "手表已连接（可即时控制）" : "手表已配对（待机/后台可达）"
    }

    private func keepAliveLabel(_ mode: WatchKeepAliveMode) -> String {
        switch mode {
        case .workout: return "HKWorkoutSession 运动保活"
        case .extended: return "WKExtendedRuntimeSession"
        case .audioBackground: return "UIBackgroundModes audio"
        case .idle: return "未激活"
        }
    }

    private func formatClock(_ sec: Int) -> String {
        String(format: "%02d:%02d:%02d", sec / 3600, (sec % 3600) / 60, sec % 60)
    }

    private func summarySubtitle(for slice: ReceivedWatchSlice) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(slice.startAtMs) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        let sizeText = ByteCountFormatter.string(fromByteCount: slice.wavByteSize, countStyle: .file)
        return "\(formatter.string(from: start)) · 时长 \(slice.durationMs / 1000)s · \(sizeText)"
    }
}
