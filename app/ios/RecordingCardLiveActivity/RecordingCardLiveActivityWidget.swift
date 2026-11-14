import ActivityKit
import SwiftUI
import WidgetKit

private let lcdFontName = "RCLcdDigital-Regular"
private let posixLocale = Locale(identifier: "en_US_POSIX")
private let islandLcdInk = Color(red: 0.93, green: 0.94, blue: 0.92)

@available(iOSApplicationExtension 16.1, *)
struct RecordingCardLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: RecordingCardActivityAttributes.self) { context in
      // 锁屏与通知横幅：左侧图标+标题，右侧等宽 7 段液晶 6 位时间（HH:MM:SS）严格右对齐，柔和中性色
      HStack(spacing: 12) {
        AppLogoMark(size: 38)
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
        Spacer(minLength: 8)
        if context.state.isRecording {
          LockScreenLcdTimer(startedAtMs: context.state.startedAtMs)
        } else {
          LcdStaticReadout(
            text: "OFF",
            ghost: "888",
            fontSize: 16,
            ink: .secondary,
            ghostOpacity: 0.08
          )
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .activityBackgroundTint(Color(.secondarySystemBackground))
      .activitySystemActionForegroundColor(.primary)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          AppLogoMark(size: 30)
            .padding(.leading, 4)
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
            }
          }
          .frame(maxWidth: .infinity, alignment: .trailing)
          .padding(.trailing, 4)
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
          .padding(.horizontal, 6)
          .padding(.top, 2)
        }
      } compactLeading: {
        AppLogoMark(size: 20)
          .padding(.leading, 2)
      } compactTrailing: {
        // 紧凑态灵动岛右侧空间受状态栏图标限制只能容纳 4 位数字：
        // - < 60 分钟显示 MM:SS（两位分 + 两位秒）；
        // - ≥ 60 分钟切换为 HH:MM（两位时 + 两位分），中间冒号每秒闪动代表秒数跳动；
        // - 固定等宽容器 + 右对齐，与左侧图标对称且绝不抖动。
        if context.state.isRecording {
          CompactLcdTimer(
            startedAtMs: context.state.startedAtMs,
            isOverOneHour: context.state.isOverOneHour,
            colonVisible: context.state.colonVisible
          )
          .padding(.trailing, 2)
        } else {
          Text("OFF")
            .font(.custom(lcdFontName, fixedSize: 12.5))
            .foregroundStyle(Color.white.opacity(0.62))
            .frame(width: 36, alignment: .trailing)
            .padding(.trailing, 2)
        }
      } minimal: {
        AppLogoMark(size: 20)
      }
    }
  }
}

/// 紧凑态灵动岛 4 位 7 段液晶计时器（固定宽度右对齐，防抖动）。
@available(iOSApplicationExtension 16.1, *)
private struct CompactLcdTimer: View {
  let startedAtMs: Int64
  let isOverOneHour: Bool
  let colonVisible: Bool

  private var startDate: Date {
    Date(timeIntervalSince1970: Double(startedAtMs) / 1000.0)
  }

  var body: some View {
    HStack(spacing: 0) {
      Spacer(minLength: 0)
      ZStack(alignment: .trailing) {
        Text("88:88")
          .font(.custom(lcdFontName, fixedSize: 13.5))
          .foregroundStyle(Color.white.opacity(0.12))
          .multilineTextAlignment(.trailing)

        if #available(iOSApplicationExtension 18.0, *) {
          if isOverOneHour {
            Text(
              TimeDataSource<Duration>.durationOffset(to: startDate),
              format: .time(pattern: .hourMinute(padHourToLength: 2, roundSeconds: .down))
                .locale(posixLocale)
            )
            .font(.custom(lcdFontName, fixedSize: 13.5))
            .foregroundStyle(islandLcdInk)
            .multilineTextAlignment(.trailing)

            if !colonVisible {
              // 遮暗 HH:MM 正中央冒号至底纹亮度（2 位分钟宽 2 * 0.58 * 13.5 = 15.66pt）
              Rectangle()
                .fill(Color.black.opacity(0.86))
                .frame(width: 3.4, height: 14)
                .padding(.trailing, 15.66)
            }
          } else {
            Text(
              TimeDataSource<Duration>.durationOffset(to: startDate),
              format: .time(pattern: .minuteSecond(padMinuteToLength: 2))
                .locale(posixLocale)
            )
            .font(.custom(lcdFontName, fixedSize: 13.5))
            .foregroundStyle(islandLcdInk)
            .multilineTextAlignment(.trailing)
          }
        } else {
          Text(
            timerInterval: startDate...Date.distantFuture,
            countsDown: false,
            showsHours: isOverOneHour
          )
          .font(.custom(lcdFontName, fixedSize: 13.5))
          .foregroundStyle(islandLcdInk)
          .multilineTextAlignment(.trailing)
        }
      }
      .fixedSize(horizontal: true, vertical: false)
    }
    .frame(width: 36, alignment: .trailing)
    .contentTransition(.identity)
    .transaction { $0.animation = nil }
  }
}

