import AppKit

@MainActor
final class NewTransferSheetVC: NSViewController {
    let engine: QueueEngine
    private let directions: [TransferDirection] = [.upload, .download, .remote, .local]
    private let directionPopup = NSPopUpButton()
    private let srcRemote = NSPopUpButton()
    private let srcPath = NSTextField(string: "")
    private let srcLocal = NSTextField(string: "")
    private let dstRemote = NSPopUpButton()
    private let dstPath = NSTextField(string: "CardBackup")
    private let dstLocal = NSTextField(string: "")
    private let presetPopup = NSPopUpButton()
    private let srcContainer = NSStackView()
    private let dstContainer = NSStackView()

    init(engine: QueueEngine) { self.engine = engine; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    private var direction: TransferDirection { directions[directionPopup.indexOfSelectedItem] }
    private var sourceIsRemote: Bool { direction == .download || direction == .remote }
    private var destIsRemote: Bool { direction == .upload || direction == .remote }

    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420)) }

    override func viewDidLoad() {
        super.viewDidLoad()
        let title = makeLabel(L("新建传输任务", "New transfer"), size: 18, weight: .bold)

        directionPopup.addItems(withTitles: [
            L("上传备份（本机 → 网盘）", "Upload (Mac → cloud)"),
            L("下载（网盘 → 本机）", "Download (cloud → Mac)"),
            L("网盘互传（网盘 → 网盘）", "Cloud → cloud"),
            L("本地拷贝（本机 → 本机）", "Local copy (Mac → Mac)")])
        directionPopup.onAction { [weak self] in self?.rebuildEndpoints() }

        for p in [srcRemote, dstRemote] {
            p.removeAllItems()
            p.addItems(withTitles: engine.remotes.map { "\($0.name) · \($0.typeLabel)" })
        }
        if let d = engine.defaultDestRemote, let i = engine.remotes.firstIndex(where: { $0.name == d }) {
            dstRemote.selectItem(at: i)
        }
        let pathPH = L("路径，如 CardBackup/2026（留空为根目录）", "Path, e.g. CardBackup/2026 (blank = root)")
        srcPath.placeholderString = pathPH
        dstPath.placeholderString = pathPH
        srcLocal.placeholderString = L("本机路径", "Local path")
        dstLocal.placeholderString = L("本机路径", "Local path")

        srcContainer.orientation = .vertical; srcContainer.alignment = .leading; srcContainer.spacing = 6
        dstContainer.orientation = .vertical; dstContainer.alignment = .leading; dstContainer.spacing = 6

        presetPopup.addItems(withTitles: Preset.all.map { $0.name })
        if let i = Preset.all.firstIndex(where: { $0.id == engine.selectedPresetID }) { presetPopup.selectItem(at: i) }
        presetPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true
        presetPopup.onAction { [weak self] in
            guard let self else { return }
            engine.applyPreset(Preset.all[presetPopup.indexOfSelectedItem])
        }
        let presetRow = hstack([makeLabel(L("传输参数预设", "Transfer preset"), size: 13, weight: .medium), presetPopup, flexibleSpacer()])

        let cancel = CFButton(L("取消", "Cancel"), style: .secondary)
        cancel.keyEquivalent = "\u{1b}"
        cancel.onAction { [weak self] in self.map { $0.dismiss($0) } }
        let addBtn = CFButton(L("添加到队列", "Add to queue"), style: .primary)
        addBtn.keyEquivalent = "\r"
        addBtn.onAction { [weak self] in self?.add() }
        let buttons = hstack([flexibleSpacer(), cancel, addBtn])

        let stack = vstack([title,
                            labeled(L("方向", "Direction"), directionPopup),
                            divider(),
                            makeLabel(L("来源", "Source"), size: 13, weight: .semibold), srcContainer,
                            makeLabel(L("目的地", "Destination"), size: 13, weight: .semibold), dstContainer,
                            divider(), presetRow, buttons], spacing: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])
        for v in [srcContainer, dstContainer, presetRow, buttons] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        rebuildEndpoints()
    }

    private func labeled(_ text: String, _ control: NSView) -> NSView {
        hstack([makeLabel(text, size: 13, weight: .medium), control, flexibleSpacer()])
    }

    private func rebuildEndpoints() {
        srcContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        dstContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        srcContainer.addArrangedSubview(endpoint(isRemote: sourceIsRemote, remote: srcRemote, path: srcPath, local: srcLocal))
        dstContainer.addArrangedSubview(endpoint(isRemote: destIsRemote, remote: dstRemote, path: dstPath, local: dstLocal))
    }

    private func endpoint(isRemote: Bool, remote: NSPopUpButton, path: NSTextField, local: NSTextField) -> NSView {
        if isRemote {
            remote.widthAnchor.constraint(equalToConstant: 200).isActive = true
            let row = hstack([remote, makeLabel(":", color: .secondaryLabelColor), path])
            path.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return row
        } else {
            let browse = CFButton(L("选择…", "Choose…"), style: .secondary, size: .small)
            browse.onAction {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let u = panel.urls.first { local.stringValue = u.path }
            }
            local.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return hstack([local, browse])
        }
    }

    private func add() {
        let srcName = engine.remotes[safe: srcRemote.indexOfSelectedItem]?.name ?? ""
        let dstName = engine.remotes[safe: dstRemote.indexOfSelectedItem]?.name ?? ""
        let sourceFs = sourceIsRemote ? "\(srcName):\(srcPath.stringValue)" : srcLocal.stringValue
        let destFs = destIsRemote ? "\(dstName):\(dstPath.stringValue)" : dstLocal.stringValue
        if (sourceIsRemote ? srcName.isEmpty : srcLocal.stringValue.isEmpty)
            || (destIsRemote ? dstName.isEmpty : dstLocal.stringValue.isEmpty) {
            let a = NSAlert(); a.messageText = L("请填写来源和目的地", "Please fill in source and destination"); a.runModal(); return
        }
        let srcLabel = sourceIsRemote ? "\(srcName): \(srcPath.stringValue)" : URL(fileURLWithPath: srcLocal.stringValue).lastPathComponent
        let dstLabel = destIsRemote ? "\(dstName): \(dstPath.stringValue)" : URL(fileURLWithPath: dstLocal.stringValue).lastPathComponent
        engine.addJob(sourceFs: sourceFs, sourceLabel: srcLabel, destFs: destFs, destLabel: dstLabel, direction: direction)
        dismiss(self)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
