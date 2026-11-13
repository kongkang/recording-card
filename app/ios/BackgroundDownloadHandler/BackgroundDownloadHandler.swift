import BackgroundAssets
import StoreKit

@available(iOS 26.0, *)
@main
struct BackgroundDownloadHandler: StoreDownloaderExtension {
  func shouldDownload(_ assetPack: AssetPack) -> Bool {
    true
  }
}
