import SwiftUI
#if canImport(WatchRecorderCore)
import WatchRecorderCore
#endif
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
            state: ComplicationDisplayState(
                isRecording: false,
                pendingCount: 0,
                uiStyleId: store.loadStyle().rawValue
            )
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

private struct ComplicationStylePalette {
    let accent: Color
    let recording: Color
    let pending: Color
    let design: Font.Design

    init(style: WatchUIStyle) {
        switch style {
        case .warmPaper:
            accent = Color(red: 0.949, green: 0.635, blue: 0.235)
            recording = Color(red: 0.851, green: 0.255, blue: 0.141)
            pending = .orange
            design = .default
        case .braunField:
            accent = Color(red: 1.0, green: 0.333, blue: 0.078)
            recording = Color(red: 1.0, green: 0.333, blue: 0.078)
            pending = Color(red: 0.639, green: 0.722, blue: 0.424)
            design = .monospaced
        case .chronos:
            accent = Color(red: 0.376, green: 0.647, blue: 0.980)
            recording = Color(red: 0.937, green: 0.267, blue: 0.267)
            pending = Color(red: 0.376, green: 0.647, blue: 0.980)
            design = .default
        case .folio:
            accent = Color(red: 0.851, green: 0.396, blue: 0.322)
            recording = Color(red: 0.784, green: 0.243, blue: 0.169)
            pending = Color(red: 0.851, green: 0.780, blue: 0.682)
            design = .serif
        case .nocturne:
            accent = Color(red: 0.961, green: 0.651, blue: 0.137)
            recording = Color(red: 1.0, green: 0.271, blue: 0.227)
            pending = Color(red: 0.188, green: 0.820, blue: 0.345)
            design = .monospaced
        case .air:
            accent = Color(red: 0.424, green: 0.831, blue: 0.725)
            recording = Color(red: 0.910, green: 0.361, blue: 0.259)
            pending = Color(red: 0.424, green: 0.831, blue: 0.725)
            design = .rounded
        }
    }
}

struct RecordingCardComplicationEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RecordingCardComplicationEntry

    var body: some View {
        let palette = ComplicationStylePalette(style: entry.state.uiStyle)
        contentView(palette: palette)
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(URL(string: WatchConstants.toggleUrlScheme))
    }

    @ViewBuilder
    private func contentView(palette: ComplicationStylePalette) -> some View {
        let activeColor = entry.state.isRecording
            ? palette.recording
            : (entry.state.pendingCount > 0 ? palette.pending : palette.accent)

        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Circle()
                    .stroke(activeColor.opacity(entry.state.isRecording ? 0.85 : 0.4), lineWidth: 1.5)
                    .padding(1)
                VStack(spacing: 1) {
                    Image(systemName: entry.state.isRecording ? "record.circle.fill" : "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(entry.state.isRecording ? palette.recording : palette.accent)
                    Text(entry.state.isRecording ? "录音" : (entry.state.pendingCount > 0 ? "\(entry.state.pendingCount)待" : "待机"))
                        .font(.system(size: 9, weight: .medium, design: palette.design))
                }
            }
        case .accessoryCorner:
            Image(systemName: entry.state.isRecording ? "record.circle.fill" : "mic.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(entry.state.isRecording ? palette.recording : palette.accent)
                .widgetLabel {
                    if entry.state.isRecording, let started = entry.state.startedAtDate {
                        Text(started, style: .timer)
                            .font(.system(size: 11, weight: .semibold, design: palette.design))
                    } else if entry.state.pendingCount > 0 {
                        Text("待传\(entry.state.pendingCount)")
                            .font(.system(size: 11, design: palette.design))
                    } else {
                        Text("录音卡")
                            .font(.system(size: 11, design: palette.design))
                    }
                }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: entry.state.isRecording ? "record.circle.fill" : "mic.fill")
                        .foregroundStyle(entry.state.isRecording ? palette.recording : palette.accent)
                    Text("录音卡")
                        .font(.system(.headline, design: palette.design))
                }
                if entry.state.isRecording, let started = entry.state.startedAtDate {
                    HStack(spacing: 4) {
                        Text("录音中")
                            .font(.system(.caption, design: palette.design))
                            .foregroundStyle(palette.recording)
                        Text(started, style: .timer)
                            .font(.system(.caption, design: palette.design).monospacedDigit())
                    }
                } else if entry.state.pendingCount > 0 {
                    Text("轻点开录 · 待传 \(entry.state.pendingCount) 段")
                        .font(.system(.caption, design: palette.design))
                        .foregroundStyle(palette.pending)
                } else {
                    Text("轻点开始持续录音")
                        .font(.system(.caption, design: palette.design))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            if entry.state.isRecording {
                Label("录音卡 · 录音中", systemImage: "record.circle.fill")
                    .font(.system(.caption, design: palette.design))
            } else {
                Label("录音卡 · 点击开录", systemImage: "mic.fill")
                    .font(.system(.caption, design: palette.design))
            }
        @unknown default:
            Image(systemName: "mic.fill")
                .foregroundStyle(palette.accent)
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
