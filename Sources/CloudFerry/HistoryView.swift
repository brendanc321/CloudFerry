import AppKit
import Combine
import UniformTypeIdentifiers

/// 历史记录：每一次传输（完成 / 失败 / 取消）都会永久记下来，清除队列也不会丢。
/// 方便回答“这张卡备份过没有？什么时候？传到哪了？校验过没有？”
@MainActor
final class HistoryVC: NSViewController, Refreshable, NSTableViewDataSource, NSTableViewDelegate {
    let engine: QueueEngine
    private let table = NSTableView()
    private let searchField = NSSearchField()
    private let filterPopup = NSPopUpButton()
    private let summary = makeLabel("", color: .secondaryLabelColor)
    private var rows: [TransferJob] = []
    private var cancellables = Set<AnyCancellable>()
    private var lastSig = ""

    private static let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()
    private static let shortFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f }()

    init(engine: QueueEngine) { self.engine = engine; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        filterPopup.addItems(withTitles: [L("全部", "All"), L("上传备份", "Uploads"), L("下载", "Downloads"),
                                          L("失败 / 取消", "Failed / canceled"), L("未校验的上传", "Unverified uploads")])
        filterPopup.onAction { [weak self] in self?.reload() }
        searchField.placeholderString = L("搜索卡名、文件夹、路径…", "Search card, folder, path…")
        searchField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        searchField.target = self; searchField.action = #selector(searchChanged)
        (searchField.cell as? NSSearchFieldCell)?.sendsWholeSearchString = false
        let export = CFButton(L("导出 CSV", "Export CSV"), style: .secondary, symbol: "square.and.arrow.up") { [weak self] in self?.exportCSV() }
        let clear = CFButton(L("清空", "Clear"), style: .danger) { [weak self] in self?.confirmClear() }
        clear.toolTip = L("清空全部历史记录（不会删除网盘里的任何文件）", "Clear all history (never deletes cloud files)")
        let headerTop = pageHeader(L("历史记录", "History"), subtitle: summary, actions: [clear, export])
        filterPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let header = vstack([headerTop, hstack([searchField, filterPopup, flexibleSpacer()], spacing: 8)], spacing: 18)
        headerTop.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        table.style = .plain
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 10, height: 0)
        table.rowHeight = 34
        table.allowsMultipleSelection = true
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(doubleClicked)
        func col(_ id: String, _ t: String, _ w: CGFloat) {
            let c = NSTableColumn(identifier: .init(id)); c.title = t; c.width = w; c.minWidth = 50
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id == "name")
            table.addTableColumn(c)
        }
        col("time", L("完成时间", "Finished"), 92)
        col("name", L("名称", "Name"), 150)
        col("dest", L("位置", "Location"), 180)
        col("size", L("大小", "Size"), 78)
        col("files", L("文件", "Files"), 52)
        col("speed", L("用时 · 平均速度", "Time · avg speed"), 160)
        col("status", L("状态", "Status"), 90)
        table.tableColumn(withIdentifier: .init("time"))?.minWidth = 92
        table.tableColumn(withIdentifier: .init("status"))?.minWidth = 84
        table.sortDescriptors = [NSSortDescriptor(key: "time", ascending: false)]
        for id in ["size", "files"] { table.tableColumn(withIdentifier: .init(id))?.headerCell.alignment = .right }
        applyCleanHeader(table)
        table.menu = NSMenu()
        table.menu?.delegate = self
        scroll.documentView = table

        let tip = makeLabel(L("双击：上传 → 在 Google Drive 网页中打开；下载 → 在访达中显示。右键查看更多（再传一次 / 校验 / 删除记录）。删除记录不会删除网盘里的任何文件。",
                              "Double-click: uploads open in Google Drive; downloads show in Finder. Right-click for more (run again / verify / delete record). Deleting a record never deletes cloud files."),
                            color: .tertiaryLabelColor, multiline: true)
        tip.font = Typo.caption

        let tableCard = CardBox(title: nil)
        tableCard.addRow(scroll)

        let stack = NSStackView(views: [header, tableCard, tip])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Theme.Page.top),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Page.side),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.Page.side),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])
        for v in [header, tableCard, tip] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        tableCard.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        engine.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            guard let self else { return }
            let sig = "\(self.engine.history.count)|\(self.engine.history.first?.id.uuidString ?? "")|\(self.engine.history.filter { $0.verified }.count)|\(self.engine.verifyingJobs.count)"
            if sig != self.lastSig { self.lastSig = sig; self.reload() }
        }.store(in: &cancellables)
        reload()
    }

    func refreshOnShow() { reload() }

    private var fittedWidth: CGFloat = 0
    override func viewDidLayout() {
        super.viewDidLayout()
        // 列宽随窗口宽度自适应，避免右边几列被挤出可视区
        let w = table.enclosingScrollView?.contentView.bounds.width ?? 0
        if w > 0, abs(w - fittedWidth) > 1 { fittedWidth = w; table.sizeToFit() }
    }

    @objc private func searchChanged() { reload() }

    private func reload() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var list = engine.history
        switch filterPopup.indexOfSelectedItem {
        case 1: list = list.filter { $0.direction == .upload }
        case 2: list = list.filter { $0.direction == .download }
        case 3: list = list.filter { $0.status == .failed || $0.status == .canceled }
        case 4: list = list.filter { $0.direction == .upload && $0.status == .completed && !$0.verified }
        default: break
        }
        if !q.isEmpty {
            list = list.filter { j in
                [j.sourceLabel, j.sourceFs, j.destFs, j.volumeName ?? ""].contains { $0.lowercased().contains(q) }
            }
        }
        let sd = table.sortDescriptors.first
        let key = sd?.key ?? "time", asc = sd?.ascending ?? false
        list.sort { a, b in
            let r: Bool
            switch key {
            case "name": r = a.sourceLabel.localizedCaseInsensitiveCompare(b.sourceLabel) == .orderedAscending
            case "size": r = a.doneBytes < b.doneBytes
            case "files": r = a.transfersDone < b.transfersDone
            case "speed": r = (a.averageSpeed ?? 0) < (b.averageSpeed ?? 0)
            case "dir": r = a.direction.rawValue < b.direction.rawValue
            case "dest": r = a.destFs < b.destFs
            case "status": r = a.status.rawValue < b.status.rawValue
            default: r = (a.finishedAt ?? a.createdAt) < (b.finishedAt ?? b.createdAt)
            }
            return asc ? r : !r
        }
        rows = list
        table.reloadData()

        let ups = engine.history.filter { $0.direction == .upload && $0.status == .completed }
        let total = ups.reduce(Int64(0)) { $0 + $1.doneBytes }
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        let week = ups.filter { ($0.finishedAt ?? $0.createdAt) > weekAgo }.reduce(Int64(0)) { $0 + $1.doneBytes }
        let failed = engine.history.filter { $0.status == .failed }.count
        summary.stringValue = L("共 \(engine.history.count) 条 · 累计上传 ", "\(engine.history.count) records · uploaded ") + Format.bytes(total)
            + L(" · 最近 7 天 ", " · last 7 days ") + Format.bytes(week)
            + (failed > 0 ? L(" · \(failed) 次失败", " · \(failed) failed") : "")
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { reload() }

    func tableView(_ tv: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let j = rows[row]
        let id = NSUserInterfaceItemIdentifier("h.cell")
        let cell = (tv.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView(); c.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.font = .systemFont(ofSize: 12); tf.lineBreakMode = .byTruncatingMiddle
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf); c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 3),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -3),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        let tf = cell.textField!
        tf.textColor = .labelColor
        tf.font = .systemFont(ofSize: 12.5)
        tf.alignment = .left
        tf.lineBreakMode = .byTruncatingTail
        switch column?.identifier.rawValue ?? "" {
        case "time":
            tf.stringValue = Self.shortFmt.string(from: j.finishedAt ?? j.createdAt)
            tf.font = Theme.mono(11); tf.textColor = .secondaryLabelColor
        case "name":
            let arrow: String
            switch j.direction { case .upload: arrow = "↑ "; case .download: arrow = "↓ "; case .remote: arrow = "⇄ "; case .local: arrow = "→ " }
            let a = NSMutableAttributedString(string: arrow, attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
            a.append(NSAttributedString(string: j.sourceLabel, attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12.5, weight: .medium)]))
            tf.attributedStringValue = a
        case "dir":
            tf.stringValue = j.direction.label; tf.textColor = .secondaryLabelColor
        case "dest":
            tf.stringValue = j.destFs
            tf.textColor = .secondaryLabelColor
            tf.lineBreakMode = .byTruncatingHead
        case "size":
            tf.stringValue = j.doneBytes > 0 ? Format.bytes(j.doneBytes) : "—"
            tf.font = Theme.mono(11); tf.alignment = .right
        case "files":
            tf.stringValue = j.transfersDone > 0 ? "\(j.transfersDone)" : "—"
            tf.font = Theme.mono(11); tf.alignment = .right
        case "speed":
            var parts: [String] = []
            if let s = j.activeSeconds, s >= 1 { parts.append(Format.duration(s)) }
            if let a = j.averageSpeed { parts.append(Format.speed(a)) }
            tf.stringValue = parts.isEmpty ? "—" : parts.joined(separator: " · ")
            tf.font = Theme.mono(11); tf.textColor = .secondaryLabelColor
        default:
            switch j.status {
            case .completed:
                if engine.verifyingJobs.contains(j.id) { tf.stringValue = L("校验中…", "Verifying…"); tf.textColor = .secondaryLabelColor }
                else if j.verified { tf.stringValue = "✓ " + L("已校验", "Verified"); tf.textColor = .systemGreen }
                else if j.verifyNote != nil { tf.stringValue = "! " + L("校验有差异", "Mismatch"); tf.textColor = .systemOrange }
                else { tf.stringValue = "✓ " + j.direction.doneVerb; tf.textColor = .secondaryLabelColor }
                tf.font = .systemFont(ofSize: 12, weight: .semibold)
            case .failed: tf.stringValue = "✕ " + L("失败", "Failed"); tf.textColor = .systemRed; tf.font = .systemFont(ofSize: 12, weight: .semibold)
            case .canceled: tf.stringValue = L("已取消", "Canceled"); tf.textColor = .secondaryLabelColor
            default: tf.stringValue = j.status.label
            }
        }
        cell.toolTip = [j.direction.label + " · " + Self.timeFmt.string(from: j.finishedAt ?? j.createdAt),
                        j.sourceFs + "  →  " + j.destFs,
                        j.verified && j.direction == .upload ? L("已校验，可放心格式化储存卡", "Verified — safe to format the card") : nil,
                        j.error ?? j.verifyNote].compactMap { $0 }.joined(separator: "\n")
        return cell
    }

    private func selected() -> [TransferJob] {
        var idx = table.selectedRowIndexes
        if table.clickedRow >= 0, !idx.contains(table.clickedRow) { idx = IndexSet(integer: table.clickedRow) }
        return idx.compactMap { $0 < rows.count ? rows[$0] : nil }
    }

    @objc private func doubleClicked() {
        let r = table.clickedRow
        guard r >= 0, r < rows.count else { return }
        open(rows[r])
    }

    private func open(_ j: TransferJob) {
        if j.destIsLocal { JobRowView.reveal(j.destFs) }
        else if engine.isDriveFs(j.destFs) { engine.openInDriveWeb(fs: j.destFs) }
        else if j.sourceIsLocal { JobRowView.reveal(j.sourceFs) }
    }

    private func confirmClear() {
        let a = NSAlert()
        a.messageText = L("清空全部历史记录？", "Clear all history?")
        a.informativeText = L("只清除 CloudFerry 里的记录（包括“这张卡什么时候备份过”的信息），不会删除网盘或电脑上的任何文件。", "Only clears CloudFerry's records (including “when was this card backed up”). No files in the cloud or on your Mac are touched.")
        a.addButton(withTitle: L("清空", "Clear")); a.addButton(withTitle: L("取消", "Cancel"))
        a.alertStyle = .warning
        if a.runModal() == .alertFirstButtonReturn { engine.clearHistory() }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CloudFerry-history-\(QueueEngine.dayKey(Date())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["finished,name,card,direction,source,destination,bytes,files,seconds,avg_MBps,status,verified,note"]
        for j in engine.history {
            let fields: [String] = [
                Self.timeFmt.string(from: j.finishedAt ?? j.createdAt), q(j.sourceLabel), q(j.volumeName ?? ""),
                j.direction.rawValue, q(j.sourceFs), q(j.destFs), "\(j.doneBytes)", "\(j.transfersDone)",
                j.activeSeconds.map { String(Int($0)) } ?? "",
                j.averageSpeed.map { String(format: "%.1f", $0 / 1_000_000) } ?? "",
                j.status.rawValue, j.verified ? "yes" : "no", q(j.error ?? j.verifyNote ?? ""),
            ]
            lines.append(fields.joined(separator: ","))
        }
        // 带 BOM，Excel/Numbers 打开中文不乱码
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(lines.joined(separator: "\n").utf8)
        try? data.write(to: url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension HistoryVC: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let sel = selected()
        guard let first = sel.first else { return }
        let e = engine
        func add(_ title: String, _ symbol: String, _ action: @escaping () -> Void) {
            let it = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
            let a = MenuAction(action); it.target = a; it.representedObject = a
            it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(it)
        }
        if e.isDriveFs(first.destFs) { add(L("在 Google Drive 网页中打开", "Open in Google Drive"), "safari") { e.openInDriveWeb(fs: first.destFs) } }
        if first.destIsLocal { add(L("在访达中显示目的地", "Show destination in Finder"), "folder") { JobRowView.reveal(first.destFs) } }
        if first.sourceIsLocal { add(L("在访达中显示来源", "Show source in Finder"), "folder") { JobRowView.reveal(first.sourceFs) } }
        menu.addItem(.separator())
        add(sel.count > 1 ? L("全部再传一次（\(sel.count) 个，只补传新文件）", "Run all again (\(sel.count), only new files)") : L("再传一次（只补传新文件）", "Run again (only new files)"),
            "arrow.triangle.2.circlepath") { for j in sel { e.rerun(j) } }
        let done = sel.filter { $0.status == .completed }
        if !done.isEmpty {
            add(L("快速核对（文件清单 + 大小）", "Quick check (file list + sizes)"), "checklist") { for j in done { e.verify(j.id, full: false) } }
            add(L("完整校验（逐个哈希，较慢）", "Full verify (hash every file, slower)"), "checkmark.shield") { for j in done { e.verify(j.id, full: true) } }
        }
        add(L("拷贝目的地路径", "Copy destination path"), "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(sel.map { $0.destFs }.joined(separator: "\n"), forType: .string)
        }
        if let err = first.error ?? first.verifyNote {
            add(L("拷贝错误/校验信息", "Copy error / verify note"), "exclamationmark.bubble") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(err, forType: .string)
            }
        }
        menu.addItem(.separator())
        add(L("删除这条记录（不删除任何文件）", "Delete record (no files are deleted)"), "trash") { e.removeHistory(Set(sel.map { $0.id })) }
    }
}
