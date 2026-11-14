import CoreText
import Foundation
import SwiftUI
import WidgetKit

enum RCLcdFontRegistrar {
  private static let lock = NSLock()
  private static var registered = false

  static func registerIfNeeded() {
    lock.lock()
    defer { lock.unlock() }
    guard !registered else { return }
    registered = true

    let bundles: [Bundle] = [Bundle.main, Bundle(for: BundleAnchor.self)]
    for bundle in bundles {
      if let url = bundle.url(forResource: "RCLcdDigital-Regular", withExtension: "ttf") {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return
      }
    }
  }

  private final class BundleAnchor {}
}

@available(iOSApplicationExtension 16.1, *)
@main
struct RecordingCardLiveActivityBundle: WidgetBundle {
  init() {
    RCLcdFontRegistrar.registerIfNeeded()
  }

  var body: some Widget {
    RecordingCardLiveActivityWidget()
  }
}
