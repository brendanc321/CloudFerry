import AppKit
import ObjectiveC

// MARK: - Formatting helpers

enum Format {
    static func bytes(_ b: Int64) -> String {
        if b <= 0 { return "0 B" }
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowedUnits = b < 1024 ? [.useBytes] : [.useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: b)
    }
    static func speed(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1 { return "0 MB/s" }
        let mb = bytesPerSec / 1_000_000
        if mb >= 1 { return String(format: "%.1f MB/s", mb) }
        return String(format: "%.0f KB/s", bytesPerSec / 1000)
    }
    static func eta(_ seconds: Int?) -> String {
        guard let s = seconds, s > 0 else { return "—" }
        return L("剩 ", "") + remaining(s) + L("", " left")
    }
    /// 剩余时间（不带前缀）：1 小时 5 分 / 22 分 36 秒 / 1h 5m / 22m 36s
    static func remaining(_ s: Int?) -> String {
        guard let s, s > 0 else { return "—" }
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return L("\(h) 小时 \(m) 分", "\(h)h \(m)m") }
        if m > 0 { return L("\(m) 分 \(sec) 秒", "\(m)m \(sec)s") }
        return L("\(sec) 秒", "\(sec)s")
    }
    /// 用时：1 小时 23 分 / 4 分 05 秒 / 12 秒
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return L("\(h) 小时 \(m) 分", "\(h)h \(m)m") }
        if m > 0 { return L(String(format: "%d 分 %02d 秒", m, sec), String(format: "%dm %02ds", m, sec)) }
        return L("\(sec) 秒", "\(sec)s")
    }
    static func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = RelativeDateTimeFormatter()
        f.locale = Loc.appleLocale
        return f.localizedString(for: date, relativeTo: Date())
    }
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()
    static func dateShort(_ date: Date?) -> String {
        guard let date else { return "—" }
        return dateFmt.string(from: date)
    }
    /// 解析 rclone 的 ISO8601（可能带纳秒）时间字符串
    static func parseModTime(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let dot = s.firstIndex(of: "."),
           let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            return f.date(from: String(s[..<dot]) + String(s[tz...]))
        }
        return f.date(from: s)
    }
}

// MARK: - Closure target/action bridge

final class Trampoline: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}
private var kTrampoline: UInt8 = 0

extension NSControl {
    func onAction(_ closure: @escaping () -> Void) {
        let t = Trampoline(closure)
        target = t
        action = #selector(Trampoline.fire)
        objc_setAssociatedObject(self, &kTrampoline, t, .OBJC_ASSOCIATION_RETAIN)
    }
}

// MARK: - Label helpers

func makeLabel(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
               color: NSColor = .labelColor, multiline: Bool = false, mono: Bool = false) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = mono ? Theme.mono(size, weight) : .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    if multiline {
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 0
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    return l
}

func hstack(_ views: [NSView], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    s.spacing = spacing
    s.alignment = alignment
    return s
}
func vstack(_ views: [NSView], spacing: CGFloat = 6, alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .vertical
    s.spacing = spacing
    s.alignment = alignment
    return s
}
func flexibleSpacer() -> NSView {
    let v = NSView()
    v.setContentHuggingPriority(.defaultLow, for: .horizontal)
    v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return v
}

// MARK: - Captioned rows (label + control + explanatory subtext)

/// 表单行：左边「标题 + 灰色说明」，右边控件，垂直居中对齐（像系统设置）
func captionedRow(title: String, caption: String, control: NSView) -> NSView {
    let titleLabel = makeLabel(title)
    titleLabel.font = Typo.rowTitle
    var textViews: [NSView] = [titleLabel]
    if !caption.isEmpty { textViews.append(captionLabel(caption, maxWidth: 520)) }
    let textCol = vstack(textViews, spacing: 3)
    textCol.setContentHuggingPriority(.defaultLow, for: .horizontal)
    textCol.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    control.setContentHuggingPriority(.required, for: .horizontal)
    control.setContentCompressionResistancePriority(.required, for: .horizontal)
    let row = hstack([textCol, flexibleSpacer(), control], spacing: 20, alignment: .centerY)
    row.translatesAutoresizingMaskIntoConstraints = false
    return row
}

