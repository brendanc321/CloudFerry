import AppKit

// MARK: - 设计规范（v1.2 重新设计）
//
// 字号层级（只用这几级，保证一眼看出重点）：
//   页面标题 26 bold · 区块标题 15 semibold · 行标题 13 medium · 正文 13 · 说明 11.5 secondary · 标签 11 semibold
// 间距：页面左右 36、顶部 30；区块之间 28；卡片内边距 18 × 16；行间 12
// 颜色：只有一个强调色（青绿）。主按钮 = 实心强调色；次按钮 = 浅灰底；文字按钮 = 强调色文字。
// 状态一律用「胶囊标签」表达，不再用彩色长句子。

enum Typo {
    static let pageTitle = NSFont.systemFont(ofSize: 27, weight: .heavy)
    static let section = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let rowTitle = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let body = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let caption = NSFont.systemFont(ofSize: 11.5, weight: .regular)
    static let tag = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static func metric(_ size: CGFloat = 24) -> NSFont { NSFont.monospacedSystemFont(ofSize: size, weight: .semibold) }
    static func number(_ size: CGFloat = 12, _ w: NSFont.Weight = .regular) -> NSFont { NSFont.monospacedDigitSystemFont(ofSize: size, weight: w) }
}

extension Theme {
    /// 强调色上的文字颜色（暗色模式强调色很亮 → 用深色字；亮色模式用白字）
    static let onAccent = NSColor(name: NSColor.Name("cfOnAccent")) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.02, green: 0.13, blue: 0.12, alpha: 1)
            : NSColor.white
    }
    /// 次级按钮 / 输入块的底色
    static let controlFill = NSColor(name: NSColor.Name("cfControlFill")) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.085) : NSColor(white: 0, alpha: 0.055)
    }
    static let controlFillHover = NSColor(name: NSColor.Name("cfControlFillHover")) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.13) : NSColor(white: 0, alpha: 0.09)
    }
    /// 图标底块
    static let iconTile = NSColor(name: NSColor.Name("cfIconTile")) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.045)
    }
    static let success = NSColor.systemGreen
    static let warning = NSColor.systemOrange
    static let danger = NSColor.systemRed

    enum Page { static let side: CGFloat = 36, top: CGFloat = 30, bottom: CGFloat = 40, sectionGap: CGFloat = 28 }
}

// MARK: - 文字

/// 说明文字：小一号、次要色、限制最大行宽（长句不再横跨整个窗口）
func captionLabel(_ text: String, maxWidth: CGFloat? = 560, color: NSColor = .secondaryLabelColor) -> NSTextField {
    let l = makeLabel(text, color: color, multiline: true)
    l.font = Typo.caption
    if let maxWidth { l.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true }
    return l
}

func sectionTitle(_ text: String) -> NSTextField {
    let l = makeLabel(text)
    l.font = Typo.section
    return l
}

/// 区块标题行：标题 +（可选）灰色补充 + 右侧操作
func sectionHeader(_ title: String, detail: String? = nil, trailing: [NSView] = []) -> NSStackView {
    var left: [NSView] = [sectionTitle(title)]
    if let detail, !detail.isEmpty {
        let d = makeLabel(detail, color: .secondaryLabelColor); d.font = Typo.number(13)
        left.append(d)
    }
    let l = hstack(left, spacing: 8, alignment: .firstBaseline)
    return hstack([l, flexibleSpacer()] + trailing, spacing: 8, alignment: .centerY)
}

/// 页面标题：大标题 + 副标题 + 右侧操作按钮（主按钮放最右）
func pageHeader(_ title: String, subtitle: NSTextField? = nil, subtitleText: String? = nil, actions: [NSView] = []) -> NSStackView {
    let t = makeLabel(title); t.font = Typo.pageTitle
    var col: [NSView] = [t]
    if let subtitle { subtitle.font = Typo.body; subtitle.textColor = .secondaryLabelColor; col.append(subtitle) }
    else if let subtitleText { let s = makeLabel(subtitleText, color: .secondaryLabelColor); s.font = Typo.body; col.append(s) }
    let left = vstack(col, spacing: 4)
    left.setContentHuggingPriority(.defaultLow, for: .horizontal)
    left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let right = hstack(actions, spacing: 8)
    right.setContentHuggingPriority(.required, for: .horizontal)
    return hstack([left, flexibleSpacer(), right], spacing: 16, alignment: .centerY)
}

// MARK: - 按钮

