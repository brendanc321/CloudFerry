import AppKit
import QuartzCore

// MARK: - 精美渐变进度条

final class GradientProgressBar: NSView {
    var progress: Double = 0 { didSet { needsLayout = true } }
    var barHeight: CGFloat = 9 { didSet { heightConstraint?.constant = barHeight; needsLayout = true } }
    /// 「取景器」风格：分成一格一格的 LED
    var segmented = false { didSet { needsLayout = true } }
    private let segMask = CALayer()
    private var segMaskSize: CGSize = .zero
    private var heightConstraint: NSLayoutConstraint?
    private let track = CALayer()
    private let fill = CAGradientLayer()
    private var indeterminate = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        heightConstraint = heightAnchor.constraint(equalToConstant: barHeight)
        heightConstraint?.isActive = true
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        let render = {
            self.track.backgroundColor = Theme.hairline.cgColor
            let a = Theme.accent
            let b = a.blended(withFraction: 0.35, of: .systemTeal) ?? a
            self.fill.colors = [b.cgColor, a.cgColor]
        }
        if #available(macOS 11.0, *) { effectiveAppearance.performAsCurrentDrawingAppearance { render() } }
        else { render() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(.init(name: .easeInEaseOut))
        let h = min(barHeight, bounds.height)
        let y = (bounds.height - h) / 2
        track.frame = CGRect(x: 0, y: y, width: bounds.width, height: h)
        track.cornerRadius = h / 2
        if !indeterminate {
            let w = max(h, bounds.width * CGFloat(max(0, min(1, progress))))
            fill.frame = CGRect(x: 0, y: y, width: w, height: h)
            fill.cornerRadius = h / 2
        }
        if segmented {
            segMask.frame = bounds
            if segMaskSize != bounds.size, bounds.width > 1 {
                segMaskSize = bounds.size
                segMask.contents = segmentMask(width: bounds.width, height: bounds.height, segment: max(3, h * 0.9), gap: 1.5)
            }
            layer?.mask = segMask
            track.cornerRadius = 1; fill.cornerRadius = 1
        } else {
            layer?.mask = nil
        }
        CATransaction.commit()
    }

    func setIndeterminate(_ on: Bool) {
        guard on != indeterminate else { return }
        indeterminate = on
        let h = min(barHeight, bounds.height)
        let y = (bounds.height - h) / 2
        if on {
            let w = bounds.width * 0.35
            fill.frame = CGRect(x: -w, y: y, width: w, height: h)
            fill.cornerRadius = h / 2
            let anim = CABasicAnimation(keyPath: "position.x")
            anim.fromValue = -w / 2
            anim.toValue = bounds.width + w / 2
            anim.duration = 1.1
            anim.repeatCount = .infinity
            fill.add(anim, forKey: "slide")
        } else {
            fill.removeAnimation(forKey: "slide")
            needsLayout = true
        }
    }
}

// MARK: - Logo / 图标绘制（v1.3：粗圆环字母 C + 中间向上箭头。ChatGPT Work/Ultra 出概念，这里按几何精确重画，纯扁平）

/// Apple 风格的连续圆角（超椭圆近似）
func squirclePath(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let cx = r.midX, cy = r.midY, a = r.width / 2, b = r.height / 2
    let steps = 240
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c >= 0 ? 1 : -1) * pow(abs(c), 2 / n)
        let y = cy + b * (s >= 0 ? 1 : -1) * pow(abs(s), 2 / n)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

/// 四种配色（a 白底青标 / b 青底白标 / c 黑底白标 / d 黑底青环白箭头）。默认 d
enum LogoStyle: String, CaseIterable {
    case a, b, c, d
    static let teal = CGColor(srgbRed: 0.122, green: 0.749, blue: 0.682, alpha: 1)   // #1FBFAE
    static let ink = CGColor(srgbRed: 0.067, green: 0.067, blue: 0.067, alpha: 1)    // #111111
    static let white = CGColor(gray: 1, alpha: 1)
    static var current: LogoStyle {
        ProcessInfo.processInfo.environment["CLOUDFERRY_LOGO"].flatMap(LogoStyle.init(rawValue:)) ?? .d
    }
    var tile: CGColor { switch self { case .a: return Self.white; case .b: return Self.teal; case .c, .d: return Self.ink } }
    var ring: CGColor { switch self { case .a, .d: return Self.teal; case .b, .c: return Self.white } }
    var arrow: CGColor { switch self { case .a: return Self.teal; case .b, .c, .d: return Self.white } }
}

