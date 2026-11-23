import AppKit
import QuartzCore

// 实时监控面板（v1.3）：大号速度读数 + 带刻度的吞吐曲线 + 5 个指标 + 正在传输的文件 + 刚完成的文件

extension Format {
    /// 网速（比特/秒）：832 Mbps / 1.21 Gbps —— 和宽带套餐的单位一致
    static func bits(_ bytesPerSec: Double) -> String {
        let bps = bytesPerSec * 8
        if bps >= 1e9 { return String(format: "%.2f Gbps", bps / 1e9) }
        if bps >= 1e6 { return String(format: "%.0f Mbps", bps / 1e6) }
        if bps >= 1e3 { return String(format: "%.0f Kbps", bps / 1e3) }
        return "0 Mbps"
    }
    /// 很短的「多久以前」：12 秒前 / 3 分钟前 / 14:05
    static func ago(_ d: Date?) -> String {
        guard let d else { return "—" }
        let s = max(0, Int(Date().timeIntervalSince(d)))
        if s < 60 { return L("\(s) 秒前", "\(s)s ago") }
        if s < 3600 { return L("\(s / 60) 分钟前", "\(s / 60)m ago") }
        return clock(d)
    }
    private static let clockFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    static func clock(_ d: Date) -> String { clockFmt.string(from: d) }
}

/// 按扩展名给文件一个图标（视频 / 照片 / 音频 / 附属文件）
func fileSymbol(for name: String) -> String {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "mp4", "mov", "mxf", "avi", "mts", "m2ts", "braw", "r3d", "crm", "insv", "lrv", "mkv": return "film"
    case "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "cr3", "cr2", "arw", "nef", "raf", "dng", "orf", "rw2", "srw", "gpr": return "photo"
    case "wav", "mp3", "aac", "m4a", "bwf", "aif", "aiff": return "waveform"
    case "xml", "thm", "xmp", "json", "txt", "bin", "dat", "ind": return "doc.text"
    default: return "doc"
    }
}

/// 「文件夹/」暗一点、「文件名」亮一点的路径文字
func pathAttributed(_ path: String, size: CGFloat = 12.5) -> NSAttributedString {
    let ns = path as NSString
    let dir = ns.deletingLastPathComponent
    let base = ns.lastPathComponent
    let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingMiddle
    let out = NSMutableAttributedString()
    if !dir.isEmpty {
        out.append(NSAttributedString(string: dir + "/", attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: para]))
    }
    out.append(NSAttributedString(string: base, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: para]))
    return out
}

// MARK: - 吞吐曲线（带刻度、平均线、峰值点、当前点光晕）

final class ThroughputChartView: NSView {
    var values: [Double] = [] { didSet { needsDisplay = true } }
    /// 显示多少个采样点（1 秒一个）：60 = 1 分钟，300 = 5 分钟
    var windowSize: Int = 60 { didSet { needsDisplay = true } }
    var live = false { didSet { needsDisplay = true } }
    /// 紧凑模式：只有 LED 柱，没有刻度和标注（菜单栏面板用）
    var compact = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    private static func niceStep(_ raw: Double) -> Double {
        guard raw > 0 else { return 1 }
        let p = pow(10, floor(log10(raw)))
        for m in [1.0, 2.0, 2.5, 5.0, 10.0] where raw <= m * p { return m * p }
        return 10 * p
    }

    override func draw(_ dirtyRect: NSRect) {
        let right: CGFloat = compact ? 0 : 70, bottom: CGFloat = compact ? 0 : 18, top: CGFloat = compact ? 0 : 6
        let plot = NSRect(x: 0, y: bottom, width: max(10, bounds.width - right), height: max(10, bounds.height - bottom - top))
        let n = max(2, windowSize)
        let vals = Array(values.suffix(n))
        let peak = vals.max() ?? 0
        let step = Self.niceStep(max(peak * 1.15, 2_000_000) / 4)
        let maxV = step * 4

        let accent = Theme.accent
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: Typo.osd(9.5, .medium), .foregroundColor: NSColor.tertiaryLabelColor]

