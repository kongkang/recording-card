import Flutter
@testable import Runner
import UIKit
import XCTest

class RunnerTests: XCTestCase {

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

  func testFlutterAppDelegateDoesNotImplementMemoryWarningAndAppDelegateDoesNotCrash() {
    // TestFlight Issue #1 回归：FlutterAppDelegate 未实现 applicationDidReceiveMemoryWarning:，
    // AppDelegate 不得再覆盖并调用 super.applicationDidReceiveMemoryWarning(_:)。
    XCTAssertFalse(
      FlutterAppDelegate.instancesRespond(
        to: #selector(UIApplicationDelegate.applicationDidReceiveMemoryWarning(_:))
      )
    )
    XCTAssertFalse(
      AppDelegate.instancesRespond(
        to: #selector(UIApplicationDelegate.applicationDidReceiveMemoryWarning(_:))
      )
    )
    AppDelegate.trimNativeMemory()
    NotificationCenter.default.post(
      name: UIApplication.didReceiveMemoryWarningNotification,
      object: UIApplication.shared
    )
  }

  func testLiveActivityBridgeRuntimeGuardForMacHosts() {
    // TestFlight Issue #2 回归：Apple Silicon Mac 兼容模式 / Catalyst 下禁掉 ActivityKit 弱链接调用。
    XCTAssertFalse(
      LiveActivityBridge.isActivityKitRuntimeAvailable(
        isiOSAppOnMac: true,
        isMacCatalystApp: false
      )
    )
    XCTAssertFalse(
      LiveActivityBridge.isActivityKitRuntimeAvailable(
        isiOSAppOnMac: false,
        isMacCatalystApp: true
      )
    )
    let macFlags = LiveActivityBridge.hardwareFlags(model: "Mac15,12")
    XCTAssertFalse(macFlags.island)
    XCTAssertFalse(macFlags.actionButton)
  }

}