/// 灵动岛长按展开态 6 位 7 段液晶计时器（`HH:MM:SS`，严格右对齐）。
@available(iOSApplicationExtension 16.1, *)
private struct ExpandedLcdTimer: View {
  let startedAtMs: Int64

  private var startDate: Date {
    Date(timeIntervalSince1970: Double(startedAtMs) / 1000.0)
  }

  var body: some View {
    ZStack(alignment: .trailing) {
      Text("88:88:88")
        .font(.custom(lcdFontName, fixedSize: 15.5))
        .foregroundStyle(Color.white.opacity(0.12))
        .multilineTextAlignment(.trailing)

      if #available(iOSApplicationExtension 18.0, *) {
        Text(
          TimeDataSource<Duration>.durationOffset(to: startDate),
          format: .time(pattern: .hourMinuteSecond(padHourToLength: 2))
            .locale(posixLocale)
        )
        .font(.custom(lcdFontName, fixedSize: 15.5))
        .foregroundStyle(islandLcdInk)
        .multilineTextAlignment(.trailing)
      } else {
        Text(timerInterval: startDate...Date.distantFuture, countsDown: false)
          .font(.custom(lcdFontName, fixedSize: 15.5))
          .foregroundStyle(islandLcdInk)
          .multilineTextAlignment(.trailing)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
    .contentTransition(.identity)
    .transaction { $0.animation = nil }
  }
}

/// 锁屏实况卡片右侧 6 位 7 段液晶计时窗口（`HH:MM:SS`，带微弱 88:88:88 液晶底纹与浅边框）。
@available(iOSApplicationExtension 16.1, *)
private struct LockScreenLcdTimer: View {
  let startedAtMs: Int64

  private var startDate: Date {
    Date(timeIntervalSince1970: Double(startedAtMs) / 1000.0)
  }

  var body: some View {
    ZStack(alignment: .trailing) {
      Text("88:88:88")
        .font(.custom(lcdFontName, fixedSize: 17))
        .foregroundStyle(Color.primary.opacity(0.08))
        .multilineTextAlignment(.trailing)

      if #available(iOSApplicationExtension 18.0, *) {
        Text(
          TimeDataSource<Duration>.durationOffset(to: startDate),
          format: .time(pattern: .hourMinuteSecond(padHourToLength: 2))
            .locale(posixLocale)
        )
        .font(.custom(lcdFontName, fixedSize: 17))
        .foregroundStyle(Color.primary.opacity(0.88))
        .multilineTextAlignment(.trailing)
      } else {
        Text(timerInterval: startDate...Date.distantFuture, countsDown: false)
          .font(.custom(lcdFontName, fixedSize: 17))
          .foregroundStyle(Color.primary.opacity(0.88))
          .multilineTextAlignment(.trailing)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.primary.opacity(0.045))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
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
  let ink: Color
  let ghostOpacity: Double

  var body: some View {
    ZStack(alignment: .trailing) {
      Text(ghost)
        .font(.custom(lcdFontName, fixedSize: fontSize))
        .foregroundStyle(Color.primary.opacity(ghostOpacity))
      Text(text)
        .font(.custom(lcdFontName, fixedSize: fontSize))
        .foregroundStyle(ink)
    }
    .fixedSize(horizontal: true, vertical: false)
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.primary.opacity(0.045))
    )
  }
}

/// 严格使用录音卡 App Logo 作为实况与灵动岛图标（不使用麦克风/波形等录音图标）。
private struct AppLogoMark: View {
  let size: CGFloat

  var body: some View {
    Image("AppLogo")
      .resizable()
      .interpolation(.high)
      .scaledToFill()
      .frame(width: size, height: size)
      .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
  }
}
