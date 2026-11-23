import AppKit

struct PaletteCommand {
    let title: String
    let subtitle: String
    let symbol: String
    let run: () -> Void
}

enum CommandPalette {
    @MainActor
    static func present(in root: RootSplitVC, engine: QueueEngine) {
        let vc = CommandPaletteVC(commands: commands(root: root, engine: engine))
        root.presentAsSheet(vc)
    }

    @MainActor
    private static func commands(root: RootSplitVC, engine: QueueEngine) -> [PaletteCommand] {
        var cmds: [PaletteCommand] = []
        for s in AppSection.allCases {
            cmds.append(PaletteCommand(title: s.title, subtitle: L("切换到", "Go to"), symbol: s.icon) { root.selectSection(s) })
        }
        cmds += [
            PaletteCommand(title: L("新建任务", "New Transfer"), subtitle: L("上传 / 下载 / 互传", "upload / download / cloud→cloud"), symbol: "plus.circle") { root.newTransfer() },
            PaletteCommand(title: L("连接 Google Drive", "Connect Google Drive"), subtitle: L("一键授权", "one-click auth"), symbol: "person.badge.key") { root.connectDrive() },
            PaletteCommand(title: L("换成我自己的 Google 通道", "Use my own Google client"), subtitle: L("client_id 设置向导", "client_id setup wizard"), symbol: "key.horizontal") { root.openClientSetup() },
            PaletteCommand(title: L("刷新当前", "Refresh"), subtitle: "", symbol: "arrow.clockwise") { root.refreshCurrent() },
            PaletteCommand(title: engine.globalPaused ? L("全部继续", "Resume all") : L("全部暂停", "Pause all"), subtitle: "", symbol: "playpause") { engine.globalPaused ? engine.resumeAll() : engine.pauseAll() },
            PaletteCommand(title: L("清除已完成", "Clear finished"), subtitle: L("历史记录里仍保留", "kept in History"), symbol: "trash") { engine.clearFinished() },
            PaletteCommand(title: L("备份全部外接盘", "Back up all external drives"), subtitle: L("到默认网盘", "to the default remote"), symbol: "externaldrive.badge.plus") {
                if engine.defaultDestRemote != nil { engine.backupAllExternal() } else { root.connectDrive() }
            },
            PaletteCommand(title: L("切换语言 中 / EN", "Toggle language 中 / EN"), subtitle: "", symbol: "globe") { Loc.toggle() },
        ] + AppTheme.allCases.map { t in
            PaletteCommand(title: L("外观：", "Appearance: ") + t.title, subtitle: AppTheme.current == t ? L("当前", "current") : "", symbol: t.symbol) { AppTheme.current = t }
        } + [
            PaletteCommand(title: L("关于 CloudFerry", "About CloudFerry"), subtitle: "v" + AppInfo.version, symbol: "info.circle") { NSApp.orderFrontStandardAboutPanel(nil); NSApp.activate(ignoringOtherApps: true) },
        ]
        return cmds
    }
}

@MainActor
final class CommandPaletteVC: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let all: [PaletteCommand]
    private var filtered: [PaletteCommand]
    private let field = NSSearchField()
    private let table = NSTableView()

    init(commands: [PaletteCommand]) { self.all = commands; self.filtered = commands; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = ThemedBox(frame: NSRect(x: 0, y: 0, width: 580, height: 420))
        v.fillColor = Theme.terminalBG
        v.boxRadius = 14
        v.strokeColor = Theme.hairline
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let prompt = makeLabel("⌘K", size: 12, weight: .bold, color: Theme.accent, mono: true)
        field.placeholderString = L("输入命令或页面…", "Type a command or page…")
        field.delegate = self
        field.font = .systemFont(ofSize: 15)
        field.focusRingType = .none
        field.target = self; field.action = #selector(searchChanged)
        (field.cell as? NSSearchFieldCell)?.sendsWholeSearchString = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 44
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(runSelected)
        let col = NSTableColumn(identifier: .init("c")); col.width = 540
        table.addTableColumn(col)
        scroll.documentView = table

        let head = hstack([prompt, field], spacing: 10)
        let stack = NSStackView(views: [head, scroll])
        stack.orientation = .vertical; stack.spacing = 10; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
            head.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        table.reloadData()
        if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    @objc private func searchChanged() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = q.isEmpty ? all : all.filter { $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q) }
        table.reloadData()
        if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    @objc private func runSelected() {
        let row = table.selectedRow
        guard row >= 0, row < filtered.count else { return }
        let cmd = filtered[row]
        dismiss(self)
        DispatchQueue.main.async { cmd.run() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let c = filtered[row]
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: c.symbol, accessibilityDescription: nil)
        icon.contentTintColor = Theme.accent
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let title = makeLabel(c.title, size: 14, weight: .medium)
        var texts: [NSView] = [title]
        if !c.subtitle.isEmpty { texts.append(makeLabel(c.subtitle, size: 11, color: .secondaryLabelColor)) }
        let col = vstack(texts, spacing: 1)
        let row = hstack([icon, col], spacing: 12)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        return row
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }

    // 键盘：上下移动、回车执行、Esc 关闭
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(1); return true
        case #selector(NSResponder.moveUp(_:)):
            move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            runSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss(self); return true
        default: return false
        }
    }
    private func move(_ d: Int) {
        guard !filtered.isEmpty else { return }
        let cur = table.selectedRow
        let next = max(0, min(filtered.count - 1, (cur < 0 ? 0 : cur) + d))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }
}

final class PaletteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let r = bounds.insetBy(dx: 4, dy: 3)
        let p = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        Theme.accent.withAlphaComponent(0.20).setFill(); p.fill()
    }
}