/// 统一按钮：主按钮（实心强调色）/ 次按钮（浅灰底）/ 文字按钮 / 危险。带悬停与按下反馈。
final class CFButton: NSButton {
    enum Style { case primary, secondary, plain, danger, icon }
    enum Size { case small, regular, large
        var height: CGFloat { switch self { case .small: return 24; case .regular: return 28; case .large: return 34 } }
        var pad: CGFloat { switch self { case .small: return 10; case .regular: return 14; case .large: return 18 } }
        var font: NSFont {
            switch self {
            case .small: return .systemFont(ofSize: 12, weight: .medium)
            case .regular: return .systemFont(ofSize: 13, weight: .medium)
            case .large: return .systemFont(ofSize: 14, weight: .semibold)
            }
        }
        var radius: CGFloat { switch self { case .small: return 6; case .regular: return 7; case .large: return 9 } }
    }

    var style: Style { didSet { restyle() } }
    let size: Size
    private var hovering = false { didSet { restyle() } }
    private var pressed = false { didSet { restyle() } }
    private var trackingAreaRef: NSTrackingArea?
    private var label: String
    private var symbol: String?

    init(_ title: String, style: Style = .secondary, size: Size = .regular, symbol: String? = nil, action: (() -> Void)? = nil) {
        self.style = style; self.size = size; self.label = title; self.symbol = symbol
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        focusRingType = .none
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        imageHugsTitle = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: style == .icon ? 26 : size.height).isActive = true
        if style == .icon { widthAnchor.constraint(equalToConstant: 26).isActive = true }
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        if let action { onAction(action) }
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ t: String) { label = t; restyle(); invalidateIntrinsicContentSize() }
    func setSymbol(_ s: String?) { symbol = s; restyle(); invalidateIntrinsicContentSize() }

    override var isEnabled: Bool { didSet { restyle() } }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        if style == .icon { return NSSize(width: 26, height: 26) }
        return NSSize(width: ceil(base.width) + size.pad * 2 - (label.isEmpty ? size.pad : 0), height: size.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); trackingAreaRef = t
    }
    override func mouseEntered(with event: NSEvent) { if isEnabled { hovering = true } }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        super.mouseDown(with: event)   // 跟踪到松开
        pressed = false
    }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }
    override func layout() { super.layout(); applyChamfer(layer, bounds: bounds, cut: style == .icon ? 5 : size.radius - 1) }

    private func restyle() {
        let render = {
            let fg: NSColor
            var bg: NSColor = .clear
            switch self.style {
            case .primary:
                fg = Theme.inverseFG
                bg = self.hovering ? Theme.inverseBG.withAlphaComponent(0.86) : Theme.inverseBG
            case .secondary:
                fg = .labelColor
                bg = self.hovering ? Theme.controlFillHover : Theme.controlFill
            case .plain:
                fg = Theme.accent
                bg = self.hovering ? Theme.accent.withAlphaComponent(0.10) : .clear
            case .danger:
                fg = .systemRed
                bg = self.hovering ? NSColor.systemRed.withAlphaComponent(0.10) : .clear
            case .icon:
                fg = self.hovering ? .labelColor : .secondaryLabelColor
                bg = self.hovering ? Theme.controlFill : .clear
            }
            self.imagePosition = self.label.isEmpty ? .imageOnly : .imageLeading
            self.layer?.cornerRadius = 0
            self.layer?.backgroundColor = bg.cgColor
            applyChamfer(self.layer, bounds: self.bounds, cut: self.style == .icon ? 5 : self.size.radius - 1)
            self.alphaValue = !self.isEnabled ? 0.4 : (self.pressed ? 0.78 : 1)
            if let s = self.symbol {
                let cfg = NSImage.SymbolConfiguration(pointSize: self.style == .icon ? 13 : self.size == .small ? 11 : 12, weight: .semibold)
                self.image = NSImage(systemSymbolName: s, accessibilityDescription: self.label)?.withSymbolConfiguration(cfg)
                self.contentTintColor = fg
            } else { self.image = nil }
            let para = NSMutableParagraphStyle(); para.alignment = .center
            self.attributedTitle = NSAttributedString(string: self.label.isEmpty ? "" : (self.symbol != nil ? " " + self.label : self.label),
                                                      attributes: [.font: self.size.font, .foregroundColor: fg, .paragraphStyle: para])
        }
        effectiveAppearance.performAsCurrentDrawingAppearance { render() }
    }
}

// MARK: - 胶囊标签

final class Pill: ThemedBox {
    private let label = makeLabel("")
    private let iconView = NSImageView()
    private var inner: NSStackView!
    var tint: NSColor { didSet { apply() } }