/// 只画符号：圆环 C（开口朝右、水平切口）+ 实心上箭头。o/T = 所在正方形。
/// 菜单栏模板图标也用它（ring/arrow 传同一种颜色）。
func drawCRingMark(_ ctx: CGContext, origin o: CGPoint, size T: CGFloat, ring: CGColor, arrow: CGColor?,
                   scale k: CGFloat = 1) {
    let cx = o.x + T / 2, cy = o.y + T / 2
    let R = T * 0.37 * k, r = T * 0.265 * k          // 外径 / 内径
    let gap = T * 0.108 * k                          // 开口上下各一半（水平切口）
    ctx.saveGState()
    // 圆环减去右侧开口：先把开口矩形以外的区域设为可画区域
    ctx.addRect(CGRect(x: o.x - T, y: o.y - T, width: T * 3, height: T * 3))
    ctx.addRect(CGRect(x: cx, y: cy - gap, width: R + T, height: gap * 2))
    ctx.clip(using: .evenOdd)
    ctx.addEllipse(in: CGRect(x: cx - R, y: cy - R, width: 2 * R, height: 2 * R))
    ctx.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
    ctx.setFillColor(ring)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
    guard let arrow else { return }
    // 实心向上箭头（居中在圆环里）
    let tip = cy + T * 0.176 * k, base = cy + T * 0.046 * k, bottom = cy - T * 0.180 * k
    let hw = T * 0.115 * k, sw = T * 0.047 * k
    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx, y: tip))
    p.addLine(to: CGPoint(x: cx + hw, y: base)); p.addLine(to: CGPoint(x: cx + sw, y: base))
    p.addLine(to: CGPoint(x: cx + sw, y: bottom)); p.addLine(to: CGPoint(x: cx - sw, y: bottom))
    p.addLine(to: CGPoint(x: cx - sw, y: base)); p.addLine(to: CGPoint(x: cx - hw, y: base))
    p.closeSubpath()
    ctx.addPath(p); ctx.setFillColor(arrow); ctx.fillPath()
}

/// 画完整图标底块 + 符号（rect = 底块区域）
func drawLogoTile(_ ctx: CGContext, in rect: CGRect, rounded: Bool = true, style: LogoStyle = .current) {
    let shape = rounded ? squirclePath(rect) : CGPath(rect: rect, transform: nil)
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.setFillColor(style.tile); ctx.fill(rect)
    drawCRingMark(ctx, origin: rect.origin, size: rect.width, ring: style.ring, arrow: style.arrow)
    ctx.restoreGState()
    if style == .a && rounded {
        // 白底加一圈很淡的描边，放在白色背景上也看得出边界
        ctx.saveGState()
        ctx.addPath(squirclePath(rect.insetBy(dx: rect.width * 0.004, dy: rect.width * 0.004)))
        ctx.setLineWidth(max(1, rect.width * 0.008)); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.12)); ctx.strokePath()
        ctx.restoreGState()
    }
}

/// 兼容旧调用：s = 画布边长；图标要按 Apple 网格留边 + 投影（iconPadding）
func drawCloudFerryLogo(_ ctx: CGContext, _ s: CGFloat, rounded: Bool = true, iconPadding: Bool = false) {
    if iconPadding {
        let body = s * 824 / 1024
        let r = CGRect(x: (s - body) / 2, y: (s - body) / 2 + s * 0.012, width: body, height: body)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.45))
        ctx.addPath(squirclePath(r)); ctx.setFillColor(CGColor(gray: 0.05, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()
        drawLogoTile(ctx, in: r, rounded: true)
    } else {
        drawLogoTile(ctx, in: CGRect(x: 0, y: 0, width: s, height: s), rounded: rounded)
    }
}

