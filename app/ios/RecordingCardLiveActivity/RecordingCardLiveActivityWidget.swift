import ActivityKit
import SwiftUI
import WidgetKit

private let lcdFontName = "RCLcdDigital-Regular"
private let lcdBlinkFontName = "RCLcdBlink-Regular"
private let posixLocale = Locale(identifier: "en_US_POSIX")
private let islandLcdInk = Color(red: 0.93, green: 0.94, blue: 0.92)

@available(iOSApplicationExtension 16.1, *)
struct RecordingCardLiveActivityWidget: Widget {
  init() {
    RCLcdFontRegistrar.registerIfNeeded()
  }

  var body: some WidgetConfiguration {
    ActivityConfiguration(for: RecordingCardActivityAttributes.self) { context in
      // 锁屏与通知横幅：采用与 iOS 圆角卡片同心的 20pt 左右内边距，
      // 左侧固定 36pt 图标，右侧固定 88pt 7 段液晶 6 位时间窗口（HH:MM:SS）严格右对齐。
      HStack(alignment: .center, spacing: 12) {
        AppLogoMark(size: 36, cornerRadius: 10.5, showsBorder: true)

        VStack(alignment: .leading, spacing: 2) {
          Text(context.state.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
          Text(context.state.subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if context.state.isRecording {
          LockScreenLcdTimer(startedAtMs: context.state.startedAtMs)
        } else {
          LcdStaticReadout(
            text: "OFF",
            ghost: "888",
            fontSize: 16,
            boxWidth: 36,
            boxHeight: 20,
            ink: .secondary,
            ghostOpacity: 0.08
          )
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 14)
      .activityBackgroundTint(Color(.secondarySystemBackground))
      .activitySystemActionForegroundColor(.primary)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          AppLogoMark(size: 30, cornerRadius: 8, showsBorder: false)
            .padding(.leading, 2)
        }
        DynamicIslandExpandedRegion(.trailing) {
          HStack(spacing: 0) {
            Spacer(minLength: 0)
            if context.state.isRecording {
              ExpandedLcdTimer(startedAtMs: context.state.startedAtMs)
            } else {
              Text("OFF")
                .font(.custom(lcdFontName, fixedSize: 15))
                .foregroundStyle(Color.white.opacity(0.6))
                .multilineTextAlignment(.trailing)
                .frame(width: 36, height: 20, alignment: .trailing)
            }
          }
          .padding(.trailing, 2)
        }
        DynamicIslandExpandedRegion(.bottom) {
          HStack(spacing: 8) {
            Circle()
              .fill(
                context.state.isRecording
                  ? Color(red: 0.92, green: 0.30, blue: 0.24)
                  : Color.white.opacity(0.35)
              )
              .frame(width: 6, height: 6)
            Text("\(context.state.title) · \(context.state.subtitle)")
              .font(.caption)
              .foregroundStyle(Color.white.opacity(0.78))
              .lineLimit(1)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 4)
          .padding(.top, 2)
        }
      } compactLeading: {
        AppLogoMark(size: 20, cornerRadius: 5.5, showsBorder: false)
      } compactTrailing: {
        // 紧凑态灵动岛右侧空间受状态栏图标限制容纳 4 位数字：
        // - < 60 分钟显示 MM:SS（两位分 + 两位秒）；
        // - ≥ 60 分钟切换为 HH:MM（两位时 + 两位分），中间冒号每秒闪动代表秒数跳动；
        // - 注意：WidgetKit 中 TimeDataSource Text 默认水平无限撑开，严禁使用 fixedSize，
        //   必须直接施加有限定宽 frame(width:height:alignment: .trailing) + multilineTextAlignment(.trailing)。
        if context.state.isRecording {
          CompactLcdTimer(
            startedAtMs: context.state.startedAtMs,
            isOverOneHour: context.state.isOverOneHour,
            colonVisible: context.state.colonVisible
          )
        } else {
          Text("OFF")
            .font(.custom(lcdFontName, fixedSize: 12.5))
            .foregroundStyle(Color.white.opacity(0.62))
            .lineLimit(1)
            .multilineTextAlignment(.trailing)
            .frame(width: 36, height: 18, alignment: .trailing)
        }
      } minimal: {
        AppLogoMark(size: 20, cornerRadius: 5.5, showsBorder: false)
      }
    }
  }
}

/// 紧凑态灵动岛 4 位 7 段液晶计时器（严格定宽 36×18 右对齐，绝不无限撑开或抖动）。
@available(iOSApplicationExtension 16.1, *)
private struct CompactLcdTimer: View {
  let startedAtMs: Int64
  let isOverOneHour: Bool
  let colonVisible: Bool

  private static let boxWidth: CGFloat = 36
  private static let boxHeight: CGFloat = 18
  private static let fontSize: CGFloat = 13.5

  private var startDate: Date {
    Date(timeIntervalSince1970: Double(startedAtMs) / 1000.0)
  }

  private var effectiveOverOneHour: Bool {
    isOverOneHour || Date().timeIntervalSince(startDate) >= 3600
  }

  var body: some View {
    ZStack(alignment: .trailing) {
      Text("88:88")
        .font(.custom(lcdFontName, fixedSize: Self.fontSize))
        .foregroundStyle(Color.white.opacity(0.13))
        .lineLimit(1)
        .multilineTextAlignment(.trailing)
        .frame(width: Self.boxWidth, height: Self.boxHeight, alignment: .trailing)

      if #available(iOSApplicationExtension 18.0, *) {
        if effectiveOverOneHour {
          // ≥1 小时模式：紧凑灵动岛显示「HH:MM」；由于 SpringBoard / chronod 会把仅含时分的
          // TimeDataSource 节流成每分钟刷新 1 次，此处用 destinationOut 镂空静态冒号至底纹层，
          // 再叠加一个由系统秒级时间源原生驱动的 1Hz 伴生闪烁字体层，无需 App 进程每秒唤醒更新。
          ZStack(alignment: .trailing) {
            Text(
              TimeDataSource<Duration>.durationOffset(to: startDate),
              format: .time(pattern: .hourMinute(padHourToLength: 2, roundSeconds: .down))
                .locale(posixLocale)
            )
            .font(.custom(lcdFontName, fixedSize: Self.fontSize))
            .foregroundStyle(islandLcdInk)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .multilineTextAlignment(.trailing)
            .frame(width: Self.boxWidth, height: Self.boxHeight, alignment: .trailing)

            Rectangle()
              .fill(Color.black)
              .frame(width: 3.45, height: Self.boxHeight)
              .padding(.trailing, 15.62)
              .blendMode(.destinationOut)
          }
          .compositingGroup()

          Text(
            TimeDataSource<Duration>.durationOffset(to: startDate),
            format: .time(pattern: .hourMinuteSecond(padHourToLength: 2))
              .locale(posixLocale)
          )
          .font(.custom(lcdBlinkFontName, fixedSize: Self.fontSize))
          .foregroundStyle(islandLcdInk)
          .lineLimit(1)
          .multilineTextAlignment(.trailing)
          .frame(width: Self.boxWidth, height: Self.boxHeight, alignment: .trailing)
          .frame(width: 3.375, height: Self.boxHeight, alignment: .trailing)
          .clipped()
          .padding(.trailing, 15.66)
        } else {
          Text(
            TimeDataSource<Duration>.durationOffset(to: startDate),
            format: .time(pattern: .minuteSecond(padMinuteToLength: 2))
              .locale(posixLocale)
          )
          .font(.custom(lcdFontName, fixedSize: Self.fontSize))
          .foregroundStyle(islandLcdInk)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .multilineTextAlignment(.trailing)
          .frame(width: Self.boxWidth, height: Self.boxHeight, alignment: .trailing)
        }
      } else {
        Text(
          timerInterval: startDate...Date.distantFuture,
          countsDown: false,
          showsHours: effectiveOverOneHour
        )
        .font(.custom(lcdFontName, fixedSize: Self.fontSize))
        .foregroundStyle(islandLcdInk)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .multilineTextAlignment(.trailing)
        .frame(width: Self.boxWidth, height: Self.boxHeight, alignment: .trailing)
      }
    }
    .frame(width: Self.boxWidth, height: Self.boxHeight, alignment: .trailing)
    .contentTransition(.identity)
    .transaction { $0.animation = nil }
  }
}

/// 灵动岛长按展开态 6 位 7 段液晶计时器（`HH:MM:SS`，严格定宽 64×20 右对齐）。
@available(iOSApplicationExtension 16.1, *)
private struct ExpandedLcdTimer: View {
  let startedAtMs: Int64