        // 底部微弱的渐变背景，增加层次
        if !compact, let bg = NSGradient(colors: [accent.withAlphaComponent(0.035), accent.withAlphaComponent(0.0)]) {
            bg.draw(in: NSBezierPath(roundedRect: plot, xRadius: 6, yRadius: 6), angle: 90)
        }

        // 横向刻度线 + 右侧刻度值
        for k in 0...4 where !compact {
            let y = plot.minY + plot.height * CGFloat(k) / 4
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y)); line.line(to: NSPoint(x: plot.maxX, y: y))
            line.lineWidth = 1
            if k > 0 { line.setLineDash([2, 4], count: 2, phase: 0) }
            Theme.hairline.setStroke(); line.stroke()
            let v = step * Double(k)
            let s = k == 0 ? "0" : Format.speed(v) as NSString
            let sz = s.size(withAttributes: labelAttrs)
            s.draw(at: NSPoint(x: plot.maxX + 8, y: y - sz.height / 2), withAttributes: labelAttrs)
        }
        // 竖向时间刻度
        let spanSec = n
        let ticks = 5
        for t in 0...ticks where !compact {
            let x = plot.minX + plot.width * CGFloat(t) / CGFloat(ticks)
            let secAgo = spanSec - spanSec * t / ticks
            let text: String = secAgo == 0 ? "NOW" : (spanSec >= 120 ? "-\(secAgo / 60)m" : "-\(secAgo)s")
            let s = text as NSString
            let sz = s.size(withAttributes: labelAttrs)
            let lx = min(max(plot.minX, x - sz.width / 2), plot.maxX - sz.width)
            s.draw(at: NSPoint(x: lx, y: 2), withAttributes: labelAttrs)
            if t > 0 && t < ticks {
                let tick = NSBezierPath(); tick.move(to: NSPoint(x: x, y: plot.minY)); tick.line(to: NSPoint(x: x, y: plot.maxY))
                tick.setLineDash([1, 5], count: 2, phase: 0); tick.lineWidth = 1
                Theme.hairline.withAlphaComponent(0.6).setStroke(); tick.stroke()
            }
        }

        guard !vals.isEmpty else { return }
        // LED 电平柱：1 分钟 = 60 根，5 分钟 = 100 根（每根是 3 秒平均）
        let bars = n <= 60 ? n : 100
        let per = Double(n) / Double(bars)
        var levels = [Double](repeating: -1, count: bars)   // -1 = 还没有数据
        let offset = n - vals.count
        for bi in 0..<bars {
            let s0 = Int(Double(bi) * per), s1 = max(s0 + 1, Int(Double(bi + 1) * per))
            var sum = 0.0, cnt = 0
            for si in s0..<s1 { let vi = si - offset; if vi >= 0 && vi < vals.count { sum += vals[vi]; cnt += 1 } }
            if cnt > 0 { levels[bi] = sum / Double(cnt) }
        }
        let slot = plot.width / CGFloat(bars)
        let gapX: CGFloat = slot > 7 ? 2 : 1
        let cellH: CGFloat = compact ? 2 : 3, gapY: CGFloat = compact ? 1 : 1.5
        let cells = max(4, Int(plot.height / (cellH + gapY)))
        let unlit = NSColor.labelColor.withAlphaComponent(0.045)
        let lastIndex = levels.lastIndex(where: { $0 >= 0 }) ?? -1
        var peakBar = -1, peakVal = 0.0
        for (bi, v) in levels.enumerated() where v > peakVal { peakVal = v; peakBar = bi }
        for bi in 0..<bars {
            let x = plot.minX + CGFloat(bi) * slot
            let v = levels[bi]
            let lit = v < 0 ? 0 : min(cells, Int(ceil(v / maxV * Double(cells))))
            for ci in 0..<cells {
                let r = NSRect(x: x, y: plot.minY + CGFloat(ci) * (cellH + gapY), width: max(1, slot - gapX), height: cellH)
                if ci < lit {
                    let level = CGFloat(ci) / CGFloat(cells)
                    var c = accent.withAlphaComponent(0.45 + 0.55 * level)
                    if ci == lit - 1 { c = (bi == lastIndex && live) ? NSColor.white.withAlphaComponent(0.95) : accent }
                    c.setFill()
                } else {
                    unlit.setFill()
                }
                r.fill()
            }
        }

        // 平均线（只算有速度的采样）
        if compact { return }
        let nz = vals.filter { $0 > 0 }
        if !nz.isEmpty {
            let avg = nz.reduce(0, +) / Double(nz.count)
            let y = plot.minY + plot.height * CGFloat(min(1, avg / maxV))
            let l = NSBezierPath(); l.move(to: NSPoint(x: plot.minX, y: y)); l.line(to: NSPoint(x: plot.maxX, y: y))
            l.setLineDash([5, 4], count: 2, phase: 0); l.lineWidth = 1
            NSColor.labelColor.withAlphaComponent(0.45).setStroke(); l.stroke()
            let tag = ("AVG " + Format.speed(avg)) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: Typo.osd(9.5), .foregroundColor: NSColor.labelColor.withAlphaComponent(0.75)]
            let sz = tag.size(withAttributes: attrs)
            let ty = y + 3 + sz.height < plot.maxY ? y + 3 : y - sz.height - 3
            let bgR = NSRect(x: plot.minX + 4, y: ty - 1, width: sz.width + 8, height: sz.height + 2)
            NSColor.windowBackgroundColor.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: bgR, xRadius: 3, yRadius: 3).fill()
            tag.draw(at: NSPoint(x: plot.minX + 8, y: ty), withAttributes: attrs)
        }
        // 峰值标记
        if peakBar >= 0, peakVal > 0 {
            let x = plot.minX + (CGFloat(peakBar) + 0.5) * slot
            let y = plot.minY + plot.height * CGFloat(min(1, peakVal / maxV))
            let tag = ("PEAK " + Format.speed(peakVal)) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: Typo.osd(9.5), .foregroundColor: NSColor.secondaryLabelColor]
            let sz = tag.size(withAttributes: attrs)
            let tx = min(max(plot.minX, x - sz.width / 2), plot.maxX - sz.width)
            let ty = min(plot.maxY - sz.height + 4, y + 5)
            tag.draw(at: NSPoint(x: tx, y: ty), withAttributes: attrs)
        }
    }
}