func rowStepper(_ title: String, _ caption: String, min: Int, max: Int, suffix: String = "",
                get: @escaping () -> Int, set: @escaping (Int) -> Void) -> NSView {
    let value = makeLabel("\(get())\(suffix)", size: 13, weight: .semibold, mono: true)
    value.alignment = .right
    value.widthAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
    let stepper = NSStepper()
    stepper.minValue = Double(min); stepper.maxValue = Double(max); stepper.increment = 1
    stepper.integerValue = get()
    stepper.valueWraps = false
    stepper.onAction { let v = stepper.integerValue; set(v); value.stringValue = "\(v)\(suffix)" }
    return captionedRow(title: title, caption: caption, control: hstack([value, stepper], spacing: 8))
}

func rowToggle(_ title: String, _ caption: String,
               get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> NSView {
    let sw = CFSwitch()
    sw.isOn = get()
    sw.onAction { set(sw.isOn) }
    return captionedRow(title: title, caption: caption, control: sw)
}

func rowPopup(_ title: String, _ caption: String, items: [String], width: CGFloat = 120,
              get: @escaping () -> Int, set: @escaping (Int) -> Void) -> NSView {
    let pop = NSPopUpButton()
    pop.addItems(withTitles: items)
    pop.selectItem(at: Swift.min(Swift.max(get(), 0), items.count - 1))
    pop.onAction { set(pop.indexOfSelectedItem) }
    pop.widthAnchor.constraint(equalToConstant: width).isActive = true
    return captionedRow(title: title, caption: caption, control: pop)
}

func rowTextField(_ title: String, _ caption: String, placeholder: String, width: CGFloat = 180,
                  get: @escaping () -> String, set: @escaping (String) -> Void) -> NSView {
    let tf = NSTextField(string: get())
    tf.placeholderString = placeholder
    tf.widthAnchor.constraint(equalToConstant: width).isActive = true
    tf.cell?.sendsActionOnEndEditing = true
    tf.onAction { set(tf.stringValue) }
    return captionedRow(title: title, caption: caption, control: tf)
}

func rowDoubleField(_ title: String, _ caption: String, width: CGFloat = 80,
                    get: @escaping () -> Double, set: @escaping (Double) -> Void) -> NSView {
    let tf = NSTextField(string: String(get()))
    tf.widthAnchor.constraint(equalToConstant: width).isActive = true
    tf.cell?.sendsActionOnEndEditing = true
    tf.onAction { set(Double(tf.stringValue) ?? get()) }
    return captionedRow(title: title, caption: caption, control: tf)
}

func divider() -> NSView { HairlineView() }

// MARK: - Card container

class CardBox: ThemedBox {
    let stack = NSStackView()
    init(title: String?, systemImage: String? = nil) {
        super.init(frame: .zero)
        fillColor = Theme.card
        strokeColor = nil
        chamfer = 12
        boxRadius = Theme.Radius.card
        translatesAutoresizingMaskIntoConstraints = false
        glassCapable = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
        // 卡片标题：只用文字（去掉彩色图标，减少视觉噪音）
        if let title {
            let label = makeLabel(title)
            label.font = .systemFont(ofSize: 14, weight: .semibold)
            addRow(label)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 「取景器」角标（可隐藏）
    private(set) var corners: ViewfinderCorners?
    var showsCorners: Bool { get { !(corners?.isHidden ?? true) } set { corners?.isHidden = !newValue } }

    func addRow(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        v.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
    }
    func addDivider() { addRow(divider()) }
}

func symbolView(_ name: String?, color: NSColor = .labelColor, size: CGFloat = 14) -> NSView? {
    guard let name else { return nil }
    let iv = NSImageView()
    iv.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    iv.contentTintColor = color
    iv.symbolConfiguration = .init(pointSize: size, weight: .regular)
    return iv
}

// MARK: - Banner

final class BannerView: ThemedBox {
    enum Kind { case info, warning, danger, success
        var color: NSColor {
            switch self { case .info: return Theme.accent; case .warning: return .systemOrange
            case .danger: return .systemRed; case .success: return .systemGreen }
        }
        var symbol: String {
            switch self { case .info: return "info.circle.fill"; case .warning: return "exclamationmark.triangle.fill"
            case .danger: return "xmark.octagon.fill"; case .success: return "checkmark.circle.fill" }
        }
    }
    init(kind: Kind, title: String, message: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        super.init(frame: .zero)
        fillColor = kind.color.withAlphaComponent(0.09)
        strokeColor = kind.color.withAlphaComponent(0.22)
        boxRadius = 10
        translatesAutoresizingMaskIntoConstraints = false

        let icon = symbolView(kind.symbol, color: kind.color, size: 15)!
        let titleLabel = makeLabel(title, multiline: true)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        var textViews: [NSView] = [titleLabel]
        if let message { textViews.append(captionLabel(message, maxWidth: 640)) }
        let textCol = vstack(textViews, spacing: 3)
        textCol.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textCol.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var row: [NSView] = [icon, textCol]
        if let actionTitle, let action {
            row.append(flexibleSpacer())
            row.append(CFButton(actionTitle, style: kind == .info ? .primary : .secondary, size: .small, action: action))
        }
        let h = hstack(row, spacing: 12, alignment: .centerY)
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)
        NSLayoutConstraint.activate([
            h.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            h.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            h.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            h.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Scrollable vertical stack (page body)

/// 页面滚动容器：内容居中、限制最大宽度（大窗口下不再拉成一长条），统一页边距
func makeVScroll(maxWidth: CGFloat = 920) -> (scroll: NSScrollView, content: NSStackView) {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.autohidesScrollers = true

    let doc = FlippedView()
    doc.translatesAutoresizingMaskIntoConstraints = false

    let content = NSStackView()
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 16
    content.translatesAutoresizingMaskIntoConstraints = false
    doc.addSubview(content)
    let fill = content.widthAnchor.constraint(equalTo: doc.widthAnchor, constant: -Theme.Page.side * 2)
    fill.priority = .defaultHigh
    NSLayoutConstraint.activate([
        content.topAnchor.constraint(equalTo: doc.topAnchor, constant: Theme.Page.top),
        content.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -Theme.Page.bottom),
        content.centerXAnchor.constraint(equalTo: doc.centerXAnchor),
        content.leadingAnchor.constraint(greaterThanOrEqualTo: doc.leadingAnchor, constant: Theme.Page.side),
        content.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
        fill,
    ])
    scroll.documentView = doc
    NSLayoutConstraint.activate([
        doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
    ])
    return (scroll, content)
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// makes an arranged subview fill the stack width
func pinWidth(_ v: NSView, to stack: NSStackView) {
    v.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
    v.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
}

// MARK: - Drop view

final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    private let border = CAShapeLayer()
    private var hovering = false { didSet { updateStyle() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        border.fillColor = nil
        border.lineDashPattern = [8, 6]
        border.lineWidth = 2
        layer?.addSublayer(border)
        registerForDraggedTypes([.fileURL])
        updateStyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        border.frame = bounds
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 15, cornerHeight: 15, transform: nil)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateStyle() }
    private func updateStyle() {
        let render = {
            self.border.strokeColor = (self.hovering ? Theme.accent : Theme.accent.withAlphaComponent(0.4)).cgColor
            self.border.lineDashPattern = self.hovering ? [10, 5] : [6, 6]
            self.layer?.backgroundColor = Theme.accent.withAlphaComponent(self.hovering ? 0.09 : 0.035).cgColor
        }
        if #available(macOS 11.0, *) { effectiveAppearance.performAsCurrentDrawingAppearance { render() } }
        else { render() }
        needsDisplay = true
    }

    // 极客点阵背景
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Theme.accent.withAlphaComponent(hovering ? 0.16 : 0.09).setFill()
        let step: CGFloat = 24
        var y: CGFloat = 16
        while y < bounds.height - 8 {
            var x: CGFloat = 16
            while x < bounds.width - 8 {
                NSBezierPath(ovalIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)).fill()
                x += step
            }
            y += step
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { hovering = true; return .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { hovering = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { hovering = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hovering = false
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL],
              !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
