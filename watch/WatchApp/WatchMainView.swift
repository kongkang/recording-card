import SwiftUI
import WatchRecorderCore

struct WatchMainView: View {
    @ObservedObject var engine: WatchSessionSyncEngine

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    statusHeader
                    clockDisplay
                    primaryRecordButton
                    if engine.snapshot.isRecording {
                        markButton
                    }
                    pendingFooter
                    if let error = engine.snapshot.lastError, !error.isEmpty {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    } else if let note = engine.lastSyncNote {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .navigationTitle("录音卡")
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(engine.isPhoneReachable ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(engine.isPhoneReachable ? "已连手机" : "离线暂存")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            if engine.snapshot.batteryPercent >= 0 {
                Text("\(engine.snapshot.batteryPercent)%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var clockDisplay: some View {
        VStack(spacing: 2) {
            Text(formatClock(engine.snapshot.elapsedSec))
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .foregroundStyle(engine.snapshot.isRecording ? .red : .primary)
            Text(modeCaption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var primaryRecordButton: some View {
        Button {
            engine.toggleRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: engine.snapshot.isRecording ? "stop.fill" : "mic.fill")
                Text(engine.snapshot.isRecording ? "停止录音" : "开始录音")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(engine.snapshot.isRecording ? .red : .green)
    }

    private var markButton: some View {
        Button {
            engine.addMark()
        } label: {
            Label("打重点", systemImage: "bookmark.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private var pendingFooter: some View {
        Group {
            if engine.snapshot.pendingSliceCount > 0 || !engine.slices.isEmpty {
                NavigationLink {
                    WatchQueueView(engine: engine)
                } label: {
                    HStack {
                        Image(systemName: engine.snapshot.pendingSliceCount > 0 ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                            .foregroundStyle(engine.snapshot.pendingSliceCount > 0 ? .orange : .green)
                        Text(
                            engine.snapshot.pendingSliceCount > 0
                                ? "待传 \(engine.snapshot.pendingSliceCount) 段"
                                : "已传 \(engine.snapshot.syncedSliceCount) 段"
                        )
                        .font(.caption)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var modeCaption: String {
        if !engine.snapshot.isRecording {
            return "每 60s 本地切片"
        }
        switch engine.snapshot.keepAliveMode {
        case .workout:
            return "录音中 · 运动保活 · 第\(engine.snapshot.currentSliceIndex + 1)片"
        case .extended:
            return "录音中 · 扩展保活 · 第\(engine.snapshot.currentSliceIndex + 1)片"
        case .audioBackground:
            return "录音中 · 音频后台 · 第\(engine.snapshot.currentSliceIndex + 1)片"
        case .idle:
            return "录音中"
        }
    }

    private func formatClock(_ totalSec: Int) -> String {
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

private struct WatchQueueView: View {
    @ObservedObject var engine: WatchSessionSyncEngine

    var body: some View {
        List {
            if engine.snapshot.pendingSliceCount > 0 {
                Button("立即同步到手机") {
                    engine.flushPendingTransfers()
                }
                .tint(.green)
            }
            ForEach(engine.slices.reversed()) { slice in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("第 \(slice.sliceIndex + 1) 片")
                            .font(.caption.bold())
                        Spacer()
                        Text(stateLabel(slice.transferState))
                            .font(.caption2)
                            .foregroundStyle(stateColor(slice.transferState))
                    }
                    Text("\(slice.durationMs / 1000)s · \(ByteCountFormatter.string(fromByteCount: slice.byteSize, countStyle: .file))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let err = slice.lastError, !err.isEmpty {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("本地队列")
    }

    private func stateLabel(_ state: WatchSliceTransferState) -> String {
        switch state {
        case .pending: return "等待手机"
        case .transferring: return "传送中"
        case .synced: return "已同步"
        }
    }

    private func stateColor(_ state: WatchSliceTransferState) -> Color {
        switch state {
        case .pending: return .orange
        case .transferring: return .blue
        case .synced: return .green
        }
    }
}
