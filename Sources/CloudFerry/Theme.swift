import AppKit

// MARK: - 设计语言（Design tokens）

enum Theme {
    // 强调色：青绿/终端感，随明暗动态解析（动态 NSColor 同时修复 cgColor 明暗切换过期的问题）
    static let accent = NSColor(name: NSColor.Name("cfAccent")) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.18, green: 0.89, blue: 0.80, alpha: 1)   // #2EE3CC
            : NSColor(srgbRed: 0.05, green: 0.64, blue: 0.60, alpha: 1)   // #0DA399
    }
    static var accentDim: NSColor { accent.withAlphaComponent(0.16) }

    // 内容区背景（比卡片略暗，制造层次）
    static let contentBackground = NSColor(name: NSColor.Name("cfContentBG")) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.11, green: 0.12, blue: 0.13, alpha: 1)
            : NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
    }
    // 卡片背景
    static let card = NSColor(name: NSColor.Name("cfCard")) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.045)
            : NSColor.white
    }
    static let hairline = NSColor(name: NSColor.Name("cfHairline")) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.10)
            : NSColor(white: 0, alpha: 0.10)
    }
    // 终端面板背景（日志/命令预览）
    static let terminalBG = NSColor(name: NSColor.Name("cfTerminal")) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.07, green: 0.08, blue: 0.09, alpha: 1)
            : NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1)
    }

    // 反色（和 Logo 一样：深色里白底黑字，浅色里黑底白字）——主按钮用
    static let inverseBG = NSColor(name: NSColor.Name("cfInverseBG")) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.96, alpha: 1) : NSColor(srgbRed: 0.067, green: 0.067, blue: 0.067, alpha: 1)
    }
    static let inverseFG = NSColor(name: NSColor.Name("cfInverseFG")) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.067, green: 0.067, blue: 0.067, alpha: 1) : NSColor(white: 1, alpha: 1)
    }

    enum Space { static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 20, xxl: CGFloat = 24 }
    enum Radius { static let small: CGFloat = 8, card: CGFloat = 12, pill: CGFloat = 999 }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

/// 切角矩形路径（Logo 的八边形语言）
func chamferCGPath(_ r: CGRect, _ c0: CGFloat) -> CGPath {
    let c = min(c0, r.width / 3, r.height / 3)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + c, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + c))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c)); p.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - c))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + c)); p.closeSubpath()
    return p
}

/// 给一个 layer 套上切角遮罩（cut = 0 时去掉）
func applyChamfer(_ layer: CALayer?, bounds: CGRect, cut: CGFloat) {
    guard let layer else { return }
    if cut <= 0 { layer.mask = nil; return }
    let m = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
    m.frame = bounds
    m.path = chamferCGPath(bounds, cut)
    layer.mask = m
    layer.cornerRadius = 0
}

// MARK: - ThemedBox：颜色在绘制时解析（明暗切换自动刷新），修复缓存 cgColor 过期

class ThemedBox: NSView {
    /// 设为 true 的盒子（卡片、任务行）在「深色玻璃」主题下改用系统 Liquid Glass 做背景
    var glassCapable = false {
        didSet {
            guard glassCapable != oldValue else { return }
            if glassCapable {
                glassObserver = NotificationCenter.default.addObserver(forName: .cfThemeChanged, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshGlass() }
                }
            }
            refreshGlass()
        }
    }
    private var glassObserver: NSObjectProtocol?
    private var glassView: NSView?
    private var savedFill: NSColor?, savedStroke: NSColor?
    var isShowingGlass: Bool { glassView != nil }

    func refreshGlass() {
        let want = glassCapable && AppTheme.current.isGlass
        if #available(macOS 26.0, *), want {
            if glassView == nil {
                let g = NSGlassEffectView()
                g.cornerRadius = boxRadius
                g.style = .regular
                // 轻微压暗，保证上面的文字在任何桌面背景上都清楚
                g.tintColor = NSColor(srgbRed: 0.02, green: 0.04, blue: 0.05, alpha: 0.32)
                g.translatesAutoresizingMaskIntoConstraints = false
                addSubview(g, positioned: .below, relativeTo: nil)
                NSLayoutConstraint.activate([
                    g.topAnchor.constraint(equalTo: topAnchor), g.bottomAnchor.constraint(equalTo: bottomAnchor),
                    g.leadingAnchor.constraint(equalTo: leadingAnchor), g.trailingAnchor.constraint(equalTo: trailingAnchor),
                ])
                glassView = g
                savedFill = fillColor; savedStroke = strokeColor
                fillColor = nil
                strokeColor = nil
            }
        } else if let g = glassView {
            g.removeFromSuperview(); glassView = nil
            fillColor = savedFill; strokeColor = savedStroke
            needsLayout = true
        } else if want {
            // macOS 26 以前没有 Liquid Glass：用半透明底色代替
            fillColor = NSColor(white: 1, alpha: 0.06)
        }
    }

    var fillColor: NSColor? { didSet { needsDisplay = true } }
    var strokeColor: NSColor? { didSet { needsDisplay = true } }
    var boxRadius: CGFloat = Theme.Radius.card { didSet { needsDisplay = true } }
    var boxBorderWidth: CGFloat = 1 { didSet { needsDisplay = true } }
    /// 切角大小（> 0 时用 Logo 同款的斜切角；玻璃主题下改回圆角）
    var chamfer: CGFloat = 0 { didSet { needsLayout = true; needsDisplay = true } }
    override func layout() {
        super.layout()
        applyChamfer(layer, bounds: bounds, cut: (chamfer > 0 && !isShowingGlass) ? chamfer : 0)
    }

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let render = {
            let cut = self.chamfer > 0 && !self.isShowingGlass
            self.layer?.cornerRadius = cut ? 0 : self.boxRadius
            self.layer?.backgroundColor = self.fillColor?.cgColor
            self.layer?.borderWidth = (self.strokeColor == nil || cut) ? 0 : self.boxBorderWidth
            self.layer?.borderColor = self.strokeColor?.cgColor
        }
        if #available(macOS 11.0, *) { effectiveAppearance.performAsCurrentDrawingAppearance { render() } }
        else { render() }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true   // 明暗切换 → 重新解析颜色
    }
}

func themedBox(fill: NSColor?, stroke: NSColor? = nil, radius: CGFloat = Theme.Radius.small, border: CGFloat = 1) -> ThemedBox {
    let b = ThemedBox()
    b.fillColor = fill; b.strokeColor = stroke; b.boxRadius = radius; b.boxBorderWidth = border
    b.translatesAutoresizingMaskIntoConstraints = false
    return b
}