/// 最终 Logo（切角八边形 G + 上箭头，ChatGPT Work/Ultra 出图后清理）：打包在 App 的 Resources 里
@MainActor let bundledLogoTile: NSImage? = Bundle.main.url(forResource: "LogoTile", withExtension: "png").flatMap(NSImage.init(contentsOf:))
@MainActor let bundledMenuGlyph: NSImage? = Bundle.main.url(forResource: "MenuGlyph", withExtension: "png").flatMap(NSImage.init(contentsOf:))

@MainActor
func makeLogoImage(size: CGFloat, rounded: Bool = true) -> NSImage {
    if let tile = bundledLogoTile {
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            tile.draw(in: rect)
            return true
        }
    }
    return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        if let ctx = NSGraphicsContext.current?.cgContext { drawCloudFerryLogo(ctx, rect.width, rounded: rounded) }
        return true
    }
}

/// 由已编译的二进制在构建时生成图标（避开 swift 解释器的 Xcode 许可限制）
func writeIconset(to dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let specs: [(String, Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
        ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (name, px) in specs {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let g = NSGraphicsContext(bitmapImageRep: rep) else { continue }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        drawCloudFerryLogo(g.cgContext, CGFloat(px), iconPadding: true)
        NSGraphicsContext.restoreGraphicsState()
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}

// MARK: - 侧边栏悬停按钮

final class HoverSidebarButton: NSButton {
    var isSelectedRow = false { didSet { restyle() } }
    private var hovering = false { didSet { restyle() } }
    private var titleString = ""
    private var trackingAreaRef: NSTrackingArea?
    private let accentBar = CALayer()

    func setTitleString(_ s: String) { titleString = s; restyle() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(t); trackingAreaRef = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func layout() {
        super.layout()
        accentBar.frame = .zero
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        wantsLayer = true
        layer?.cornerRadius = 7
        if accentBar.superlayer == nil { layer?.addSublayer(accentBar) }
        let render = {
            let bg: NSColor = self.isSelectedRow ? Theme.accent.withAlphaComponent(0.14)
                : (self.hovering ? NSColor.labelColor.withAlphaComponent(0.06) : .clear)
            self.layer?.backgroundColor = bg.cgColor
            self.accentBar.backgroundColor = self.isSelectedRow ? Theme.accent.cgColor : NSColor.clear.cgColor
            let tint: NSColor = self.isSelectedRow ? Theme.accent : .secondaryLabelColor
            self.contentTintColor = tint
            let color: NSColor = self.isSelectedRow ? Theme.accent : .labelColor
            let weight: NSFont.Weight = self.isSelectedRow ? .semibold : .regular
            let para = NSMutableParagraphStyle(); para.firstLineHeadIndent = 6
            self.attributedTitle = NSAttributedString(string: self.titleString, attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: 13, weight: weight),
                .paragraphStyle: para,
            ])
        }
        if #available(macOS 11.0, *) { effectiveAppearance.performAsCurrentDrawingAppearance { render() } }
        else { render() }
    }
}

// MARK: - 实时吞吐 sparkline

final class SparklineView: NSView {
    var values: [Double] = [] { didSet { needsLayout = true } }
    private let lineLayer = CAShapeLayer()
    private let areaLayer = CAGradientLayer()
    private let areaMask = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        lineLayer.fillColor = nil; lineLayer.lineWidth = 1.5
        lineLayer.lineJoin = .round; lineLayer.lineCap = .round
        areaLayer.mask = areaMask
        areaLayer.startPoint = CGPoint(x: 0.5, y: 1); areaLayer.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(areaLayer); layer?.addSublayer(lineLayer)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }

    private func updateColors() {
        let render = {
            self.lineLayer.strokeColor = Theme.accent.cgColor
            self.areaLayer.colors = [Theme.accent.withAlphaComponent(0.30).cgColor, Theme.accent.withAlphaComponent(0).cgColor]
        }
        if #available(macOS 11.0, *) { effectiveAppearance.performAsCurrentDrawingAppearance { render() } } else { render() }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        guard w > 1, h > 2 else { return }
        let n = 40
        var vals = values.suffix(n).map { $0 }
        if vals.count < n { vals = Array(repeating: 0.0, count: n - vals.count) + vals }
        let maxV = max(vals.max() ?? 1, 1)
        func pt(_ i: Int, _ v: Double) -> CGPoint {
            CGPoint(x: w * CGFloat(i) / CGFloat(n - 1), y: 2 + (h - 4) * CGFloat(v / maxV))
        }
        let path = CGMutablePath()
        path.move(to: pt(0, vals[0]))
        for i in 1..<n { path.addLine(to: pt(i, vals[i])) }
        lineLayer.path = path
        let ap = path.mutableCopy()!
        ap.addLine(to: CGPoint(x: w, y: 0)); ap.addLine(to: CGPoint(x: 0, y: 0)); ap.closeSubpath()
        areaMask.path = ap
        areaLayer.frame = bounds
    }
}

// MARK: - 空状态

func makeEmptyState(icon: String, title: String, subtitle: String) -> NSView {
    let iv = NSImageView()
    iv.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
    iv.symbolConfiguration = .init(pointSize: 34, weight: .regular)
    iv.contentTintColor = .tertiaryLabelColor
    let t = makeLabel(title, size: 15, weight: .medium, color: .secondaryLabelColor)
    let s = makeLabel(subtitle, size: 12, color: .tertiaryLabelColor, multiline: true)
    s.alignment = .center; s.maximumNumberOfLines = 3
    let col = vstack([iv, t, s], spacing: 6); col.alignment = .centerX
    let wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
    col.translatesAutoresizingMaskIntoConstraints = false
    wrap.addSubview(col)
    NSLayoutConstraint.activate([
        col.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
        col.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 44),
        col.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -44),
        col.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
    ])
    return wrap
}