    // 胶囊必须有固有尺寸，否则在横排里会被拉长
    override var intrinsicContentSize: NSSize {
        let s = inner.fittingSize
        return NSSize(width: ceil(s.width) + 16, height: ceil(s.height) + 6)
    }

    init(_ text: String, tint: NSColor = .secondaryLabelColor, symbol: String? = nil) {
        self.tint = tint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        boxRadius = 10
        chamfer = 5
        label.font = Typo.tag
        label.stringValue = text
        var views: [NSView] = []
        if let symbol {
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            iconView.symbolConfiguration = .init(pointSize: 9.5, weight: .bold)
            views.append(iconView)
        }
        views.append(label)
        let h = hstack(views, spacing: 4)
        h.translatesAutoresizingMaskIntoConstraints = false
        inner = h
        addSubview(h)
        NSLayoutConstraint.activate([
            h.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            h.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            h.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            h.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }
    func setText(_ t: String) { label.stringValue = t; invalidateIntrinsicContentSize() }
    private func apply() {
        fillColor = tint.withAlphaComponent(0.15)
        label.textColor = tint
        iconView.contentTintColor = tint
    }
}

// MARK: - 图标底块（列表行左侧的方形图标）

func iconTile(_ symbol: String, tint: NSColor = Theme.accent, size: CGFloat = 34) -> NSView {
    let box = themedBox(fill: Theme.iconTile, radius: size * 0.26, border: 0)
    let iv = NSImageView()
    iv.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    iv.symbolConfiguration = .init(pointSize: size * 0.44, weight: .medium)
    iv.contentTintColor = tint
    iv.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(iv)
    NSLayoutConstraint.activate([
        box.widthAnchor.constraint(equalToConstant: size), box.heightAnchor.constraint(equalToConstant: size),
        iv.centerXAnchor.constraint(equalTo: box.centerXAnchor), iv.centerYAnchor.constraint(equalTo: box.centerYAnchor),
    ])
    box.setContentHuggingPriority(.required, for: .horizontal)
    return box
}

// MARK: - 细分隔线

final class HairlineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { self.layer?.backgroundColor = Theme.hairline.cgColor }
    }
}

// MARK: - 指标块（大数字 + 小标题）

func metricBlock(title: String, value: NSTextField, detail: NSView? = nil) -> NSStackView {
    let t = makeLabel(title, color: .secondaryLabelColor); t.font = .systemFont(ofSize: 11.5, weight: .medium)
    value.font = Typo.metric(22)
    var v: [NSView] = [t, value]
    if let detail { v.append(detail) }
    return vstack(v, spacing: 4)
}

// MARK: - 干净的表头（去掉系统默认的深色表头条）

final class CleanHeaderCell: NSTableHeaderCell {
    var sortKey: String?
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        controlView.effectiveAppearance.performAsCurrentDrawingAppearance {
            Theme.hairline.setFill()
            NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
        }
        drawInterior(withFrame: cellFrame, in: controlView)
    }
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        var text = stringValue
        if let key = sortKey, let sd = (controlView as? NSTableHeaderView)?.tableView?.sortDescriptors.first, sd.key == key {
            text += sd.ascending ? "  ↑" : "  ↓"
        }
        controlView.effectiveAppearance.performAsCurrentDrawingAppearance {
            let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                                                                  .foregroundColor: NSColor.secondaryLabelColor])
            let size = s.size()
            let inner = cellFrame.insetBy(dx: 6, dy: 0)
            let x = self.alignment == .right ? inner.maxX - size.width : inner.minX
            s.draw(at: NSPoint(x: x, y: cellFrame.midY - size.height / 2 - 1))
        }
    }
}

/// 把表格的表头换成干净样式（细线 + 灰色小字 + 排序箭头）
func applyCleanHeader(_ table: NSTableView) {
    for c in table.tableColumns {
        let h = CleanHeaderCell(textCell: c.title)
        h.alignment = c.headerCell.alignment
        h.sortKey = c.sortDescriptorPrototype?.key
        c.headerCell = h
    }
    table.cornerView = nil
    if let hv = table.headerView { hv.frame.size.height = 30 }
}

// MARK: - 外观主题：跟随系统 / 浅色 / 深色 / 深色玻璃

extension Notification.Name { static let cfThemeChanged = Notification.Name("cfThemeChanged") }

enum AppTheme: String, CaseIterable {
    case system, light, dark, glass

