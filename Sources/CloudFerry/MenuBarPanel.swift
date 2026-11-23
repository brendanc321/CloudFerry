import AppKit

// 菜单栏（v1.3）：单色模板图标（跟随系统明暗）+ 下拉菜单顶部的实时状态面板

enum MenuBarState { case idle, active, paused, failed }

/// 菜单栏图标：和 App 图标同一个「圆环 C + 箭头」，单色模板图（系统自动配黑/白）
@MainActor
func menuBarGlyph(_ state: MenuBarState) -> NSImage? {
    // 打包好的「G + 箭头」模板图（18pt，@2x 像素）；暂停时半透明，失败时菜单栏文字会显示「!」
    if let g = bundledMenuGlyph {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            g.draw(in: rect, from: .zero, operation: .sourceOver, fraction: state == .paused ? 0.45 : 1)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "CloudFerry"
        return img
    }
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        let black = CGColor(gray: 0, alpha: 1)
        let T = rect.width, k: CGFloat = 1.3          // 放大一点填满 18pt
        switch state {
        case .idle, .active:
            drawCRingMark(ctx, origin: .zero, size: T, ring: black, arrow: black, scale: k)
        case .paused:
            drawCRingMark(ctx, origin: .zero, size: T, ring: black, arrow: nil, scale: k)
            ctx.setFillColor(black)
            ctx.fill(CGRect(x: T * 0.36, y: T * 0.34, width: T * 0.1, height: T * 0.32))
            ctx.fill(CGRect(x: T * 0.54, y: T * 0.34, width: T * 0.1, height: T * 0.32))
        case .failed:
            drawCRingMark(ctx, origin: .zero, size: T, ring: black, arrow: nil, scale: k)
            ctx.setFillColor(black)
            ctx.fill(CGRect(x: T * 0.45, y: T * 0.44, width: T * 0.1, height: T * 0.24))
            ctx.fill(CGRect(x: T * 0.45, y: T * 0.30, width: T * 0.1, height: T * 0.09))
        }
        return true
    }
    img.isTemplate = true
    img.accessibilityDescription = "CloudFerry"
    return img
}

@MainActor
final class StatusPanelView: NSView {
    static let width: CGFloat = 312

    private let logo = NSImageView()
    private let appName = makeLabel("CloudFerry")
    private let statusPill = Pill("", tint: .secondaryLabelColor)

    private let route = makeLabel("", color: .secondaryLabelColor)
    private let bar = GradientProgressBar()
    private let pct = makeLabel("—")
    private let bytes = makeLabel("", color: .secondaryLabelColor)
    private let speed = makeLabel("", color: Theme.accent)
    private let eta = makeLabel("", color: .secondaryLabelColor)
    private let bits = makeLabel("", color: .secondaryLabelColor)
    private let spark = ThroughputChartView()
    private let files = makeLabel("", color: .secondaryLabelColor)
    private var activeBox: NSStackView!

    private let idleTitle = makeLabel("", color: .secondaryLabelColor)
    private var idleBox: NSStackView!

    private let todayValue = makeLabel("", color: .secondaryLabelColor)
    private let todayBar = GradientProgressBar()

