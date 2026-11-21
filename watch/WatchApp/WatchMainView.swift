import SwiftUI
#if canImport(WatchRecorderCore)
import WatchRecorderCore
#endif

struct WatchMainView: View {
    @ObservedObject var engine: WatchSessionSyncEngine
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var sessionMarkCount: Int = 0
    @State private var knockPulse = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let compact = geometry.size.width < 180
                let controlHeight: CGFloat = compact ? 44 : 48
                let queueHeight: CGFloat = compact ? 34 : 38
                let bottomInset = max(geometry.safeAreaInsets.bottom, compact ? 7 : 8)

                VStack(spacing: 0) {
                    centerDial(compact: compact, width: geometry.size.width)
                        .frame(maxHeight: .infinity)

                    if let error = engine.snapshot.lastError, !error.isEmpty {
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 3)
                    }
                    bottomControls(
                        height: controlHeight,
                        queueHeight: queueHeight,
                        bottomInset: bottomInset
                    )
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .overlay(alignment: .topLeading) {
                    statusLeading
                        .padding(.leading, 14)
                        // 49mm 模拟器实测：系统时间中线距屏幕顶 28pt，状态行约 11pt，顶距 22pt 时中线重合（误差 0.5px）。
                        .padding(.top, compact ? 16 : 22)
                        .ignoresSafeArea(edges: .top)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.orange, lineWidth: 2)
                        .padding(6)
                        .opacity(knockPulse ? 0.85 : 0)
                        .scaleEffect(knockPulse ? 1.02 : 0.84)
                        .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .containerBackground(Color.black, for: .navigation)
            .onChange(of: engine.snapshot.isRecording) { _, isRec in
                if isRec { sessionMarkCount = 0 }
            }
        }
    }

    /// 左侧状态贴着系统时间的中线。时间由 watchOS 绘制，这里不画。
    private var statusLeading: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(engine.isPhoneReachable ? Color(red: 0.204, green: 0.780, blue: 0.349) : Color.orange)
                .frame(width: 7, height: 7)
            Text(engine.isPhoneReachable ? "已连手机" : "离线暂存")
                .lineLimit(1)
            if engine.snapshot.isCharging || engine.snapshot.batteryPercent >= 0 {
                Text(batteryTierLabel)
                    .foregroundStyle(engine.snapshot.isCharging ? Color(red: 0.388, green: 0.902, blue: 0.525) : .white.opacity(0.72))
                    .lineLimit(1)
            }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.85))
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .combine)
    }

    private func centerDial(compact: Bool, width: CGFloat) -> some View {
        VStack(spacing: compact ? 2 : 4) {
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
                    .font(.system(size: min(38, width * (compact ? 0.16 : 0.18)), weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(remainEstimateText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.6))
                Text("轻敲两下机身打点")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.42))
                    .padding(.top, compact ? 0 : 2)
            } else {
                Text(Date(), format: .dateTime.month().day().weekday(.abbreviated))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.orange)
                Text(Date(), format: .dateTime.hour().minute())
                    .font(.system(size: compact ? 36 : 42, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text("表盘组件亦可一键开录")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard engine.snapshot.isRecording, !isLuminanceReduced else { return }
            engine.addMark()
            sessionMarkCount += 1
            triggerKnockRipple()
        }
    }

    private func bottomControls(height: CGFloat, queueHeight: CGFloat, bottomInset: CGFloat) -> some View {
        VStack(spacing: 5) {
            Group {
                if engine.snapshot.isRecording {
                    if isLuminanceReduced {
                        Text("先点亮屏幕 · 再滑动停止")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .frame(height: height)
                            .background(Color.white.opacity(0.08), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
                    } else {
                        FlatSlideToStopControl(height: height) {
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
                            .frame(height: height)
                            .background(Color(red: 0.188, green: 0.820, blue: 0.345), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)

            NavigationLink {
                WatchQueueView(engine: engine)
            } label: {
                designSliceBar(queueHeight: queueHeight, bottomInset: bottomInset)
            }
            .buttonStyle(.plain)
        }
    }

    /// 设计稿 `.w-slice-bar`：全宽贴底，上圆角 14，内容高 38，进度线高 2、左 14% 起、最长 72%。
    private func designSliceBar(queueHeight: CGFloat, bottomInset: CGFloat) -> some View {
        let lap = engine.snapshot.isRecording ? (engine.snapshot.elapsedSec % 60) : 0
        let remaining = 60 - lap
        let progress = engine.snapshot.isRecording ? Double(lap) / 60.0 : 0.0
        let pending = engine.snapshot.pendingSliceCount
        let synced = engine.snapshot.syncedSliceCount
        let footerShape = UnevenRoundedRectangle(
            topLeadingRadius: 14,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 14,
            style: .continuous
        )
        let ring = engine.snapshot.isRecording
            ? Color(red: 1, green: 0.271, blue: 0.227)
            : Color(red: 0.188, green: 0.820, blue: 0.345)

        return ZStack(alignment: .top) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1.8)
                        Circle()
                            .trim(from: engine.snapshot.isRecording ? progress : 0, to: 1)
                            .stroke(ring, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 14, height: 14)
                    Text(engine.snapshot.isRecording ? "单圈 \(remaining)s" : "单圈 60s")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.88))
                }
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    Text(footerQueueSummary(pending: pending, synced: synced))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(pending > 0 ? Color.orange : (synced > 0 ? Color(red: 0.188, green: 0.820, blue: 0.345) : .white.opacity(0.72)))
                    Text("›")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 14)
            .frame(height: queueHeight)
        }
        .frame(maxWidth: .infinity)
        .frame(height: queueHeight + bottomInset, alignment: .top)
        .background {
            footerShape
                .fill(pending > 0 ? Color.orange.opacity(0.15) : Color.white.opacity(0.09))
        }
        .overlay(alignment: .bottom) {
            if engine.snapshot.isRecording && progress > 0 {
                GeometryReader { geo in
                    let lead = geo.size.width * 0.14
                    let span = geo.size.width * 0.72 * progress
                    Capsule()
                        .fill(Color(red: 1, green: 0.271, blue: 0.227))
                        .frame(width: max(2, span), height: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .offset(x: lead)
                        .padding(.bottom, bottomInset + 2)
                }
                .allowsHitTesting(false)
            }
        }
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

    private func triggerKnockRipple() {
        knockPulse = false
        withAnimation(.easeOut(duration: 0.14)) {
            knockPulse = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) {
            withAnimation(.easeOut(duration: 0.16)) {
                knockPulse = false
            }
        }
    }
}

