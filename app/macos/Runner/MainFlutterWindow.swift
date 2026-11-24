import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.title = "录音卡"
    self.minSize = NSSize(width: 960, height: 680)
    self.collectionBehavior.insert(.fullScreenPrimary)

    let visible = (self.screen ?? NSScreen.main)?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let width = min(1280, visible.width - 48)
    let height = min(840, visible.height - 48)
    self.setContentSize(NSSize(width: width, height: height))
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)
    PhoneMicBridge.shared.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
