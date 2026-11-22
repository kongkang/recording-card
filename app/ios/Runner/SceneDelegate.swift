import Flutter
import UIKit

/// UIScene 迁移：官方模板要求的本地 SceneDelegate 子类，
/// 同时接管 Control Center / 操作按钮 → 控制 传入的 `reai-mobile://action/...` 触发 URL。
class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    _ = handleRecordingCardActionURLs(connectionOptions.urlContexts)
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    let remaining = handleRecordingCardActionURLs(URLContexts)
    if !remaining.isEmpty {
      super.scene(scene, openURLContexts: remaining)
    }
  }

  override func sceneDidEnterBackground(_ scene: UIScene) {
    AppDelegate.trimNativeMemory()
    super.sceneDidEnterBackground(scene)
  }

  private func handleRecordingCardActionURLs(
    _ contexts: Set<UIOpenURLContext>
  ) -> Set<UIOpenURLContext> {
    var remaining = Set<UIOpenURLContext>()
    for ctx in contexts {
      let url = ctx.url
      if url.scheme?.lowercased() == "reai-mobile",
         url.host?.lowercased() == "action" {
        let action = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if action == "agent" {
          LiveActivityBridge.shared.triggerActionButtonAgent()
          continue
        }
        if action == "toggle" {
          LiveActivityBridge.shared.triggerActionButtonToggle()
          continue
        }
      }
      remaining.insert(ctx)
    }
    return remaining
  }
}