    private var root: NSStackView!

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        logo.image = makeLogoImage(size: 26)
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 26).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 26).isActive = true
        appName.font = .systemFont(ofSize: 13.5, weight: .semibold)
        let head = hstack([logo, appName, flexibleSpacer(), statusPill], spacing: 9)

        route.font = Typo.caption; route.lineBreakMode = .byTruncatingMiddle
        route.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.barHeight = 6; bar.segmented = true; bar.translatesAutoresizingMaskIntoConstraints = false
        pct.font = Typo.number(12.5, .semibold)
        bytes.font = Typo.number(11.5)
        speed.font = Typo.number(12.5, .semibold)
        eta.font = Typo.caption
        bits.font = Typo.number(11)
        files.font = Typo.caption
        spark.translatesAutoresizingMaskIntoConstraints = false
        spark.heightAnchor.constraint(equalToConstant: 30).isActive = true
        spark.compact = true; spark.windowSize = 60
        let line1 = hstack([pct, bytes, flexibleSpacer(), speed], spacing: 6, alignment: .firstBaseline)
        let line2 = hstack([eta, flexibleSpacer(), bits], spacing: 6, alignment: .firstBaseline)
        activeBox = vstack([route, bar, line1, line2, spark, files], spacing: 6)
        activeBox.setCustomSpacing(9, after: route)
        for v in [route, bar, line1, line2, spark, files] as [NSView] { v.widthAnchor.constraint(equalTo: activeBox.widthAnchor).isActive = true }

        idleTitle.font = Typo.caption
        idleTitle.lineBreakMode = .byWordWrapping; idleTitle.maximumNumberOfLines = 2
        idleBox = vstack([idleTitle], spacing: 4)

        let todayLabel = makeLabel(L("今日已上传", "Uploaded today"), color: .secondaryLabelColor)
        todayLabel.font = Typo.caption
        todayValue.font = Typo.number(11)
        todayBar.barHeight = 4; todayBar.segmented = true; todayBar.translatesAutoresizingMaskIntoConstraints = false
        let todayRow = hstack([todayLabel, flexibleSpacer(), todayValue], spacing: 6)
        let today = vstack([todayRow, todayBar], spacing: 5)
        for v in [todayRow, todayBar] as [NSView] { v.widthAnchor.constraint(equalTo: today.widthAnchor).isActive = true }

        let sep = HairlineView()
        root = vstack([head, activeBox, idleBox, sep, today], spacing: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        for v in [head, activeBox, idleBox, sep, today] as [NSView] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// structural = true 时才切换布局（菜单打开前调用）；打开期间只改数字，避免菜单跳动
    func update(_ engine: QueueEngine, structural: Bool) {
        let job = engine.activeJob
        let failed = engine.jobs.contains { $0.status == .failed }
        if engine.globalPaused {
            statusPill.setText(L("已暂停", "Paused")); statusPill.tint = Theme.warning
        } else if job != nil {
            statusPill.setText(L("传输中", "Transferring")); statusPill.tint = Theme.accent
        } else if failed {
            statusPill.setText(L("有任务失败", "Task failed")); statusPill.tint = Theme.danger
        } else if engine.queuedCount > 0 {
            statusPill.setText(L("排队 \(engine.queuedCount)", "\(engine.queuedCount) queued")); statusPill.tint = .secondaryLabelColor
        } else {
            statusPill.setText(L("空闲", "Idle")); statusPill.tint = .secondaryLabelColor
        }

        if structural {
            activeBox.isHidden = job == nil
            idleBox.isHidden = job != nil
        }
        if let j = job {
            route.stringValue = j.sourceLabel + "  →  " + j.destLabel
            bar.progress = j.hasSizeInfo ? j.progress : 0
            pct.stringValue = j.hasSizeInfo ? "\(Int(j.progress * 100))%" : L("扫描中", "Scanning")
            bytes.stringValue = Format.bytes(j.bytes) + (j.totalBytes > 0 ? " / " + Format.bytes(j.totalBytes) : "")
            speed.stringValue = Format.speed(j.speed)
            bits.stringValue = "≈ " + Format.bits(j.speed)
            if let s = j.etaSeconds, s > 0 {
                eta.stringValue = "ETA " + Format.timecode(s) + L(" · 约 ", " · ≈ ") + Format.clock(Date().addingTimeInterval(Double(s))) + L(" 完成", " done")
            } else { eta.stringValue = L("正在估算剩余时间…", "Estimating time left…") }
            spark.values = engine.speedHistory; spark.live = true
            files.stringValue = L("文件 ", "Files ") + "\(j.transfersDone) / \(max(j.totalTransfers, j.transfersDone))"
                + L(" · \(engine.liveFiles.count) 个连接", " · \(engine.liveFiles.count) connections")
                + (j.errorsCount > 0 ? L(" · 出错 \(j.errorsCount)", " · \(j.errorsCount) errors") : "")
        } else {
            if engine.globalPaused {
                idleTitle.stringValue = L("已全部暂停。点下面的「全部继续」接着传。", "Everything is paused. Click Resume all below to continue.")
            } else if engine.queuedCount > 0 {
                idleTitle.stringValue = L("\(engine.queuedCount) 个任务排队中，马上开始。", "\(engine.queuedCount) task(s) queued; starting soon.")
            } else if let cap = engine.dailyCapUntil {
                idleTitle.stringValue = L("已到 Google 每日上限，", "Daily Google cap reached; resumes ") + Format.relative(cap) + L(" 自动续传。", ".")
            } else {
                idleTitle.stringValue = L("没有正在传的任务。把储存卡拖到 Dock 图标上就能开始备份。", "Nothing transferring. Drop a card on the Dock icon to start a backup.")
            }
        }
        let today = engine.todayUploaded
        todayValue.stringValue = Format.bytes(today) + " / 750 GB"
        todayValue.textColor = today > 650_000_000_000 ? Theme.warning : .secondaryLabelColor
        todayBar.progress = min(1, Double(today) / 750_000_000_000)

        if structural {
            layoutSubtreeIfNeeded()
            let h = root.fittingSize.height + 24
            setFrameSize(NSSize(width: Self.width, height: h))
        }
    }
}