// MARK: - 呼吸灯小圆点（LIVE）

final class PulseDot: NSView {
    private let dot = CALayer()
    var active = false { didSet { if active != oldValue { apply() } } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 8).isActive = true
        heightAnchor.constraint(equalToConstant: 8).isActive = true
        layer?.addSublayer(dot)
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); dot.frame = bounds; dot.cornerRadius = bounds.width / 2 }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); apply() }
    private func apply() {
        let c = active ? Theme.rec : NSColor.tertiaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance { self.dot.backgroundColor = c.cgColor }
        dot.removeAllAnimations()
        guard active else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1; a.toValue = 0.25; a.duration = 0.9
        a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = .init(name: .easeInEaseOut)
        dot.add(a, forKey: "pulse")
    }
}

// MARK: - 文件列表的一行（正在传 / 刚完成 共用列宽）

private enum Col {
    static let size: CGFloat = 128, bar: CGFloat = 96, pct: CGFloat = 40, speed: CGFloat = 84, tail: CGFloat = 70
}

private func fixedLabel(_ width: CGFloat, color: NSColor = .secondaryLabelColor, align: NSTextAlignment = .right) -> NSTextField {
    let l = makeLabel("", color: color)
    l.font = Typo.number(11.5)
    l.alignment = align
    l.lineBreakMode = .byTruncatingTail
    l.translatesAutoresizingMaskIntoConstraints = false
    l.widthAnchor.constraint(equalToConstant: width).isActive = true
    return l
}