// MARK: - 淡入过渡

func fadeIn(_ view: NSView, duration: CFTimeInterval = 0.18) {
    view.wantsLayer = true
    let anim = CABasicAnimation(keyPath: "opacity")
    anim.fromValue = 0.0
    anim.toValue = 1.0
    anim.duration = duration
    anim.timingFunction = .init(name: .easeOut)
    view.layer?.add(anim, forKey: "fadeIn")
}

// MARK: - 侧边栏导航项（固定宽度图标列 → 所有文字左对齐；右侧可显示角标）

final class SidebarItem: NSView {
    var isSelectedRow = false { didSet { restyle() } }
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let label = makeLabel("")
    private let badge = makeLabel("")
    private var hovering = false { didSet { restyle() } }

    init(symbol: String, title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 13.5, weight: .medium)
        icon.imageAlignment = .alignCenter
        label.stringValue = title
        label.font = .systemFont(ofSize: 13)
        badge.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        badge.alignment = .right
        for v in [icon, label, badge] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ t: String) { label.stringValue = t }
    /// 右侧角标（如传输进度 41%、排队数），nil = 不显示
    func setBadge(_ t: String?) { badge.stringValue = t ?? ""; badge.isHidden = t == nil }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }
    override func layout() { super.layout(); applyChamfer(layer, bounds: bounds, cut: 7) }

    private func restyle() {
        applyChamfer(layer, bounds: bounds, cut: 7)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let bg: NSColor = self.isSelectedRow ? Theme.accent.withAlphaComponent(0.16)
                : (self.hovering ? NSColor.labelColor.withAlphaComponent(0.06) : .clear)
            self.layer?.backgroundColor = bg.cgColor
        }
        icon.contentTintColor = isSelectedRow ? Theme.accent : .secondaryLabelColor
        label.textColor = isSelectedRow ? Theme.accent : .labelColor
        label.font = .systemFont(ofSize: 13, weight: isSelectedRow ? .semibold : .regular)
        badge.textColor = isSelectedRow ? Theme.accent : .secondaryLabelColor
    }
}
