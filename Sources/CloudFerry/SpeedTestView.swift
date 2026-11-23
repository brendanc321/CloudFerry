import AppKit
import Combine

@MainActor
final class SpeedTestVC: NSViewController, Refreshable {
    let engine: QueueEngine
    private let tester = SpeedTester()
    private var content: NSStackView!
    private let targetPopup = NSPopUpButton()
    private let downloadCheck = NSButton(checkboxWithTitle: L("同时测下载", "Also test download"), target: nil, action: nil)
    private let runButton = CFButton(L("开始测速", "Start test"), style: .primary, symbol: "play.fill")
    private let statusLabel = makeLabel("", color: .secondaryLabelColor)
    private let resultBox = NSStackView()
    private var cancellables = Set<AnyCancellable>()

    init(engine: QueueEngine) { self.engine = engine; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() { let (s, c) = makeVScroll(); content = c; view = s }

    override func viewDidLoad() {
        super.viewDidLoad()
        add(pageHeader(L("测速与推荐", "Speed test & tuning"),
                       subtitleText: L("实测你到网盘的真实速度，并据此推荐全部参数，每条都说明原因。",
                                       "Measure your real speed to the cloud and get every setting recommended, with reasons.")))
        content.setCustomSpacing(24, after: content.arrangedSubviews.last!)

        let card = CardBox(title: nil)
        targetPopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        downloadCheck.state = .on
        runButton.onAction { [weak self] in self?.run() }
        let lbl = makeLabel(L("目标网盘", "Remote"), color: .secondaryLabelColor); lbl.font = Typo.rowTitle
        let row = hstack([lbl, targetPopup, downloadCheck, flexibleSpacer(), runButton], spacing: 12)
        card.addRow(row)
        card.addRow(captionLabel(L("用你当前的上传设置（分片大小等）实测到 Google Drive 的稳定速度，比通用测速更准。会传约 1–1.5 GB、约 30–50 秒，跳过开头加速期取稳定值；结束后彻底删除，不进回收站，不碰你的资料。",
                                   "Measures your sustained speed to Google Drive with your current upload settings — more accurate than a generic speed test. Moves ~1–1.5 GB over ~30–50 s, skips the ramp-up, then deletes everything (not left in Trash). Your files are never touched."),
                                 maxWidth: 680))
        statusLabel.font = Typo.caption
        card.addRow(statusLabel)
        add(card)

        resultBox.orientation = .vertical; resultBox.alignment = .leading; resultBox.spacing = 16
        add(resultBox)

        tester.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.refreshResults() }.store(in: &cancellables)
        engine.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.syncTargets() }.store(in: &cancellables)
        syncTargets()
        refreshResults()
    }
    func refreshOnShow() { syncTargets() }
    private func add(_ v: NSView) { content.addArrangedSubview(v); pinWidth(v, to: content) }

    private func syncTargets() {
        let current = targetPopup.titleOfSelectedItem
        targetPopup.removeAllItems()
        targetPopup.addItems(withTitles: engine.remotes.map { "\($0.name) · \($0.typeLabel)" })
        if let current, targetPopup.itemTitles.contains(current) { targetPopup.selectItem(withTitle: current) }
        else if let d = engine.defaultDestRemote, let i = engine.remotes.firstIndex(where: { $0.name == d }) { targetPopup.selectItem(at: i) }
        runButton.isEnabled = !engine.remotes.isEmpty && engine.ready && !tester.running
    }

    private func run() {
        guard let r = engine.remotes[safe: targetPopup.indexOfSelectedItem] else { return }
        Task { await engine.runSpeedTest(tester, remoteName: r.name, includeDownload: downloadCheck.state == .on) }
    }

    private func refreshResults() {
        statusLabel.stringValue = tester.running ? tester.phaseText : (tester.error.map { "✕ " + $0 } ?? "")
        statusLabel.textColor = tester.error != nil && !tester.running ? .systemRed : .secondaryLabelColor
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
        runButton.isEnabled = !tester.running && !engine.remotes.isEmpty
        runButton.setTitle(tester.running ? L("测速中…", "Testing…") : L("开始测速", "Start test"))

        resultBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard tester.phase == .done, let res = tester.result else {
            if !tester.running {
                let e = makeEmptyState(icon: "speedometer",
                    title: L("还没测过速", "No test yet"),
                    subtitle: L("点上面「开始测速」，测你到网盘的真实稳定速度，并一键推荐参数。",
                               "Run a test to measure your real sustained speed to the cloud and get one-click tuning."))
                resultBox.addArrangedSubview(e); pinWidth(e, to: resultBox)
            }
            return
        }

        let header = sectionHeader(L("实测结果", "Results"), detail: Format.relative(res.ranAt))
        resultBox.addArrangedSubview(header); pinWidth(header, to: resultBox)
        let card = CardBox(title: nil)
        func mv(_ t: String, _ v: String, _ d: String, accent: Bool = false) -> NSStackView {
            let val = makeLabel(v, color: accent ? Theme.accent : .labelColor, mono: true)
            let det = makeLabel(d, color: .secondaryLabelColor); det.font = Typo.caption
            return metricBlock(title: t, value: val, detail: det)
        }
        var blocks = [mv(L("上传", "Upload"), String(format: "%.1f MB/s", res.uploadMBps), String(format: "≈ %.0f Mbps", res.uploadMBps * 8), accent: true)]
        if downloadCheck.state == .on { blocks.append(mv(L("下载", "Download"), String(format: "%.1f MB/s", res.downloadMBps), String(format: "≈ %.0f Mbps", res.downloadMBps * 8))) }
        let gbPerHour = res.uploadMBps * 3600 / 1000
        blocks.append(mv(L("一小时大约能传", "Per hour, roughly"), String(format: "%.0f GB", gbPerHour), L("按上传速度估算", "at the upload speed")))
        let row = hstack(blocks, spacing: 40, alignment: .top)
        card.addRow(hstack([row, flexibleSpacer()]))
        resultBox.addArrangedSubview(card); pinWidth(card, to: resultBox)

        let apply = CFButton(L("应用推荐设置", "Apply recommended"), style: .primary, symbol: "wand.and.stars") { [weak self] in
            if let s = self?.tester.recommendedSettings { self?.engine.applyRecommended(s) }
        }
        let recHeader = sectionHeader(L("推荐参数", "Recommended settings"), detail: L("只是建议，可到「上传设置」微调", "suggestions — fine-tune in Settings"), trailing: [apply])
        resultBox.addArrangedSubview(recHeader); pinWidth(recHeader, to: resultBox)
        resultBox.setCustomSpacing(12, after: recHeader)
        let rec = CardBox(title: nil)
        for (i, r) in tester.recommendations.enumerated() {
            if i > 0 { rec.addDivider() }
            let value = makeLabel(r.value, color: Theme.accent, mono: true); value.font = Typo.number(14, .semibold)
            rec.addRow(captionedRow(title: r.title, caption: r.reason, control: value))
        }
        resultBox.addArrangedSubview(rec); pinWidth(rec, to: resultBox)
    }

}