final class LiveFileRow: NSView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let size = fixedLabel(Col.size)
    private let bar = GradientProgressBar()
    private let pct = fixedLabel(Col.pct, color: .labelColor)
    private let speed = fixedLabel(Col.speed, color: Theme.accent)
    private let eta = fixedLabel(Col.tail)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.barHeight = 5
        bar.segmented = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: Col.bar).isActive = true
        let h = hstack([icon, name, size, bar, pct, speed, eta], spacing: 10)
        h.distribution = .fill
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: leadingAnchor), h.trailingAnchor.constraint(equalTo: trailingAnchor),
            h.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: 28),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ f: LiveFile) {
        icon.image = NSImage(systemSymbolName: fileSymbol(for: f.name), accessibilityDescription: nil)
        name.attributedStringValue = pathAttributed(f.name)
        name.toolTip = f.name
        size.stringValue = Format.bytes(f.bytes) + " / " + Format.bytes(f.size)
        bar.progress = Double(f.percent) / 100
        pct.stringValue = "\(f.percent)%"
        speed.stringValue = Format.speed(f.speed > 0 ? f.speed : f.speedAvg)
        eta.stringValue = Format.timecode(f.eta)
    }
}

final class DoneFileRow: NSView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let size = fixedLabel(Col.size)
    private let took = fixedLabel(Col.bar + 10 + Col.pct)
    private let speed = fixedLabel(Col.speed)
    private let when = fixedLabel(Col.tail, color: .tertiaryLabelColor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let h = hstack([icon, name, size, took, speed, when], spacing: 10)
        h.distribution = .fill
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: leadingAnchor), h.trailingAnchor.constraint(equalTo: trailingAnchor),
            h.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: 26),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ f: DoneFile) {
        icon.image = NSImage(systemSymbolName: f.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", accessibilityDescription: nil)
        icon.contentTintColor = f.ok ? Theme.success : Theme.warning
        name.attributedStringValue = pathAttributed(f.name, size: 12)
        name.toolTip = f.ok ? f.name : f.name + "\n" + f.error
        size.stringValue = Format.bytes(f.size)
        took.stringValue = f.seconds.map { L("用时 ", "took ") + Format.duration(max(1, $0)) } ?? ""
        if let s = f.seconds, s > 0.05, f.ok { speed.stringValue = Format.speed(Double(f.size) / s) } else { speed.stringValue = f.ok ? "" : L("将重试", "will retry") }
        speed.textColor = f.ok ? .secondaryLabelColor : Theme.warning
        when.stringValue = Format.ago(f.completedAt)
    }
}

/// 列表表头（和行的列宽对齐）
private func fileListHeader(_ cols: [(String, CGFloat?, NSTextAlignment)]) -> NSView {
    var views: [NSView] = []
    let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
    spacer.widthAnchor.constraint(equalToConstant: 18).isActive = true
    views.append(spacer)
    for (text, w, align) in cols {
        if let w {
            let l = fixedLabel(w, color: .tertiaryLabelColor, align: align); l.font = .systemFont(ofSize: 10.5, weight: .medium); l.stringValue = text
            views.append(l)
        } else {
            let l = makeLabel(text, color: .tertiaryLabelColor); l.font = .systemFont(ofSize: 10.5, weight: .medium)
            l.setContentHuggingPriority(.defaultLow, for: .horizontal)
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(l)
        }
    }
    let h = hstack(views, spacing: 10)
    h.distribution = .fill
    return h
}

// MARK: - 实时监控卡片

@MainActor
final class LiveTelemetryCard: CardBox {
    private let pulse = PulseDot()
    private let headTitle = makeLabel(L("实时监控", "Live monitor"))
    private let headDetail = makeLabel("", color: .secondaryLabelColor)
    private let recTag = osdLabel("STBY")
    private let tcTag = osdLabel("TC --:--:--")
    private let windowSeg = NSSegmentedControl(labels: [L("1 分钟", "1 min"), L("5 分钟", "5 min")], trackingMode: .selectOne, target: nil, action: nil)

    private let speedBig = makeLabel("—")
    private let speedBits = makeLabel("", color: .secondaryLabelColor)
    private let avgValue = fixedLabel(96, color: .labelColor, align: .left)
    private let peakValue = fixedLabel(96, color: .labelColor, align: .left)
    private let connValue = fixedLabel(96, color: .labelColor, align: .left)
    private let elapsedValue = fixedLabel(96, color: .labelColor, align: .left)
    private let chart = ThroughputChartView()