private struct FlatSlideToStopControl: View {
    let height: CGFloat
    let onStop: () -> Void
    @State private var dragX: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let padding: CGFloat = 4
            let knobSize = height - padding * 2
            let maxDrag = max(1, geo.size.width - knobSize - padding * 2)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.red.opacity(0.16))
                    .overlay(Capsule().stroke(Color.red.opacity(0.36), lineWidth: 1))

                Text("滑动停止录音")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.37))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, knobSize + padding * 2)
                    .padding(.trailing, 8)

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
        .frame(height: height)
    }
}

private struct WatchQueueView: View {
    @ObservedObject var engine: WatchSessionSyncEngine

    var body: some View {
        List {
            Text("手表版本 \(watchAppVersionLabel)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
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
        .toolbar(.visible, for: .navigationBar)
        .containerBackground(Color.black, for: .navigation)
    }

    private var watchAppVersionLabel: String {
        WatchSessionSyncEngine.bundledAppVersionLabel
    }

    private func stateLabel(_ state: WatchSliceTransferState) -> String {
        switch state {
        case .pending: return "等待手机"
        case .transferring: return "传送中"
        case .awaitingAck: return "待确认"
        case .synced: return "已同步"
        }
    }

    private func stateColor(_ state: WatchSliceTransferState) -> Color {
        switch state {
        case .pending: return .orange
        case .transferring, .awaitingAck: return .blue
        case .synced: return .green
        }
    }
}