  private static let boxWidth: CGFloat = 64
  private static let boxHeight: CGFloat = 20
  private static let fontSize: CGFloat = 15.5

  private var startDate: Date {
    Date(timeIntervalSince1970: Double(startedAtMs) / 1000.0)
  }

  var body: some View {
    ZStack(alignment: .trailing) {
      Text("88:88:88")
        .font(.custom(lcdFontName, fixedSize: Self.fontSize))
        .foregroundStyle(Color.white.opacity(0.13))
        .lineLimit(1)
        .multilineTextAlignment(.trailing)
        .frame(width: Self.boxWidth, height: Self.boxHeight, alignment: .trailing)

      if #available(iOSApplicationExtension 18.0, *) {
        Text(
          TimeDataSource<Duration>.durationOffset(to: startDate),
          format: .time(pattern: .hourMinuteSecond(padHourToLength: 2))
            .locale(posixLocale)
        )
        .font(.custom(lcdFontName, fixedSize: Self.fontSize))
        .foregroundStyle(islandLcdInk)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .multilineTextAlignment(.trailing)
        .frame(width: Self.boxWidth, height: Self.boxHeight, alignment: .trailing)
      } else {
        Text(timerInterval: startDate...Date.distantFuture, countsDown: false)
          .font(.custom(lcdFontName, fixedSize: Self.fontSize))
          .foregroundStyle(islandLcdInk)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .multilineTextAlignment(.trailing)
          .frame(width: Self.boxWidth, height: Self.boxHeight, alignment: .trailing)
      }
    }
    .frame(width: Self.boxWidth, height: Self.boxHeight, alignment: .trailing)
    .contentTransition(.identity)
    .transaction { $0.animation = nil }
  }
}

