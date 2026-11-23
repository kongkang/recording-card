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
        let theme = WatchThemePalette(style: engine.uiStyle)
        NavigationStack {
            GeometryReader { geometry in
                let compact = geometry.size.width < 180
                let controlHeight: CGFloat = compact ? 44 : 48
                let queueHeight: CGFloat = compact ? 34 : 38
                let bottomInset = max(geometry.safeAreaInsets.bottom, compact ? 7 : 8)

                ZStack {
                    themeBackdrop(theme: theme)

                    VStack(spacing: 0) {
                        centerDial(theme: theme, compact: compact, width: geometry.size.width)
                            .frame(maxHeight: .infinity)

                        if let error = engine.snapshot.lastError, !error.isEmpty {
                            Text(error)
                                .font(.system(size: 10))
                                .foregroundStyle(theme.recordingAccent)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 3)
                        }
                        bottomControls(
                            theme: theme,
                            height: controlHeight,
                            queueHeight: queueHeight,
                            bottomInset: bottomInset
                        )
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .overlay(alignment: .topLeading) {
                        statusLeading(theme: theme)
                            .padding(.leading, 14)
                            // 49mm 模拟器实测：系统时间中线距屏幕顶 28pt，状态行约 11pt，顶距 22pt 时中线重合（误差 0.5px）。
                            .padding(.top, compact ? 16 : 22)
                            .ignoresSafeArea(edges: .top)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(theme.markColor, lineWidth: 2)
                            .padding(6)
                            .opacity(knockPulse ? 0.88 : 0)
                            .scaleEffect(knockPulse ? 1.02 : 0.84)
                            .allowsHitTesting(false)
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .containerBackground(theme.bg, for: .navigation)
            .onChange(of: engine.snapshot.isRecording) { _, isRec in
                if isRec { sessionMarkCount = 0 }
            }
        }
    }

    @ViewBuilder
    private func themeBackdrop(theme: WatchThemePalette) -> some View {
        ZStack {
            theme.bg

            switch theme.style {
            case .braunField:
                Canvas { context, size in
                    let step: CGFloat = 14
                    var y: CGFloat = 18
                    while y < size.height - 24 {
                        var x: CGFloat = 12
                        while x < size.width - 10 {
                            let rect = CGRect(x: x, y: y, width: 1.5, height: 1.5)
                            context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.08)))
                            x += step
                        }
                        y += step
                    }
                }
                .allowsHitTesting(false)

            case .chronos:
                HStack(spacing: 0) {
                    VStack(spacing: 7) {
                        ForEach(0..<12, id: \.self) { idx in
                            Capsule()
                                .fill(idx % 3 == 0 ? theme.accent.opacity(0.65) : Color.white.opacity(0.18))
                                .frame(width: idx % 3 == 0 ? 7 : 3.5, height: 1.5)
                        }
                    }
                    .padding(.leading, 5)
                    Spacer()
                }
                .allowsHitTesting(false)

            case .folio:
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)

            case .air:
                RadialGradient(
                    colors: [
                        (engine.snapshot.isRecording ? theme.recordingAccent : theme.accent).opacity(0.28),
                        .clear,
                    ],
                    center: .top,
                    startRadius: 4,
                    endRadius: 96
                )
                .allowsHitTesting(false)

            case .warmPaper, .nocturne:
                EmptyView()
            }
        }
    }

    /// 左侧状态贴着系统时间的中线。时间由 watchOS 绘制，这里不画。
    private func statusLeading(theme: WatchThemePalette) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(engine.isPhoneReachable ? theme.battColor : theme.markColor)
                .frame(width: 7, height: 7)
            Text(engine.isPhoneReachable ? "已连手机" : "离线暂存")
                .lineLimit(1)
            if engine.snapshot.isCharging || engine.snapshot.batteryPercent >= 0 {
                Text(batteryTierLabel)
                    .foregroundStyle(engine.snapshot.isCharging ? theme.battColor : theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 10.5, weight: .semibold, design: theme.metaDesign))
        .foregroundStyle(theme.textPrimary.opacity(0.86))
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .combine)
    }

    private func centerDial(theme: WatchThemePalette, compact: Bool, width: CGFloat) -> some View {
        VStack(spacing: compact ? 2 : 4) {
            if engine.snapshot.isRecording {
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(theme.recordingAccent)
                            .frame(width: 6, height: 6)
                        Text("录音中")
                            .font(.system(size: 10.5, weight: .semibold, design: theme.metaDesign))
                            .foregroundStyle(theme.textPrimary.opacity(0.82))
                    }
                    if sessionMarkCount > 0 {
                        Text("已打点 \(sessionMarkCount)")
                            .font(.system(size: 9.5, weight: .bold, design: theme.metaDesign).monospacedDigit())
                            .foregroundStyle(theme.markColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(theme.markColor.opacity(0.2), in: Capsule())
                    }
                }

                if theme.style == .braunField {
                    braunLedStrip(theme: theme)
                }

                Text(formatClock(engine.snapshot.elapsedSec))
                    .font(.system(size: min(38, width * (compact ? 0.16 : 0.18)), weight: .semibold, design: theme.timerDesign))
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary)

                if theme.style == .nocturne && !isLuminanceReduced {
                    nocturneSpectrumStrip(theme: theme)
                }

                Text(remainEstimateText)
                    .font(.system(size: 10.5, design: theme.metaDesign))
                    .foregroundStyle(theme.textSecondary)
                Text("轻敲两下机身打点")
                    .font(.system(size: 9.5))
                    .foregroundStyle(theme.textSecondary.opacity(0.75))
                    .padding(.top, compact ? 0 : 2)
            } else {
                Text(Date(), format: .dateTime.month().day().weekday(.abbreviated))
                    .font(.system(size: 11, weight: .semibold, design: theme.metaDesign))
                    .foregroundStyle(theme.accent)
                Text(Date(), format: .dateTime.hour().minute())
                    .font(.system(size: compact ? 36 : 42, weight: .medium, design: theme.timerDesign))
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary)
                if theme.style == .nocturne {
                    nocturneIdleBars(theme: theme)
                }
                Text("表盘组件亦可一键开录")
                    .font(.system(size: 9.5))
                    .foregroundStyle(theme.textSecondary.opacity(0.78))
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

    private func braunLedStrip(theme: WatchThemePalette) -> some View {
        let activeCount = (engine.snapshot.elapsedSec % 12) + 1
        return HStack(spacing: 2.5) {
            ForEach(0..<12, id: \.self) { idx in
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        idx < activeCount
                            ? (idx >= 10 ? theme.battColor : theme.recordingAccent)
                            : Color.white.opacity(0.14)
                    )
                    .frame(width: 7, height: 3)
            }
        }
        .padding(.vertical, 2)
    }

    private func nocturneSpectrumStrip(theme: WatchThemePalette) -> some View {
        let tick = engine.snapshot.elapsedSec
        return HStack(alignment: .center, spacing: 3) {
            ForEach(0..<11, id: \.self) { idx in
                let wave = abs((idx * 5 + tick * 3) % 9 - 4)
                let height = CGFloat(4 + wave * 2)
                let isPeak = idx == 5 && sessionMarkCount > 0
                Capsule()
                    .fill(isPeak ? theme.markColor : theme.battColor.opacity(0.82))
                    .frame(width: 2.5, height: height)
            }
        }
        .frame(height: 14)
        .padding(.vertical, 1)
    }

    private func nocturneIdleBars(theme: WatchThemePalette) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<11, id: \.self) { idx in
                Capsule()
                    .fill(idx == 5 ? theme.accent.opacity(0.6) : Color.white.opacity(0.16))
                    .frame(width: 2.5, height: idx == 5 ? 6 : 3)
            }
        }
        .padding(.vertical, 2)
    }

    private func bottomControls(
        theme: WatchThemePalette,
        height: CGFloat,
        queueHeight: CGFloat,
        bottomInset: CGFloat
    ) -> some View {
        let controlShape = RoundedRectangle(
            cornerRadius: theme.controlCornerRadius >= 18 ? height / 2 : theme.controlCornerRadius,
            style: .continuous
        )
        return VStack(spacing: 5) {
            Group {
                if engine.snapshot.isRecording {
                    if isLuminanceReduced {
                        Text("先点亮屏幕 · 再滑动停止")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.textPrimary.opacity(0.7))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .frame(height: height)
                            .background(theme.surface, in: controlShape)
                            .overlay(controlShape.stroke(theme.border, lineWidth: 1))
                    } else {
                        FlatSlideToStopControl(theme: theme, height: height) {
                            engine.toggleRecording()
                        }
                    }
                } else {
                    Button {
                        engine.toggleRecording()
                    } label: {
                        Text("开始录音")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.startFg)
                            .frame(maxWidth: .infinity)
                            .frame(height: height)
                            .background(theme.startBg, in: controlShape)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)

            NavigationLink {
                WatchQueueView(engine: engine)
            } label: {
                designSliceBar(theme: theme, queueHeight: queueHeight, bottomInset: bottomInset)
            }
            .buttonStyle(.plain)
        }
    }

    /// 设计稿 `.w-slice-bar`：全宽贴底，上圆角 14（声波仪 8），内容高 38，进度线高 2、左 14% 起、最长 72%。
    private func designSliceBar(
        theme: WatchThemePalette,
        queueHeight: CGFloat,
        bottomInset: CGFloat
    ) -> some View {
        let lap = engine.snapshot.isRecording ? (engine.snapshot.elapsedSec % 60) : 0
        let remaining = 60 - lap
        let progress = engine.snapshot.isRecording ? Double(lap) / 60.0 : 0.0
        let pending = engine.snapshot.pendingSliceCount
        let synced = engine.snapshot.syncedSliceCount
        let topRadius: CGFloat = theme.style == .braunField ? 8 : 14
        let footerShape = UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: topRadius,
            style: .continuous
        )
        let ring = engine.snapshot.isRecording ? theme.recordingAccent : theme.accent

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
                        .font(.system(size: 10, weight: .semibold, design: theme.metaDesign))
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary.opacity(0.88))
                }
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    Text(footerQueueSummary(pending: pending, synced: synced))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(
                            pending > 0
                                ? theme.markColor
                                : (synced > 0 ? theme.battColor : theme.textSecondary)
                        )
                    Text("›")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary.opacity(0.72))
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
                .fill(pending > 0 ? theme.markColor.opacity(0.16) : theme.surface)
        }
        .overlay(alignment: .bottom) {
            if engine.snapshot.isRecording && progress > 0 {
                GeometryReader { geo in
                    let lead = geo.size.width * 0.14
                    let span = geo.size.width * 0.72 * progress
                    Capsule()
                        .fill(theme.recordingAccent)
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

private struct WatchThemePalette {
    let style: WatchUIStyle
    let bg: Color
    let surface: Color
    let border: Color
    let accent: Color
    let recordingAccent: Color
    let markColor: Color
    let battColor: Color
    let startBg: Color
    let startFg: Color
    let textPrimary: Color
    let textSecondary: Color
    let timerDesign: Font.Design
    let metaDesign: Font.Design
    let controlCornerRadius: CGFloat
    let knobCornerRadius: CGFloat

    init(style: WatchUIStyle) {
        self.style = style
        switch style {
        case .warmPaper:
            bg = Color(red: 0.035, green: 0.035, blue: 0.031) // #090908
            surface = Color.white.opacity(0.09)
            border = Color.white.opacity(0.20)
            accent = Color(red: 0.949, green: 0.635, blue: 0.235) // #F2A23C
            recordingAccent = Color(red: 0.851, green: 0.255, blue: 0.141) // #D94124
            markColor = Color.orange
            battColor = Color(red: 0.204, green: 0.780, blue: 0.349)
            startBg = Color(red: 0.188, green: 0.820, blue: 0.345)
            startFg = .white
            textPrimary = .white
            textSecondary = Color.white.opacity(0.62)
            timerDesign = .monospaced
            metaDesign = .default
            controlCornerRadius = 999
            knobCornerRadius = 999

        case .braunField:
            bg = Color(red: 0.051, green: 0.055, blue: 0.051) // #0D0E0D
            surface = Color.white.opacity(0.08)
            border = Color.white.opacity(0.22)
            accent = Color(red: 1.0, green: 0.333, blue: 0.078) // #FF5514
            recordingAccent = Color(red: 1.0, green: 0.333, blue: 0.078)
            markColor = Color(red: 1.0, green: 0.545, blue: 0.239)
            battColor = Color(red: 0.639, green: 0.722, blue: 0.424) // #A3B86C
            startBg = Color(red: 1.0, green: 0.333, blue: 0.078)
            startFg = .white
            textPrimary = Color(red: 0.96, green: 0.95, blue: 0.93)
            textSecondary = Color(red: 0.69, green: 0.68, blue: 0.65)
            timerDesign = .monospaced
            metaDesign = .monospaced
            controlCornerRadius = 8
            knobCornerRadius = 6

        case .chronos:
            bg = Color(red: 0.020, green: 0.031, blue: 0.067) // #050811
            surface = Color(red: 0.12, green: 0.22, blue: 0.45).opacity(0.22)
            border = Color(red: 0.376, green: 0.647, blue: 0.980).opacity(0.32)
            accent = Color(red: 0.376, green: 0.647, blue: 0.980) // #60A5FA
            recordingAccent = Color(red: 0.937, green: 0.267, blue: 0.267) // #EF4444
            markColor = Color(red: 0.376, green: 0.647, blue: 0.980)
            battColor = Color(red: 0.376, green: 0.647, blue: 0.980)
            startBg = Color(red: 0.145, green: 0.388, blue: 0.922) // #2563EB
            startFg = .white
            textPrimary = Color(red: 0.96, green: 0.98, blue: 1.0)
            textSecondary = Color(red: 0.68, green: 0.76, blue: 0.88)
            timerDesign = .default
            metaDesign = .default
            controlCornerRadius = 999
            knobCornerRadius = 999

        case .folio:
            bg = Color(red: 0.051, green: 0.043, blue: 0.035) // #0D0B09
            surface = Color(red: 0.85, green: 0.78, blue: 0.68).opacity(0.09)
            border = Color(red: 0.851, green: 0.780, blue: 0.682).opacity(0.26)
            accent = Color(red: 0.851, green: 0.396, blue: 0.322) // #D96552
            recordingAccent = Color(red: 0.784, green: 0.243, blue: 0.169) // #C83E2B
            markColor = Color(red: 0.91, green: 0.63, blue: 0.38)
            battColor = Color(red: 0.851, green: 0.780, blue: 0.682) // #D9C7AE
            startBg = Color(red: 0.176, green: 0.776, blue: 0.325)
            startFg = .white
            textPrimary = Color(red: 0.961, green: 0.937, blue: 0.894) // #F5EFE4
            textSecondary = Color(red: 0.76, green: 0.71, blue: 0.63)
            timerDesign = .serif
            metaDesign = .serif
            controlCornerRadius = 10
            knobCornerRadius = 7

        case .nocturne:
            bg = .black // #000000
            surface = Color.white.opacity(0.08)
            border = Color(red: 0.961, green: 0.651, blue: 0.137).opacity(0.28)
            accent = Color(red: 0.961, green: 0.651, blue: 0.137) // #F5A623
            recordingAccent = Color(red: 1.0, green: 0.271, blue: 0.227) // #FF453A
            markColor = Color(red: 0.961, green: 0.651, blue: 0.137)
            battColor = Color(red: 0.188, green: 0.820, blue: 0.345) // #30D158
            startBg = Color(red: 0.176, green: 0.776, blue: 0.325) // #2DC653
            startFg = .black
            textPrimary = Color(red: 0.95, green: 0.96, blue: 0.98)
            textSecondary = Color(red: 0.58, green: 0.61, blue: 0.68)
            timerDesign = .monospaced
            metaDesign = .monospaced
            controlCornerRadius = 999
            knobCornerRadius = 999

        case .air:
            bg = Color(red: 0.024, green: 0.039, blue: 0.035) // #060A09
            surface = Color(red: 0.424, green: 0.831, blue: 0.725).opacity(0.11)
            border = Color(red: 0.424, green: 0.831, blue: 0.725).opacity(0.28)
            accent = Color(red: 0.424, green: 0.831, blue: 0.725) // #6CD4B9
            recordingAccent = Color(red: 0.910, green: 0.361, blue: 0.259) // #E85C42
            markColor = Color(red: 0.424, green: 0.831, blue: 0.725)
            battColor = Color(red: 0.424, green: 0.831, blue: 0.725)
            startBg = Color(red: 0.106, green: 0.478, blue: 0.420) // #1B7A6B
            startFg = .white
            textPrimary = Color(red: 0.95, green: 0.98, blue: 0.97)
            textSecondary = Color(red: 0.66, green: 0.78, blue: 0.75)
            timerDesign = .rounded
            metaDesign = .rounded
            controlCornerRadius = 999
            knobCornerRadius = 999
        }
    }
}

private struct FlatSlideToStopControl: View {
    let theme: WatchThemePalette
    let height: CGFloat
    let onStop: () -> Void
    @State private var dragX: CGFloat = 0

    var body: some View {
        let trackShape = RoundedRectangle(
            cornerRadius: theme.controlCornerRadius >= 18 ? height / 2 : theme.controlCornerRadius,
            style: .continuous
        )

        GeometryReader { geo in
            let padding: CGFloat = 4
            let knobSize = height - padding * 2
            let knobRadius = theme.knobCornerRadius >= 18 ? knobSize / 2 : theme.knobCornerRadius
            let knobShape = RoundedRectangle(cornerRadius: knobRadius, style: .continuous)
            let maxDrag = max(1, geo.size.width - knobSize - padding * 2)

            ZStack(alignment: .leading) {
                trackShape
                    .fill(theme.recordingAccent.opacity(0.16))
                    .overlay(trackShape.stroke(theme.recordingAccent.opacity(0.38), lineWidth: 1))

                Text("滑动停止录音")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.recordingAccent.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, knobSize + padding * 2)
                    .padding(.trailing, 8)

                knobShape
                    .fill(theme.recordingAccent)
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
        let theme = WatchThemePalette(style: engine.uiStyle)
        List {
            Text("手表版本 \(watchAppVersionLabel)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
            if engine.snapshot.pendingSliceCount > 0 {
                Button("立即同步到手机") {
                    engine.flushPendingTransfers()
                }
                .tint(theme.battColor)
            }

            Section("本地队列") {
                if engine.slices.isEmpty {
                    Text("暂无本地录音片段")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
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
            }

            Section("表盘风格") {
                ForEach(WatchUIStyle.allCases) { style in
                    let p = WatchThemePalette(style: style)
                    let active = engine.uiStyle == style
                    Button {
                        engine.setLocalStyle(style)
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(p.accent)
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(style.displayName)
                                    .font(.caption.weight(.semibold))
                                Text(style.englishName)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if active {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(p.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("本地队列")
        .toolbar(.visible, for: .navigationBar)
        .containerBackground(theme.bg, for: .navigation)
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
