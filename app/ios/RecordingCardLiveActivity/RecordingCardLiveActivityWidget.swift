import ActivityKit
import SwiftUI
import WidgetKit

@available(iOSApplicationExtension 16.1, *)
struct RecordingCardLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: RecordingCardActivityAttributes.self) { context in
      HStack(spacing: 12) {
        AppLogoMark(size: 40)
        VStack(alignment: .leading, spacing: 2) {
          Text(context.state.title)
            .font(.headline)
            .foregroundStyle(.primary)
          Text(context.state.subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if context.state.isRecording {
          Text(
            timerInterval: Date(
              timeIntervalSince1970: Double(context.state.startedAtMs) / 1000.0
            )...Date.distantFuture,
            countsDown: false
          )
          .font(.callout.monospacedDigit().weight(.semibold))
          .foregroundStyle(Color(red: 0, green: 195 / 255, blue: 48 / 255))
          .frame(minWidth: 48, alignment: .trailing)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .activityBackgroundTint(Color(.systemBackground))
      .activitySystemActionForegroundColor(
        Color(red: 0, green: 195 / 255, blue: 48 / 255)
      )
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          AppLogoMark(size: 36)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(alignment: .leading, spacing: 2) {
            Text(context.state.title)
              .font(.headline)
            Text(context.state.subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          if context.state.isRecording {
            Text(
              timerInterval: Date(
                timeIntervalSince1970: Double(context.state.startedAtMs) / 1000.0
              )...Date.distantFuture,
              countsDown: false
            )
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .foregroundStyle(Color(red: 0, green: 195 / 255, blue: 48 / 255))
          }
        }
      } compactLeading: {
        AppLogoMark(size: 22)
      } compactTrailing: {
        if context.state.isRecording {
          Text(
            timerInterval: Date(
              timeIntervalSince1970: Double(context.state.startedAtMs) / 1000.0
            )...Date.distantFuture,
            countsDown: false
          )
          .font(.caption2.monospacedDigit())
          .foregroundStyle(Color(red: 0, green: 195 / 255, blue: 48 / 255))
          .frame(width: 42, alignment: .trailing)
          .contentTransition(.identity)
          .transaction { $0.animation = nil }
        } else {
          Text("OFF")
            .font(.caption2)
        }
      } minimal: {
        AppLogoMark(size: 20)
      }
    }
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
