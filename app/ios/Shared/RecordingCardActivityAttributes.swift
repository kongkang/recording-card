import Foundation

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.1, *)
struct RecordingCardActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    var title: String
    var subtitle: String
    var startedAtMs: Int64
    var isRecording: Bool
    /// 录音时长 ≥ 60 分钟时切换紧凑灵动岛为 `HH:MM` + 闪烁冒号模式。
    var isOverOneHour: Bool
    /// ≥ 60 分钟模式下冒号每秒亮灭交替状态。
    var colonVisible: Bool

    init(
      title: String,
      subtitle: String,
      startedAtMs: Int64,
      isRecording: Bool,
      isOverOneHour: Bool = false,
      colonVisible: Bool = true
    ) {
      self.title = title
      self.subtitle = subtitle
      self.startedAtMs = startedAtMs
      self.isRecording = isRecording
      self.isOverOneHour = isOverOneHour
      self.colonVisible = colonVisible
    }

    private enum CodingKeys: String, CodingKey {
      case title
      case subtitle
      case startedAtMs
      case isRecording
      case isOverOneHour
      case colonVisible
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.title = try c.decode(String.self, forKey: .title)
      self.subtitle = try c.decode(String.self, forKey: .subtitle)
      self.startedAtMs = try c.decode(Int64.self, forKey: .startedAtMs)
      self.isRecording = try c.decode(Bool.self, forKey: .isRecording)
      self.isOverOneHour = try c.decodeIfPresent(Bool.self, forKey: .isOverOneHour) ?? false
      self.colonVisible = try c.decodeIfPresent(Bool.self, forKey: .colonVisible) ?? true
    }
  }

  var appTitle: String
}
#endif
