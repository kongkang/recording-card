import SwiftUI
import WatchRecorderCore
import WidgetKit

struct RecordingCardComplicationEntry: TimelineEntry {
    let date: Date
    let state: ComplicationDisplayState
}

struct RecordingCardComplicationProvider: TimelineProvider {
    private let store = ComplicationStateStore()

    func placeholder(in context: Context) -> RecordingCardComplicationEntry {
        RecordingCardComplicationEntry(
            date: Date(),
            state: ComplicationDisplayState(isRecording: false, pendingCount: 0)
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (RecordingCardComplicationEntry) -> Void) {
        let state = store.load()
        completion(RecordingCardComplicationEntry(date: Date(), state: state))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecordingCardComplicationEntry>) -> Void) {
        let state = store.load()
        let entry = RecordingCardComplicationEntry(date: Date(), state: state)
        let refreshDate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(refreshDate)))
    }
}

struct RecordingCardComplicationEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RecordingCardComplicationEntry

    var body: some View {
        contentView
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(URL(string: WatchConstants.toggleUrlScheme))
    }

    @ViewBuilder
    private var contentView: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: entry.state.isRecording ? "record.circle.fill" : "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(entry.state.isRecording ? .red : .primary)
                    Text(entry.state.isRecording ? "录音" : (entry.state.pendingCount > 0 ? "\(entry.state.pendingCount)待" : "待机"))
                        .font(.system(size: 9, weight: .medium))
                }
            }
        case .accessoryCorner:
            Image(systemName: entry.state.isRecording ? "record.circle.fill" : "mic.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(entry.state.isRecording ? .red : .primary)
                .widgetLabel {
                    if entry.state.isRecording, let started = entry.state.startedAtDate {
                        Text(started, style: .timer)
                    } else if entry.state.pendingCount > 0 {
                        Text("待传\(entry.state.pendingCount)")
                    } else {
                        Text("录音卡")
                    }
                }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: entry.state.isRecording ? "record.circle.fill" : "mic.fill")
                        .foregroundStyle(entry.state.isRecording ? .red : .primary)
                    Text("录音卡")
                        .font(.headline)
                }
                if entry.state.isRecording, let started = entry.state.startedAtDate {
                    HStack(spacing: 4) {
                        Text("录音中")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Text(started, style: .timer)
                            .font(.caption.monospacedDigit())
                    }
                } else if entry.state.pendingCount > 0 {
                    Text("轻点开录 · 待传 \(entry.state.pendingCount) 段")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("轻点开始持续录音")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            if entry.state.isRecording {
                Label("录音卡 · 录音中", systemImage: "record.circle.fill")
            } else {
                Label("录音卡 · 点击开录", systemImage: "mic.fill")
            }
        @unknown default:
            Image(systemName: "mic.fill")
        }
    }
}

struct RecordingCardComplication: Widget {
    let kind: String = "RecordingCardComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecordingCardComplicationProvider()) { entry in
            RecordingCardComplicationEntryView(entry: entry)
        }
        .configurationDisplayName("录音卡")
        .description("放上表盘，轻点一键开启或停止手表持续录音。")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

@main
struct RecordingCardWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RecordingCardComplication()
    }
}