    private let pctValue = makeLabel("—"), pctBar = GradientProgressBar(), pctDetail = makeLabel("", color: .secondaryLabelColor)
    private let bytesValue = makeLabel("—"), bytesDetail = makeLabel("", color: .secondaryLabelColor)
    private let filesValue = makeLabel("—"), filesDetail = makeLabel("", color: .secondaryLabelColor)
    private let etaValue = makeLabel("—"), etaDetail = makeLabel("", color: .secondaryLabelColor)
    private let todayValue = makeLabel("—"), todayBar = GradientProgressBar(), todayDetail = makeLabel("", color: .secondaryLabelColor)

    private var liveSection: NSStackView!
    private let liveCount = Pill("0", tint: Theme.accent)
    private let liveStack = NSStackView()
    private var liveRows: [LiveFileRow] = []
    private let liveMore = makeLabel("", color: .tertiaryLabelColor)

    private var doneSection: NSStackView!
    private let doneCount = Pill("0", tint: .secondaryLabelColor)
    private let doneErrors = Pill("", tint: Theme.warning, symbol: "exclamationmark.triangle.fill")
    private let doneStack = NSStackView()
    private var doneRows: [DoneFileRow] = []
    private var doneExpanded = false
    private lazy var doneToggle: CFButton = CFButton(L("显示更多", "Show more"), style: .plain, size: .small) { [weak self] in
        guard let self else { return }
        doneExpanded.toggle(); doneToggle.setTitle(doneExpanded ? L("收起", "Show less") : L("显示更多", "Show more")); onLayoutChange?()
    }
    var onLayoutChange: (() -> Void)?
    private weak var engine: QueueEngine?

    init() {
        super.init(title: nil)
        stack.spacing = 16
        windowSeg.selectedSegment = UserDefaults.standard.integer(forKey: "cf.chartWindow") == 1 ? 1 : 0
        windowSeg.controlSize = .small
        windowSeg.selectedSegmentBezelColor = Theme.accent
        windowSeg.target = self; windowSeg.action = #selector(windowChanged)
        chart.windowSize = windowSeg.selectedSegment == 1 ? 300 : 60

        headTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        headDetail.font = Typo.caption; headDetail.lineBreakMode = .byTruncatingTail
        headDetail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let head = hstack([pulse, recTag, headTitle, headDetail, flexibleSpacer(), tcTag, windowSeg], spacing: 8)
        head.setCustomSpacing(6, after: pulse); head.setCustomSpacing(12, after: recTag); head.setCustomSpacing(14, after: tcTag)
        addRow(head)

        // 左：大号速度 + 小指标；右：曲线
        speedBig.font = NSFont.monospacedSystemFont(ofSize: 29, weight: .semibold)
        speedBits.font = Typo.number(13, .medium)
        func kv(_ k: String, _ v: NSTextField) -> NSView {
            let kl = makeLabel(k, color: .tertiaryLabelColor); kl.font = .systemFont(ofSize: 11, weight: .medium)
            kl.translatesAutoresizingMaskIntoConstraints = false
            kl.widthAnchor.constraint(equalToConstant: 44).isActive = true
            return hstack([kl, v], spacing: 6)
        }
        let left = vstack([speedBig, speedBits,
                           vstack([kv(L("平均", "Avg"), avgValue), kv(L("峰值", "Peak"), peakValue),
                                   kv(L("连接", "Conns"), connValue), kv(L("已运行", "Running"), elapsedValue)], spacing: 5)],
                          spacing: 4)
        left.setCustomSpacing(14, after: speedBits)
        left.translatesAutoresizingMaskIntoConstraints = false
        left.widthAnchor.constraint(equalToConstant: 214).isActive = true
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 156).isActive = true
        chart.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addRow(hstack([left, chart], spacing: 20, alignment: .top))