    var title: String {
        switch self {
        case .system: return L("跟随系统", "System")
        case .light: return L("浅色", "Light")
        case .dark: return L("深色", "Dark")
        case .glass: return L("深色玻璃", "Dark glass")
        }
    }
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        case .glass: return "sparkles"
        }
    }

    static var current: AppTheme {
        get {
            if let env = ProcessInfo.processInfo.environment["CLOUDFERRY_THEME"], let t = AppTheme(rawValue: env) { return t }
            return UserDefaults.standard.string(forKey: "cf.theme").flatMap(AppTheme.init(rawValue:)) ?? .dark
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "cf.theme")
            MainActor.assumeIsolated { apply() }
            NotificationCenter.default.post(name: .cfThemeChanged, object: nil)
        }
    }
    var isGlass: Bool { self == .glass }

    /// 应用到整个 App 和所有普通窗口
    @MainActor static func apply() {
        let t = current
        switch t {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark, .glass: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        for w in NSApp.windows where w.contentViewController is RootSplitVC {
            w.isOpaque = !t.isGlass
            w.backgroundColor = t.isGlass ? .clear : .windowBackgroundColor
            w.invalidateShadow()
        }
    }
}

/// 内容区背景：普通主题 = 实色；玻璃主题 = 窗口后面的桌面模糊 + 深色压暗（保证文字清楚）
final class BackdropView: NSView {
    private let blur = NSVisualEffectView()
    private let tint = NSView()
    private let grid = NSView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        blur.blendingMode = .behindWindow
        blur.material = .hudWindow
        blur.state = .active
        tint.wantsLayer = true
        grid.wantsLayer = true
        for v in [blur, tint, grid] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
                v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        NotificationCenter.default.addObserver(forName: .cfThemeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true; self?.refresh() }
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { refresh() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    private func refresh() {
        let glass = AppTheme.current.isGlass
        blur.isHidden = !glass
        tint.isHidden = !glass
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.tint.layer?.backgroundColor = NSColor(srgbRed: 0.03, green: 0.05, blue: 0.06, alpha: 0.18).cgColor
            self.layer?.backgroundColor = glass ? NSColor.clear.cgColor : Theme.contentBackground.cgColor
            let dark = self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            self.grid.layer?.backgroundColor = dotGridColor(dark: dark, glass: glass).cgColor
        }
    }
}

// MARK: - 青绿色开关（替代系统蓝色开关，和品牌色统一）

final class CFSwitch: NSControl {
    var isOn: Bool = false { didSet { animateKnob() } }
    private let track = CALayer()
    private let knob = CALayer()
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.addSublayer(track); layer?.addSublayer(knob)
        knob.shadowOpacity = 0.25; knob.shadowRadius = 1.5; knob.shadowOffset = CGSize(width: 0, height: -0.5)
        knob.shadowColor = NSColor.black.cgColor
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 38, height: 22) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.frame = bounds; track.cornerRadius = bounds.height / 2
        CATransaction.commit()
        animateKnob(animated: false)
    }
    private func animateKnob(animated: Bool = true) {
        let d = bounds.height - 4
        let x = isOn ? bounds.width - d - 2 : 2
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.18 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.track.backgroundColor = (self.isOn ? Theme.accent : Theme.controlFillHover).cgColor
            self.knob.backgroundColor = NSColor.white.cgColor
        }
        knob.frame = CGRect(x: x, y: 2, width: d, height: d)
        knob.cornerRadius = d / 2
        CATransaction.commit()
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isOn.toggle()
        sendAction(action, to: target)
    }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
}

// MARK: - 外观选择小卡片（像系统设置里的外观预览）

final class ThemeSwatch: NSView {
    let theme: AppTheme
    var onPick: ((AppTheme) -> Void)?
    var selected = false { didSet { needsDisplay = true; label.textColor = selected ? Theme.accent : .secondaryLabelColor } }
    private let label = makeLabel("")
    private var hovering = false { didSet { needsDisplay = true } }

