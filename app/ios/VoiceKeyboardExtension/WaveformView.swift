import UIKit

/// 极轻量 CoreGraphics 32 柱波形视图（无第三方依赖，常驻内存 < 1MB）。
final class WaveformView: UIView {
  var bars: [UInt8] = Array(repeating: 0, count: 32) {
    didSet { setNeedsDisplay() }
  }

  var isRecordingActive: Bool = false {
    didSet { setNeedsDisplay() }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    backgroundColor = .clear
    isOpaque = false
  }

  override func draw(_ rect: CGRect) {
    guard let ctx = UIGraphicsGetCurrentContext(), !bars.isEmpty else { return }
    let count = bars.count
    let spacing: CGFloat = 3
    let totalSpacing = spacing * CGFloat(count - 1)
    let barWidth = max(2, (rect.width - totalSpacing) / CGFloat(count))
    let color: UIColor = isRecordingActive
      ? UIColor(red: 0.18, green: 0.56, blue: 0.96, alpha: 1.0)
      : UIColor.tertiaryLabel

    ctx.setFillColor(color.cgColor)
    for (idx, val) in bars.enumerated() {
      let norm = max(0.08, CGFloat(val) / 255.0)
      let barHeight = max(4, rect.height * norm)
      let x = CGFloat(idx) * (barWidth + spacing)
      let y = (rect.height - barHeight) * 0.5
      let path = UIBezierPath(
        roundedRect: CGRect(x: x, y: y, width: barWidth, height: barHeight),
        cornerRadius: barWidth * 0.5
      )
      ctx.addPath(path.cgPath)
      ctx.fillPath()
    }
  }
}
