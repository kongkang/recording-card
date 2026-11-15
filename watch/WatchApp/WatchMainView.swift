import SwiftUI
import WatchRecorderCore

struct WatchMainView: View {
    @ObservedObject var engine: WatchSessionSyncEngine
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var sessionMarkCount: Int = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 6) {
                statusHeader
                Spacer(minLength: 2)
                centerDial
                Spacer(minLength: 2)
                if let error = engine.snapshot.lastError, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                bottomControls
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.black)
            .onChange(of: engine.snapshot.isRecording) { _, isRec in
                if isRec { sessionMarkCount = 0 }
            }
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(engine.isPhoneReachable ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(engine.isPhoneReachable ? "已连手机" : "离线暂存")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            if engine.snapshot.isCharging || engine.snapshot.batteryPercent >= 0 {
                Text(batteryTierLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(engine.snapshot.isCharging ? Color.green : Color.white.opacity(0.72))
            }
        }
    }

    private var centerDial: some View {
        VStack(spacing: 3) {
            if engine.snapshot.isRecording {
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                        Text("录音中")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    if sessionMarkCount > 0 {
                        Text("已打点 \(sessionMarkCount)")
                            .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                    }
                }
                Text(formatClock(engine.snapshot.elapsedSec))
                    .font(.system(size: 32, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(remainEstimateText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.6))
                Text("轻敲两下机身打点")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.42))
                    .padding(.top, 2)
            } else {
                Text(Date(), format: .dateTime.month().day().weekday(.abbreviated))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.orange)
                Text(Date(), format: .dateTime.hour().minute())
                    .font(.system(size: 42, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text("表盘组件亦可一键开录")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard engine.snapshot.isRecording, !isLuminanceReduced else { return }
            engine.addMark()
            sessionMarkCount += 1
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 6) {
            if engine.snapshot.isRecording {
                if isLuminanceReduced {
                    Text("先点亮屏幕 · 再滑动停止")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.68))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(Color.white.opacity(0.08), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
                } else {
                    FlatSlideToStopControl {
                        engine.toggleRecording()
                    }
                }
            } else {
                Button {
                    engine.toggleRecording()
                } label: {
                    Text("开始录音")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(Color.green, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            NavigationLink {
                WatchQueueView(engine: engine)
            } label: {
                singleLapQueueFooter
            }
            .buttonStyle(.plain)
        }
    }

    private var singleLapQueueFooter: some View {
        let lap = engine.snapshot.isRecording ? (engine.snapshot.elapsedSec % 60) : 0
        let remaining = 60 - lap
        let progress = engine.snapshot.isRecording ? Double(lap) / 60.0 : 0.0
        let pending = engine.snapshot.pendingSliceCount
        let synced = engine.snapshot.syncedSliceCount

        return ZStack(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1.8)
                        Circle()
                            .trim(from: progress, to: 1)
                            .stroke(
                                engine.snapshot.isRecording ? Color.red : Color.green,
                                style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 13, height: 13)
                    Text(engine.snapshot.isRecording ? "单圈 \(remaining)s" : "单圈 60s")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.88))
                }
                Spacer()
                HStack(spacing: 3) {
                    Text(footerQueueSummary(pending: pending, synced: synced))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(pending > 0 ? Color.orange : (synced > 0 ? Color.green : Color.white.opacity(0.65)))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)

            GeometryReader { geo in
                Rectangle()
                    .fill(Color.red)
                    .frame(width: geo.size.width * progress, height: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .allowsHitTesting(false)
        }
        .background(
            pending > 0 ? Color.orange.opacity(0.15) : Color.white.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func footerQueueSummary(pending: Int, synced: Int) -> String {
        if pending > 0 { return "待传 \(pending) 段" }
        if synced > 0 { return "已同步 \(synced) 段" }
        if engine.snapshot.isRecording { return "第 \(engine.snapshot.currentSliceIndex + 1) 段" }
        return "队列 0"
    }

    private var remainEstimateText: String {
        if engine.snapshot.isCharging { return "充电取电 · 可持续录音" }
        let pct = engine.snapshot.batteryPercent
        if pct >= 0 && pct < 20 { return "还可录 · 约 40 分钟" }
        if pct >= 0 && pct < 40 { return "还可录 · 约 1.5 小时" }
        return "还可录 · 约 3.5 小时"
    }

    private var batteryTierLabel: String {
        if engine.snapshot.isCharging {
            return "充电中"
        }
        let pct = engine.snapshot.batteryPercent
        if pct < 20 {
            return "电量低"
        }
        if pct < 40 {
            return "电量中"
        }
        return "电量高"
    }

    private func formatClock(_ totalSec: Int) -> String {
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

private struct FlatSlideToStopControl: View {
    let onStop: () -> Void
    @State private var dragX: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let knobSize: CGFloat = 30
            let padding: CGFloat = 3
            let maxDrag = max(1, geo.size.width - knobSize - padding * 2)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.red.opacity(0.16))
                    .overlay(Capsule().stroke(Color.red.opacity(0.36), lineWidth: 1))

                Text("滑动停止录音")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.37))
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 16)

                Circle()
                    .fill(Color.red)
                    .frame(width: knobSize, height: knobSize)
                    .overlay(
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .offset(x: padding + dragX)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragX = min(max(0, value.translation.width), maxDrag)
                            }
                            .onEnded { value in
                                let finalX = min(max(0, value.translation.width), maxDrag)
                                if finalX >= maxDrag * 0.88 {
                                    dragX = 0
                                    onStop()
                                } else {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        dragX = 0
                                    }
                                }
                            }
                    )
            }
        }
        .frame(height: 36)
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