        // 5 个指标
        for b in [pctBar, todayBar] { b.barHeight = 6; b.segmented = true; b.translatesAutoresizingMaskIntoConstraints = false }
        for v in [pctValue, bytesValue, filesValue, etaValue, todayValue] { v.font = Typo.metric(17); v.lineBreakMode = .byTruncatingTail }
        for d in [pctDetail, bytesDetail, filesDetail, etaDetail, todayDetail] { d.font = Typo.caption; d.lineBreakMode = .byTruncatingTail }
        let tiles: [NSStackView] = [
            metricBlock(title: L("总进度", "Progress"), value: pctValue, detail: vstack([pctBar, pctDetail], spacing: 5)),
            metricBlock(title: L("已传输", "Transferred"), value: bytesValue, detail: bytesDetail),
            metricBlock(title: L("文件", "Files"), value: filesValue, detail: filesDetail),
            metricBlock(title: L("预计剩余", "Time left"), value: etaValue, detail: etaDetail),
            metricBlock(title: L("今日已上传", "Uploaded today"), value: todayValue, detail: vstack([todayBar, todayDetail], spacing: 5)),
        ]
        var row: [NSView] = []
        for (i, t) in tiles.enumerated() {
            if i > 0 {
                let sep = HairlineView(); sep.translatesAutoresizingMaskIntoConstraints = false
                sep.removeConstraints(sep.constraints)
                sep.widthAnchor.constraint(equalToConstant: 1).isActive = true
                row.append(sep)
            }
            row.append(t)
        }
        let tilesRow = hstack(row, spacing: 14, alignment: .top)
        for (i, t) in tiles.enumerated() where i > 0 { t.widthAnchor.constraint(equalTo: tiles[0].widthAnchor).isActive = true }
        for v in row where v is HairlineView { v.heightAnchor.constraint(equalTo: tilesRow.heightAnchor).isActive = true }
        for t in tiles { for sub in t.arrangedSubviews.dropFirst(2) { sub.widthAnchor.constraint(equalTo: t.widthAnchor).isActive = true } }
        let tilesBox = themedBox(fill: Theme.contentBackground.withAlphaComponent(0.7), radius: 10, border: 0)
        tilesBox.chamfer = 9
        tilesRow.translatesAutoresizingMaskIntoConstraints = false
        tilesBox.addSubview(tilesRow)
        NSLayoutConstraint.activate([
            tilesRow.topAnchor.constraint(equalTo: tilesBox.topAnchor, constant: 12),
            tilesRow.bottomAnchor.constraint(equalTo: tilesBox.bottomAnchor, constant: -12),
            tilesRow.leadingAnchor.constraint(equalTo: tilesBox.leadingAnchor, constant: 14),
            tilesRow.trailingAnchor.constraint(equalTo: tilesBox.trailingAnchor, constant: -14),
        ])
        addRow(tilesBox)

        // 正在传输的文件
        liveStack.orientation = .vertical; liveStack.alignment = .leading; liveStack.spacing = 0
        let liveTitle = makeLabel(L("正在传输", "Transferring now")); liveTitle.font = .systemFont(ofSize: 12.5, weight: .semibold)
        liveMore.font = Typo.caption
        let liveHeader = hstack([liveTitle, liveCount, flexibleSpacer(), liveMore], spacing: 8)
        let liveCols = fileListHeader([(L("文件", "File"), nil, .left), (L("已传 / 大小", "Done / size"), Col.size, .right),
                                       (L("进度", "Progress"), Col.bar, .left), ("", Col.pct, .right),
                                       (L("速度", "Speed"), Col.speed, .right), (L("剩余", "Left"), Col.tail, .right)])
        liveSection = vstack([liveHeader, liveCols, liveStack], spacing: 6)
        for v in [liveHeader, liveCols, liveStack] as [NSView] { v.widthAnchor.constraint(equalTo: liveSection.widthAnchor).isActive = true }
        addRow(liveSection)