/// 锁屏实况卡片右侧 6 位 7 段液晶计时窗口（`HH:MM:SS`，严格定宽 70×22 + 视窗内边距 = 88×34）。
@available(iOSApplicationExtension 16.1, *)
private struct LockScreenLcdTimer: View {
  let startedAtMs: Int64

  private static let boxWidth: CGFloat = 70
  private static let boxHeight: CGFloat = 22
  private static let fontSize: CGFloat = 17

  private var startDate: Date {
    Date(timeIntervalSince1970: Double(startedAtMs) / 1000.0)
  }

  var body: some View {
    ZStack(alignment: .trailing) {
      Text("88:88:88")
        .font(.custom(lcdFontName, fixedSize: Self.fontSize))
        .foregroundStyle(Color.primary.opacity(0.09))
        .lineLimit(1)
        .multilineTextAlignment(.trailing)
        .frame(width: Self.boxWidth, height: Self.boxHeight, alignment: .trailing)

      if #available(iOSApplicationExtension 18.0, *) {
        Text(
          TimeDataSource<Duration>.durationOffset(to: startDate),
          format: .time(pattern: .hourMinuteSecond(padHourToLength: 2))
            .locale(posixLocale)
        )
        .font(.custom(lcdFontName, fixedSize: Self.fontSize))
        .foregroundStyle(Color.primary.opacity(0.88))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .multilineTextAlignment(.trailing)
        .frame(width: Self.boxWidth, height: Self.boxHeight, alignment: .trailing)
      } else {
        Text(timerInterval: startDate...Date.distantFuture, countsDown: false)
          .font(.custom(lcdFontName, fixedSize: Self.fontSize))
          .foregroundStyle(Color.primary.opacity(0.88))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .multilineTextAlignment(.trailing)
          .frame(width: Self.boxWidth, height: Self.boxHeight, alignment: .trailing)
      }
    }
    .frame(width: Self.boxWidth, height: Self.boxHeight, alignment: .trailing)
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(Color.primary.opacity(0.05))
        .overlay(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
    )
    .contentTransition(.identity)
    .transaction { $0.animation = nil }
  }
}

@available(iOSApplicationExtension 16.1, *)
private struct LcdStaticReadout: View {
  let text: String
  let ghost: String
  let fontSize: CGFloat
  let boxWidth: CGFloat
  let boxHeight: CGFloat
  let ink: Color
  let ghostOpacity: Double

  var body: some View {
    ZStack(alignment: .trailing) {
      Text(ghost)
        .font(.custom(lcdFontName, fixedSize: fontSize))
        .foregroundStyle(Color.primary.opacity(ghostOpacity))
        .lineLimit(1)
        .multilineTextAlignment(.trailing)
        .frame(width: boxWidth, height: boxHeight, alignment: .trailing)
      Text(text)
        .font(.custom(lcdFontName, fixedSize: fontSize))
        .foregroundStyle(ink)
        .lineLimit(1)
        .multilineTextAlignment(.trailing)
        .frame(width: boxWidth, height: boxHeight, alignment: .trailing)
    }
    .frame(width: boxWidth, height: boxHeight, alignment: .trailing)
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(Color.primary.opacity(0.05))
    )
  }
}

/// 严格使用录音卡 App Logo 作为实况与灵动岛图标（不使用麦克风/波形等录音图标）。
private struct AppLogoMark: View {
  let size: CGFloat
  let cornerRadius: CGFloat
  let showsBorder: Bool

  var body: some View {
    Image("AppLogo")
      .resizable()
      .interpolation(.high)
      .scaledToFill()
      .frame(width: size, height: size)
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay {
        if showsBorder {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
      }
  }
}
