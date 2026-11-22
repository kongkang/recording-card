import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// 菜单「设置…」（⌘,）切到现有设置页。登录前外壳还没挂上时，调用会被 Dart 侧忽略。
  @IBAction func openSettings(_ sender: Any?) {
    guard let controller = mainFlutterWindow.contentViewController as? FlutterViewController else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "com.reai.recordingcard/desktop",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.invokeMethod("openSettings", arguments: nil)
  }
}