        // 刚完成的文件
        doneStack.orientation = .vertical; doneStack.alignment = .leading; doneStack.spacing = 0
        let doneTitle = makeLabel(L("刚完成", "Just finished")); doneTitle.font = .systemFont(ofSize: 12.5, weight: .semibold)
        doneErrors.toolTip = L("这些文件这一轮没传成功，rclone 会自动重试；还不行的话任务会标成失败，可以一键重试。",
                               "These files failed this round; rclone retries them automatically. If they still fail, the task is marked failed and you can retry.")
        let doneHeader = hstack([doneTitle, doneCount, doneErrors, flexibleSpacer(), doneToggle], spacing: 8)
        doneSection = vstack([doneHeader, doneStack], spacing: 6)
        for v in [doneHeader, doneStack] as [NSView] { v.widthAnchor.constraint(equalTo: doneSection.widthAnchor).isActive = true }
        addRow(doneSection)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func windowChanged() {
        UserDefaults.standard.set(windowSeg.selectedSegment, forKey: "cf.chartWindow")
        chart.windowSize = windowSeg.selectedSegment == 1 ? 300 : 60
    }

    /// 有正在传的任务才算「活跃」；没有时只显示今日/本次的汇总
    func update(_ engine: QueueEngine) {
        self.engine = engine
        let active = engine.activeJob
        let isLive = active != nil
        pulse.active = isLive
        recTag.attributedStringValue = osdString(isLive ? "REC" : (engine.globalPaused ? "PAUSE" : "STBY"),
                                                 color: isLive ? Theme.rec : .tertiaryLabelColor)
        tcTag.attributedStringValue = osdString("TC " + Format.timecode(isLive ? engine.liveElapsed : nil),
                                                color: isLive ? .secondaryLabelColor : .tertiaryLabelColor)
        chart.live = isLive
        chart.values = engine.speedHistory

        if let j = active {
            headDetail.stringValue = "· " + j.sourceLabel + "  →  " + j.destLabel
            speedBig.stringValue = Format.speed(j.speed)
            speedBig.textColor = Theme.accent
            speedBits.stringValue = "≈ " + Format.bits(j.speed)
            let nz = engine.speedHistory.suffix(chart.windowSize).filter { $0 > 0 }
            avgValue.stringValue = nz.isEmpty ? "—" : Format.speed(nz.reduce(0, +) / Double(nz.count))
            peakValue.stringValue = Format.speed(max(engine.peakSpeed, j.speed, engine.speedHistory.max() ?? 0))
            connValue.stringValue = "\(engine.liveFiles.count) / \(j.settings.transfers)"
            connValue.toolTip = L("正在同时传的文件数 / 设置里的并发上限", "Files moving right now / concurrency limit in Settings")
            elapsedValue.stringValue = Format.timecode(engine.liveElapsed)

            let pct = j.hasSizeInfo ? Int(j.progress * 100) : 0
            pctValue.stringValue = j.hasSizeInfo ? "\(pct)%" : L("扫描中", "Scanning")
            pctBar.progress = j.hasSizeInfo ? j.progress : 0
            pctDetail.stringValue = j.direction == .download ? L("下载", "Download") : L("上传到网盘", "Upload")
            bytesValue.stringValue = Format.bytes(j.bytes)
            bytesDetail.stringValue = j.totalBytes > 0 ? L("共 ", "of ") + Format.bytes(j.totalBytes) : L("正在统计总量…", "Counting total…")
            filesValue.stringValue = "\(j.transfersDone) / \(max(j.totalTransfers, j.transfersDone))"
            var fd: [String] = []
            if j.checks > 0 { fd.append(L("已核对 \(j.checks)", "\(j.checks) checked")) }
            if j.errorsCount > 0 { fd.append(L("出错 \(j.errorsCount)", "\(j.errorsCount) errors")) }
            filesDetail.stringValue = fd.isEmpty ? L("已完成 / 总数", "done / total") : fd.joined(separator: " · ")
            filesDetail.textColor = j.errorsCount > 0 ? Theme.warning : .secondaryLabelColor
            etaValue.stringValue = Format.timecode(j.etaSeconds)
            etaValue.toolTip = Format.remaining(j.etaSeconds)
            etaDetail.stringValue = j.etaSeconds.map { L("约 ", "≈ ") + Format.clock(Date().addingTimeInterval(Double($0))) + L(" 完成", " finish") } ?? L("速度稳定后估算", "Estimating…")
        } else {
            headDetail.stringValue = engine.globalPaused ? L("· 已全部暂停", "· All paused") : L("· 当前没有任务在传", "· Nothing transferring")
            speedBig.stringValue = "—"
            speedBig.textColor = .tertiaryLabelColor
            speedBits.stringValue = L("空闲", "Idle")
            let nz = engine.speedHistory.filter { $0 > 0 }
            avgValue.stringValue = nz.isEmpty ? "—" : Format.speed(nz.reduce(0, +) / Double(nz.count))
            peakValue.stringValue = engine.peakSpeed > 0 ? Format.speed(engine.peakSpeed) : "—"
            connValue.stringValue = "0"
            elapsedValue.stringValue = "--:--:--"
            pctValue.stringValue = "—"; pctBar.progress = 0; pctDetail.stringValue = L("排队 \(engine.queuedCount) 个", "\(engine.queuedCount) queued")
            bytesValue.stringValue = Format.bytes(engine.sessionBytes); bytesDetail.stringValue = L("本次打开 App 以来", "Since app launch")
            let doneJobs = engine.jobs.filter { $0.status == .completed }.count
            filesValue.stringValue = "\(doneJobs)"; filesDetail.stringValue = L("个任务已完成", "tasks done"); filesDetail.textColor = .secondaryLabelColor
            etaValue.stringValue = "--:--:--"; etaDetail.stringValue = ""
        }
        let today = engine.todayUploaded
        todayValue.stringValue = Format.bytes(today)
        todayValue.textColor = today > 650_000_000_000 ? Theme.warning : .labelColor
        todayBar.progress = min(1, Double(today) / 750_000_000_000)
        let left = max(0, 750_000_000_000 - today)
        todayDetail.stringValue = L("今天还能传 ", "") + Format.bytes(left) + L("", " left today")
        let capTip = L("Google Drive 每个账号每天约 750GB 上传上限。到了上限 App 会自动暂停，第二天续传。",
                       "Google Drive allows ~750GB of uploads per account per day. The app pauses at the cap and resumes next day.")
        todayValue.toolTip = capTip; todayDetail.toolTip = capTip

        // 正在传的文件（最多 8 行，行视图复用，避免闪烁）
        let files = isLive ? engine.liveFiles : []
        liveSection.isHidden = files.isEmpty
        let shown = Array(files.prefix(8))
        while liveRows.count < shown.count { let r = LiveFileRow(); liveRows.append(r) }
        for (i, r) in liveRows.enumerated() {
            if i < shown.count {
                if r.superview == nil { liveStack.addArrangedSubview(r); r.widthAnchor.constraint(equalTo: liveStack.widthAnchor).isActive = true }
                r.show(shown[i]); r.isHidden = false
            } else { r.isHidden = true }
        }
        liveCount.setText("\(files.count)")
        liveMore.stringValue = files.count > 8 ? L("还有 \(files.count - 8) 个", "+\(files.count - 8) more") : ""

        // 刚完成的文件（默认 5 行，展开 20 行）
        let done = engine.recentDone
        doneSection.isHidden = done.isEmpty
        let limit = doneExpanded ? 20 : 5
        let dshown = Array(done.prefix(limit))
        while doneRows.count < dshown.count { doneRows.append(DoneFileRow()) }
        for (i, r) in doneRows.enumerated() {
            if i < dshown.count {
                if r.superview == nil { doneStack.addArrangedSubview(r); r.widthAnchor.constraint(equalTo: doneStack.widthAnchor).isActive = true }
                r.show(dshown[i]); r.isHidden = false
            } else { r.isHidden = true }
        }
        doneCount.setText("\(done.count)")
        let errs = done.filter { !$0.ok }.count
        doneErrors.isHidden = errs == 0
        doneErrors.setText(L("\(errs) 个出错", "\(errs) failed"))
        doneToggle.isHidden = done.count <= 5
    }
}
