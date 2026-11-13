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
  }

  var appTitle: String
}
#endif