    init(_ theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = theme.title
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 104), heightAnchor.constraint(equalToConstant: 92),
            label.centerXAnchor.constraint(equalTo: centerXAnchor), label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onPick?(theme) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: 4, y: 4, width: bounds.width - 8, height: 62)
        let path = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        func fill(_ c: NSColor, _ rect: NSRect) { c.setFill(); rect.fill() }
        let darkBG = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.13, alpha: 1)
        let darkSide = NSColor(srgbRed: 0.17, green: 0.18, blue: 0.19, alpha: 1)
        let lightBG = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
        let lightSide = NSColor(srgbRed: 0.90, green: 0.91, blue: 0.92, alpha: 1)
        let side = NSRect(x: r.minX, y: r.minY, width: r.width * 0.3, height: r.height)
        let main = NSRect(x: side.maxX, y: r.minY, width: r.width - side.width, height: r.height)
        switch theme {
        case .light: fill(lightBG, main); fill(lightSide, side)
        case .dark: fill(darkBG, main); fill(darkSide, side)
        case .system:
            fill(lightBG, r); fill(lightSide, side)
            let half = NSBezierPath(); half.move(to: NSPoint(x: r.maxX, y: r.minY)); half.line(to: NSPoint(x: r.maxX, y: r.maxY))
            half.line(to: NSPoint(x: r.minX + r.width * 0.25, y: r.maxY)); half.close()
            darkBG.setFill(); half.fill()
        case .glass:
            let g = NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.32, blue: 0.40, alpha: 1),
                                        NSColor(srgbRed: 0.20, green: 0.12, blue: 0.32, alpha: 1),
                                        NSColor(srgbRed: 0.06, green: 0.08, blue: 0.10, alpha: 1)])
            g?.draw(in: r, angle: -35)
            fill(NSColor(white: 1, alpha: 0.08), side)
        }
        // 迷你卡片 + 强调色条
        let cardColor: NSColor = theme == .light ? .white : NSColor(white: 1, alpha: 0.10)
        fill(cardColor, NSRect(x: main.minX + 8, y: main.minY + 10, width: main.width - 16, height: 16))
        fill(Theme.accent, NSRect(x: main.minX + 8, y: main.minY + 34, width: (main.width - 16) * 0.6, height: 5))
        fill(theme == .light ? NSColor(white: 0, alpha: 0.12) : NSColor(white: 1, alpha: 0.18), NSRect(x: side.minX + 6, y: side.minY + 10, width: side.width - 12, height: 4))
        fill(theme == .light ? NSColor(white: 0, alpha: 0.12) : NSColor(white: 1, alpha: 0.18), NSRect(x: side.minX + 6, y: side.minY + 18, width: side.width - 16, height: 4))
        NSGraphicsContext.restoreGraphicsState()
        // 边框：选中 = 强调色粗边
        let ring = NSBezierPath(roundedRect: r.insetBy(dx: selected ? -2 : 0, dy: selected ? -2 : 0), xRadius: selected ? 11 : 9, yRadius: selected ? 11 : 9)
        ring.lineWidth = selected ? 2.5 : 1
        (selected ? Theme.accent : (hovering ? Theme.controlFillHover : Theme.hairline)).setStroke()
        ring.stroke()
    }
}

// MARK: - 小技巧卡片（可切换下一条、可关闭）

@MainActor
final class TipsCard: ThemedBox {
    private let text = makeLabel("", multiline: true)
    private var tips: [String] = []
    private var index: Int = UserDefaults.standard.integer(forKey: "cf.tipIndex")
    var onClose: (() -> Void)?

    init(tips: [String]) {
        self.tips = tips
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        fillColor = Theme.accent.withAlphaComponent(0.07)
        strokeColor = Theme.accent.withAlphaComponent(0.18)
        boxRadius = 10
        let icon = symbolView("lightbulb.max", color: Theme.accent, size: 14)!
        let title = makeLabel(L("小技巧", "Tip"), color: Theme.accent); title.font = .systemFont(ofSize: 12, weight: .semibold)
        text.font = .systemFont(ofSize: 12.5)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let next = CFButton(L("下一条", "Next"), style: .plain, size: .small) { [weak self] in self?.advance() }
        let close = CFButton("", style: .icon, symbol: "xmark") { [weak self] in self?.onClose?() }
        close.toolTip = L("不再显示小技巧（可在设置里重新打开）", "Hide tips (re-enable in Settings)")
        let h = hstack([icon, title, text, flexibleSpacer(), next, close], spacing: 10, alignment: .centerY)
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)
        NSLayoutConstraint.activate([
            h.topAnchor.constraint(equalTo: topAnchor, constant: 10), h.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            h.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), h.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        show()
    }
    required init?(coder: NSCoder) { fatalError() }
    func setTips(_ t: [String]) { tips = t; show() }
    private func show() {
        guard !tips.isEmpty else { return }
        text.stringValue = tips[((index % tips.count) + tips.count) % tips.count]
    }
    private func advance() {
        index += 1
        UserDefaults.standard.set(index, forKey: "cf.tipIndex")
        show()
        fadeIn(text, duration: 0.25)
    }
}
