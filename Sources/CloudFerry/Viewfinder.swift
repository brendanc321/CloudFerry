import AppKit
import QuartzCore

// 「取景器 Viewfinder」设计语言（v1.3）
// 灵感：相机取景器屏显（OSD）+ 终端。规则：
//   1. 卡片四角用取景器对焦框角标，不用粗边框
//   2. 数字、小标签一律等宽字体（SF Mono），小标签大写、拉开字距
//   3. 主色磷光青绿；「正在传」用相机 REC 红点；警告琥珀色
//   4. 时间用时间码 00:22:36；速度用 LED 电平柱；进度用分段 LED 格
//   5. 背景深石墨 + 极淡点阵网格；玻璃主题用 Liquid Glass 面板

extension Theme {
    /// 相机录制红点
    static let rec = NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1)
}

extension Typo {
    /// 屏显字体：SF Mono
    static func osd(_ size: CGFloat = 10.5, _ w: NSFont.Weight = .semibold) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: w)
    }
}

/// 屏显风格小标签：等宽、大写、字距拉开（如 REC、TC、CH 01）
func osdLabel(_ text: String, color: NSColor = .tertiaryLabelColor, size: CGFloat = 10.5) -> NSTextField {
    let l = NSTextField(labelWithString: "")
    l.attributedStringValue = osdString(text, color: color, size: size)
    return l
}
func osdString(_ text: String, color: NSColor = .tertiaryLabelColor, size: CGFloat = 10.5, weight: NSFont.Weight = .semibold) -> NSAttributedString {
    NSAttributedString(string: text.uppercased(), attributes: [
        .font: Typo.osd(size, weight), .foregroundColor: color, .kern: size * 0.12,
    ])
}

extension Format {
    /// 时间码：00:22:36（超过 99 小时也照常显示）
    static func timecode(_ seconds: Double?) -> String {
        guard let s0 = seconds, s0 > 0, s0.isFinite else { return "--:--:--" }
        let s = Int(s0.rounded())
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    static func timecode(_ seconds: Int?) -> String { timecode(seconds.map(Double.init)) }
}

// MARK: - 取景器角标（叠在卡片上，不拦截鼠标）

final class ViewfinderCorners: NSView {
    var color: NSColor = Theme.accent { didSet { needsDisplay = true } }
    var length: CGFloat = 14
    var lineWidth: CGFloat = 1.5
    var radius: CGFloat = Theme.Radius.card { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let i = lineWidth / 2
        let r = max(0, radius - i)
        let b = bounds.insetBy(dx: i, dy: i)
        let L = length
        let p = NSBezierPath()
        // 四个角：沿圆角弧线画一段 L 形
        p.move(to: NSPoint(x: b.minX, y: b.maxY - r - L)); p.line(to: NSPoint(x: b.minX, y: b.maxY - r))
        p.appendArc(withCenter: NSPoint(x: b.minX + r, y: b.maxY - r), radius: r, startAngle: 180, endAngle: 90, clockwise: true)
        p.line(to: NSPoint(x: b.minX + r + L, y: b.maxY))
        p.move(to: NSPoint(x: b.maxX - r - L, y: b.maxY)); p.line(to: NSPoint(x: b.maxX - r, y: b.maxY))
        p.appendArc(withCenter: NSPoint(x: b.maxX - r, y: b.maxY - r), radius: r, startAngle: 90, endAngle: 0, clockwise: true)
        p.line(to: NSPoint(x: b.maxX, y: b.maxY - r - L))
        p.move(to: NSPoint(x: b.maxX, y: b.minY + r + L)); p.line(to: NSPoint(x: b.maxX, y: b.minY + r))
        p.appendArc(withCenter: NSPoint(x: b.maxX - r, y: b.minY + r), radius: r, startAngle: 0, endAngle: -90, clockwise: true)
        p.line(to: NSPoint(x: b.maxX - r - L, y: b.minY))
        p.move(to: NSPoint(x: b.minX + r + L, y: b.minY)); p.line(to: NSPoint(x: b.minX + r, y: b.minY))
        p.appendArc(withCenter: NSPoint(x: b.minX + r, y: b.minY + r), radius: r, startAngle: -90, endAngle: -180, clockwise: true)
        p.line(to: NSPoint(x: b.minX, y: b.minY + r + L))
        p.lineWidth = lineWidth
        p.lineCapStyle = .square
        color.withAlphaComponent(0.75).setStroke()
        p.stroke()
    }
}

/// 给任意视图加角标覆盖层
@discardableResult
func addViewfinderCorners(to v: NSView, radius: CGFloat, length: CGFloat = 14) -> ViewfinderCorners {
    let c = ViewfinderCorners()
    c.radius = radius; c.length = length
    v.addSubview(c)
    NSLayoutConstraint.activate([
        c.topAnchor.constraint(equalTo: v.topAnchor), c.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        c.leadingAnchor.constraint(equalTo: v.leadingAnchor), c.trailingAnchor.constraint(equalTo: v.trailingAnchor),
    ])
    return c
}

// MARK: - 点阵网格纹理（内容区背景）

@MainActor func dotGridColor(dark: Bool, glass: Bool) -> NSColor {
    let step: CGFloat = 18
    let img = NSImage(size: NSSize(width: step, height: step), flipped: false) { _ in
        let a: CGFloat = glass ? 0.07 : (dark ? 0.055 : 0.07)
        (dark ? NSColor.white : NSColor.black).withAlphaComponent(a).setFill()
        NSBezierPath(ovalIn: NSRect(x: step / 2 - 0.75, y: step / 2 - 0.75, width: 1.5, height: 1.5)).fill()
        return true
    }
    return NSColor(patternImage: img)
}

// MARK: - 分段 LED 遮罩（给进度条用）

func segmentMask(width: CGFloat, height: CGFloat, segment: CGFloat = 4, gap: CGFloat = 1.5, scale: CGFloat = 2) -> CGImage? {
    let w = Int(max(1, width * scale)), h = Int(max(1, height * scale))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(gray: 1, alpha: 1)
    var x: CGFloat = 0
    while x < width {
        ctx.fill(CGRect(x: x * scale, y: 0, width: min(segment, width - x) * scale, height: CGFloat(h)))
        x += segment + gap
    }
    guard let gray = ctx.makeImage() else { return nil }
    // 灰度图 → 带 alpha 的遮罩
    guard let actx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    actx.clip(to: CGRect(x: 0, y: 0, width: w, height: h), mask: gray)
    actx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    actx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return actx.makeImage()
}
