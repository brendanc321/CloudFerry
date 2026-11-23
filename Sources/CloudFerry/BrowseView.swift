import AppKit
import AVKit
import UniformTypeIdentifiers

// 浏览网盘（v1.3）：像访达一样的网盘文件管理器
//   左：我的网盘 / 与我共享 / 打开过的分享链接
//   上：后退前进、可点击路径、图标/列表、搜索、新建、上传、共享
//   中：缩略图网格或列表；拖进文件夹 = 移动；从访达拖进来 = 上传；拖到访达 = 下载
//   空格 = 快速预览（图片 / 视频在线播放）

extension NSPasteboard.PasteboardType {
    static let cfRemoteItem = NSPasteboard.PasteboardType("com.cloudferry.remote-item")
}

/// App 内拖拽携带的网盘项目
struct DragItem: Codable { let spec: String; let path: String; let name: String; let isDir: Bool; let size: Int64 }

@MainActor enum FileIcons {
    static func icon(for e: RemoteEntry) -> NSImage {
        if e.isDir { return NSWorkspace.shared.icon(for: .folder) }
        if let t = UTType(filenameExtension: e.ext) { return NSWorkspace.shared.icon(for: t) }
        return NSWorkspace.shared.icon(for: .data)
    }
    static func kind(_ e: RemoteEntry) -> String {
        if e.isDir { return L("文件夹", "Folder") }
        if let t = UTType(filenameExtension: e.ext), let d = t.localizedDescription { return d }
        return e.ext.isEmpty ? L("文件", "File") : e.ext.uppercased()
    }
}

/// 拖到访达时用的「文件承诺」，同时带上 App 内移动需要的数据
final class RemotePromiseProvider: NSFilePromiseProvider {
    var payload: Data?
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.cfRemoteItem]
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .cfRemoteItem { return payload }
        return super.pasteboardPropertyList(forType: type)
    }
}

// MARK: - 网格里的一个文件

final class FileTileView: NSView {
    let imageView = NSImageView()
    let nameLabel = NSTextField(wrappingLabelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let durationLabel = NSTextField(labelWithString: "")
    private let durationBG = NSView()
    private let sharedIcon = NSImageView()
    var isSelected = false { didSet { needsDisplay = true; restyle() } }
    var isDropTarget = false { didSet { needsDisplay = true } }
    var hasThumbnail = false { didSet { needsLayout = true; needsDisplay = true } }
    private var thumbRect: NSRect = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        nameLabel.alignment = .center
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.maximumNumberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.cell?.truncatesLastVisibleLine = true
        detailLabel.alignment = .center
        detailLabel.font = Typo.number(10.5)
        detailLabel.textColor = .tertiaryLabelColor
        durationLabel.font = Typo.osd(10, .semibold)
        durationLabel.textColor = .white
        durationBG.wantsLayer = true
        durationBG.layer?.backgroundColor = NSColor(white: 0, alpha: 0.62).cgColor
        durationBG.layer?.cornerRadius = 3
        sharedIcon.image = NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: nil)
        sharedIcon.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        sharedIcon.contentTintColor = .secondaryLabelColor
        for v in [imageView, nameLabel, detailLabel, durationBG, durationLabel, sharedIcon] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func setDuration(_ ms: Int?) {
        if let ms, ms > 0 { durationLabel.stringValue = Format.timecode(Double(ms) / 1000).replacingOccurrences(of: "^00:", with: "", options: .regularExpression) }
        else { durationLabel.stringValue = "" }
        durationLabel.isHidden = durationLabel.stringValue.isEmpty; durationBG.isHidden = durationLabel.isHidden
        needsLayout = true
    }
    func setShared(_ on: Bool) { sharedIcon.isHidden = !on }

    override func layout() {
        super.layout()
        let w = bounds.width
        let side = w - 16
        thumbRect = NSRect(x: 8, y: bounds.height - side - 6, width: side, height: side)
        imageView.frame = hasThumbnail ? thumbRect.insetBy(dx: 2, dy: 2) : thumbRect.insetBy(dx: side * 0.12, dy: side * 0.12)
        // 名字 1–2 行，大小紧跟在名字下面
        let fit = nameLabel.attributedStringValue.boundingRect(with: NSSize(width: w - 8, height: 40), options: [.usesLineFragmentOrigin]).height
        let nameH = min(32, max(16, ceil(fit)))
        nameLabel.frame = NSRect(x: 4, y: thumbRect.minY - nameH - 5, width: w - 8, height: nameH)
        detailLabel.frame = NSRect(x: 4, y: nameLabel.frame.minY - 15, width: w - 8, height: 14)
        if let img = imageView.image, hasThumbnail {
            // 时长角标贴在缩略图实际画面的右下角
            let s = img.size, box = imageView.frame
            let k = min(box.width / max(s.width, 1), box.height / max(s.height, 1))
            let pic = NSRect(x: box.midX - s.width * k / 2, y: box.midY - s.height * k / 2, width: s.width * k, height: s.height * k)
            let ls = durationLabel.intrinsicContentSize
            durationBG.frame = NSRect(x: pic.maxX - ls.width - 10, y: pic.minY + 4, width: ls.width + 6, height: ls.height + 1)
            durationLabel.frame = durationBG.frame.offsetBy(dx: 3, dy: 0).insetBy(dx: 0, dy: 0)
        } else {
            let ls = durationLabel.intrinsicContentSize
            durationBG.frame = NSRect(x: thumbRect.maxX - ls.width - 10, y: thumbRect.minY + 6, width: ls.width + 6, height: ls.height + 1)
            durationLabel.frame = durationBG.frame.offsetBy(dx: 3, dy: 0)
        }
        sharedIcon.frame = NSRect(x: thumbRect.maxX - 16, y: thumbRect.maxY - 16, width: 14, height: 14)
    }

    private func restyle() {
        nameLabel.textColor = isSelected ? .white : .labelColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected || isDropTarget {
            // 选中：缩略图后面一块柔和底色 + 名字一条青绿底（切角，和 Logo 同一语言）
            NSColor.labelColor.withAlphaComponent(isDropTarget ? 0.16 : 0.09).setFill()
            chamferPath(thumbRect.insetBy(dx: -4, dy: -4), cut: 7).fill()
        }
        if isSelected {
            let text = nameLabel.attributedStringValue
            let size = text.boundingRect(with: NSSize(width: nameLabel.frame.width - 8, height: 40), options: [.usesLineFragmentOrigin]).size
            let r = NSRect(x: bounds.midX - min(size.width, nameLabel.frame.width - 4) / 2 - 6, y: nameLabel.frame.maxY - size.height - 2,
                           width: min(size.width, nameLabel.frame.width - 4) + 12, height: size.height + 3)
            Theme.accent.withAlphaComponent(0.9).setFill()
            chamferPath(r, cut: 4).fill()
        }
    }
}

final class FileTileItem: NSCollectionViewItem {
    var path = ""
    var tile: FileTileView { view as! FileTileView }
    override func loadView() { view = FileTileView() }
    override var isSelected: Bool { didSet { tile.isSelected = isSelected } }
    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { tile.isDropTarget = highlightState == .asDropTarget }
    }
}

/// 切角矩形（Logo 的八边形语言）
func chamferPath(_ r: NSRect, cut c0: CGFloat) -> NSBezierPath {
    let c = min(c0, r.width / 3, r.height / 3)
    let p = NSBezierPath()
    p.move(to: NSPoint(x: r.minX + c, y: r.minY))
    p.line(to: NSPoint(x: r.maxX - c, y: r.minY)); p.line(to: NSPoint(x: r.maxX, y: r.minY + c))
    p.line(to: NSPoint(x: r.maxX, y: r.maxY - c)); p.line(to: NSPoint(x: r.maxX - c, y: r.maxY))
    p.line(to: NSPoint(x: r.minX + c, y: r.maxY)); p.line(to: NSPoint(x: r.minX, y: r.maxY - c))
    p.line(to: NSPoint(x: r.minX, y: r.minY + c)); p.close()
    return p
}

// MARK: - 可接收拖放的网格 / 列表（键盘快捷键）

final class BrowseCollectionView: NSCollectionView {
    var onKey: ((NSEvent) -> Bool)?
    var onBackgroundMenu: (() -> NSMenu?)?
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        if let ip = indexPathForItem(at: p) {
            if !selectionIndexPaths.contains(ip) { selectionIndexPaths = [ip] }
            return menu
        }
        selectionIndexPaths = []
        return onBackgroundMenu?() ?? menu
    }
}

final class BrowseListTable: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
    override func menu(for event: NSEvent) -> NSMenu? {
        let r = row(at: convert(event.locationInWindow, from: nil))
        if r >= 0, !selectedRowIndexes.contains(r) { selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false) }
        return menu
    }
}

final class BrowseNameCell: NSTableCellView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 13)
        addSubview(icon); addSubview(label)
        imageView = icon; textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20), icon.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - 左侧栏

final class BrowseSourceRow: NSView {
    var onClick: (() -> Void)?
    var onMenu: (() -> NSMenu?)?
    var selected = false { didSet { needsDisplay = true; title.textColor = selected ? .labelColor : .secondaryLabelColor; icon.contentTintColor = selected ? Theme.accent : .secondaryLabelColor } }
    private var hovering = false { didSet { needsDisplay = true } }
    private let icon = NSImageView()
    private let title = makeLabel("", size: 12.5, weight: .medium, color: .secondaryLabelColor)

    init(symbol: String, text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        title.stringValue = text
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let h = hstack([icon, title], spacing: 8)
        h.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        addSubview(h)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            h.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            h.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            h.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        toolTip = text
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
    override func draw(_ dirtyRect: NSRect) {
        guard selected || hovering else { return }
        NSColor.labelColor.withAlphaComponent(selected ? 0.10 : 0.05).setFill()
        chamferPath(bounds.insetBy(dx: 2, dy: 1), cut: 6).fill()
    }
}

// MARK: - 浏览页

@MainActor
final class BrowseVC: NSViewController, Refreshable, NSCollectionViewDataSource, NSCollectionViewDelegate,
                      NSTableViewDataSource, NSTableViewDelegate, NSFilePromiseProviderDelegate, NSMenuDelegate {
    let engine: QueueEngine

    // 位置 + 历史
    private var root: BrowseRoot?
    private var path = ""
    private var back: [(BrowseRoot, String)] = []
    private var forward: [(BrowseRoot, String)] = []

    // 数据
    private var allEntries: [RemoteEntry] = []
    private var entries: [RemoteEntry] = []
    private var meta: [String: DriveFileMeta] = [:]
    private var cache: [String: [RemoteEntry]] = [:]
    private var loadToken = 0
    private var sortKey = UserDefaults.standard.string(forKey: "cf.browseSort") ?? "name"
    private var sortAsc = true

    // 界面
    private let sourceStack = NSStackView()
    private var sourceRows: [(BrowseRoot, BrowseSourceRow)] = []
    private let backBtn = CFButton("", style: .icon, symbol: "chevron.left")
    private let fwdBtn = CFButton("", style: .icon, symbol: "chevron.right")
    private let breadcrumb = NSStackView()
    private let viewSeg = NSSegmentedControl()
    private let searchField = NSSearchField()
    private let spinner = NSProgressIndicator()
    private let shareBtn = CFButton("", style: .icon, symbol: "person.crop.circle.badge.plus")
    private let contentBox = NSView()
    private let collection = BrowseCollectionView()
    private let gridScroll = NSScrollView()
    private let table = BrowseListTable()
    private let listScroll = NSScrollView()
    private let emptyView = NSStackView()
    private let emptyTitle = makeLabel("", size: 14, weight: .semibold, color: .secondaryLabelColor)
    private let emptySub = makeLabel("", size: 12, color: .tertiaryLabelColor)
    private let statusLabel = makeLabel("", size: 11.5, color: .secondaryLabelColor)
    private let infoBanner = makeLabel("", size: 11.5, color: .secondaryLabelColor)
    private let sizeSlider = NSSlider(value: 132, minValue: 92, maxValue: 236, target: nil, action: nil)
    private var gridMode: Bool { viewSeg.selectedSegment == 0 }
    private var tileWidth: CGFloat { CGFloat(sizeSlider.doubleValue) }

    init(engine: QueueEngine) { self.engine = engine; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let side = buildSidebar()
        let main = buildMain()
        let divider = HairlineView()
        for v in [side, divider, main] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        divider.removeConstraints(divider.constraints)
        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: view.leadingAnchor), side.topAnchor.constraint(equalTo: view.topAnchor),
            side.bottomAnchor.constraint(equalTo: view.bottomAnchor), side.widthAnchor.constraint(equalToConstant: 196),
            divider.leadingAnchor.constraint(equalTo: side.trailingAnchor), divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: view.topAnchor), divider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            main.leadingAnchor.constraint(equalTo: divider.trailingAnchor), main.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            main.topAnchor.constraint(equalTo: view.topAnchor), main.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        rebuildSources()
        // 调试：CLOUDFERRY_BROWSE_PATH 指定初始打开的文件夹（截图检查用）
        pendingStartPath = ProcessInfo.processInfo.environment["CLOUDFERRY_BROWSE_PATH"] ?? ""
        if let first = sourceRows.first?.0 { open(first, path: pendingStartPath, record: false); pendingStartPath = "" } else { showEmpty() }
    }

    func refreshOnShow() {
        let key = engine.remotes.map(\.name).joined(separator: ",")
        if key != lastRemotesKey { rebuildSources() }
        if root == nil, let first = sourceRows.first?.0 { open(first, path: pendingStartPath, record: false); pendingStartPath = "" } else { reload(force: false) }
    }
    private var pendingStartPath = ""

    override func viewDidAppear() {
        super.viewDidAppear()
        // 不要一进来就把光标放在搜索框里（键盘操作留给文件区）
        view.window?.makeFirstResponder(gridMode ? collection : table)
    }
    func focusSearch() { view.window?.makeFirstResponder(searchField) }
    private var lastRemotesKey = ""

    // MARK: 侧栏

    private func buildSidebar() -> NSView {
        let box = NSView()
        sourceStack.orientation = .vertical; sourceStack.alignment = .leading; sourceStack.spacing = 2
        sourceStack.translatesAutoresizingMaskIntoConstraints = false
        let openLink = CFButton(L("打开分享链接…", "Open shared link…"), style: .secondary, size: .small, symbol: "link") { [weak self] in self?.promptOpenLink() }
        openLink.toolTip = L("粘贴朋友发来的 Google Drive 链接，直接在这里浏览、预览、下载（有编辑权限还能上传）",
                             "Paste a Google Drive link from a friend to browse, preview and download it here (upload too, if you can edit)")
        openLink.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(sourceStack); box.addSubview(openLink)
        NSLayoutConstraint.activate([
            sourceStack.topAnchor.constraint(equalTo: box.topAnchor, constant: 18),
            sourceStack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            sourceStack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            openLink.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            openLink.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -16),
        ])
        return box
    }

    private func sectionLabel(_ t: String) -> NSView {
        let l = NSTextField(labelWithString: "")
        l.attributedStringValue = osdString(t, color: .tertiaryLabelColor, size: 9.5)
        let wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
        l.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(l)
        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 26),
            l.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 10), l.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -5),
        ])
        return wrap
    }

    private func rebuildSources() {
        lastRemotesKey = engine.remotes.map(\.name).joined(separator: ",")
        sourceStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sourceRows = []
        func add(_ r: BrowseRoot, removable: Bool = false) {
            let row = BrowseSourceRow(symbol: r.symbol, text: r.title)
            row.onClick = { [weak self] in self?.open(r, path: "") }
            if removable {
                row.onMenu = { [weak self] in
                    let m = NSMenu()
                    let it = NSMenuItem(title: L("从列表移除", "Remove from list"), action: #selector(BrowseVC.removeLinkMenu(_:)), keyEquivalent: "")
                    it.representedObject = r.folderID; it.target = self; m.addItem(it); return m
                }
            }
            sourceStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: sourceStack.widthAnchor).isActive = true
            sourceRows.append((r, row))
        }
        let remotes = engine.remotes
        if !remotes.isEmpty {
            sourceStack.addArrangedSubview(sectionLabel(L("网盘", "Clouds")))
            for r in remotes {
                add(BrowseRoot(kind: .remote, remote: r.name, title: r.isDrive ? L("我的云端硬盘", "My Drive") + (remotes.filter(\.isDrive).count > 1 ? " · \(r.name)" : "") : r.name))
            }
            let drives = remotes.filter(\.isDrive)
            if !drives.isEmpty {
                sourceStack.addArrangedSubview(sectionLabel(L("共享", "Shared")))
                for r in drives {
                    add(BrowseRoot(kind: .sharedWithMe, remote: r.name, title: L("与我共享", "Shared with me") + (drives.count > 1 ? " · \(r.name)" : "")))
                }
            }
        }
        let links = BrowseRoot.savedLinks
        if !links.isEmpty {
            sourceStack.addArrangedSubview(sectionLabel(L("链接", "Links")))
            for l in links { add(l, removable: true) }
        }
        highlightSource()
    }

    private func highlightSource() { for (r, row) in sourceRows { row.selected = (r == root) } }

    @objc private func removeLinkMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        BrowseRoot.savedLinks.removeAll { $0.folderID == id }
        if root?.folderID == id { root = nil }
        rebuildSources()
        if root == nil, let first = sourceRows.first?.0 { open(first, path: "", record: false) }
    }

    // MARK: 主区域

    private func buildMain() -> NSView {
        let box = NSView()

        // 工具栏
        backBtn.toolTip = L("后退（⌘[）", "Back (⌘[)"); backBtn.onAction { [weak self] in self?.goBack() }
        fwdBtn.toolTip = L("前进（⌘]）", "Forward (⌘])"); fwdBtn.onAction { [weak self] in self?.goForward() }
        breadcrumb.orientation = .horizontal; breadcrumb.spacing = 2
        breadcrumb.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        viewSeg.segmentCount = 2
        viewSeg.setImage(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: L("图标", "Icons")), forSegment: 0)
        viewSeg.setImage(NSImage(systemSymbolName: "list.bullet", accessibilityDescription: L("列表", "List")), forSegment: 1)
        viewSeg.setToolTip(L("图标视图（缩略图）", "Icon view (thumbnails)"), forSegment: 0)
        viewSeg.setToolTip(L("列表视图", "List view"), forSegment: 1)
        viewSeg.trackingMode = .selectOne
        viewSeg.selectedSegment = UserDefaults.standard.integer(forKey: "cf.browseView") == 1 ? 1 : 0
        viewSeg.target = self; viewSeg.action = #selector(viewModeChanged)
        viewSeg.controlSize = .regular
        viewSeg.selectedSegmentBezelColor = Theme.accent.withAlphaComponent(0.85)
        searchField.placeholderString = L("在当前文件夹中搜索", "Search this folder")
        searchField.target = self; searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let newFolder = CFButton("", style: .icon, symbol: "folder.badge.plus") { [weak self] in self?.newFolder() }
        newFolder.toolTip = L("新建文件夹（⇧⌘N）", "New folder (⇧⌘N)")
        let upload = CFButton("", style: .icon, symbol: "arrow.up.doc") { [weak self] in self?.uploadHere() }
        upload.toolTip = L("上传到这里（也可以直接把文件拖进来）", "Upload here (or just drag files in)")
        shareBtn.toolTip = L("共享（获取链接 / 邀请朋友）", "Share (get link / invite people)")
        shareBtn.onAction { [weak self] in self?.shareSelected() }
        let more = CFButton("", style: .icon, symbol: "ellipsis.circle") { [weak self] in self?.showMoreMenu() }
        more.toolTip = L("排序和更多", "Sort & more")
        moreButton = more
        let bar = hstack([backBtn, fwdBtn, breadcrumb, flexibleSpacer(), spinner, viewSeg, searchField, newFolder, upload, shareBtn, more], spacing: 6)
        bar.setCustomSpacing(12, after: fwdBtn); bar.setCustomSpacing(12, after: viewSeg)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)

        // 网格
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 6; layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 14, left: 14, bottom: 20, right: 14)
        collection.collectionViewLayout = layout
        collection.dataSource = self; collection.delegate = self
        collection.isSelectable = true; collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.register(FileTileItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("tile"))
        collection.registerForDraggedTypes([.fileURL, .cfRemoteItem])
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        collection.onKey = { [weak self] in self?.handleKey($0) ?? false }
        collection.onBackgroundMenu = { [weak self] in self?.backgroundMenu() }
        collection.menu = itemMenu()
        let click = NSClickGestureRecognizer(target: self, action: #selector(gridDoubleClick(_:)))
        click.numberOfClicksRequired = 2; click.delaysPrimaryMouseButtonEvents = false
        collection.addGestureRecognizer(click)
        gridScroll.documentView = collection
        gridScroll.drawsBackground = false; gridScroll.hasVerticalScroller = true; gridScroll.autohidesScrollers = true

        // 列表
        table.dataSource = self; table.delegate = self
        table.style = .inset
        table.rowHeight = 28
        table.allowsMultipleSelection = true
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.registerForDraggedTypes([.fileURL, .cfRemoteItem])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        table.doubleAction = #selector(listDoubleClick); table.target = self
        table.onKey = { [weak self] in self?.handleKey($0) ?? false }
        table.menu = itemMenu()
        for (id, title, w) in [("name", L("名称", "Name"), 360.0), ("size", L("大小", "Size"), 90.0), ("kind", L("种类", "Kind"), 150.0), ("date", L("修改日期", "Date Modified"), 150.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title; c.width = CGFloat(w); c.minWidth = 60
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(c)
        }
        applyCleanHeader(table)
        listScroll.documentView = table
        listScroll.drawsBackground = false; listScroll.hasVerticalScroller = true; listScroll.autohidesScrollers = true

        // 空状态
        let emptyIcon = NSImageView(image: NSImage(systemSymbolName: "tray", accessibilityDescription: nil) ?? NSImage())
        emptyIcon.symbolConfiguration = .init(pointSize: 30, weight: .light); emptyIcon.contentTintColor = .tertiaryLabelColor
        emptySub.alignment = .center; emptySub.maximumNumberOfLines = 3
        for v in [emptyIcon, emptyTitle, emptySub] as [NSView] { emptyView.addArrangedSubview(v) }
        emptyView.orientation = .vertical; emptyView.alignment = .centerX; emptyView.spacing = 8

        for v in [gridScroll, listScroll, emptyView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false; contentBox.addSubview(v)
        }
        NSLayoutConstraint.activate([
            gridScroll.topAnchor.constraint(equalTo: contentBox.topAnchor), gridScroll.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor),
            gridScroll.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor), gridScroll.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor),
            listScroll.topAnchor.constraint(equalTo: contentBox.topAnchor), listScroll.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor),
            listScroll.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor), listScroll.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor),
            emptyView.centerXAnchor.constraint(equalTo: contentBox.centerXAnchor), emptyView.centerYAnchor.constraint(equalTo: contentBox.centerYAnchor, constant: -20),
            emptyView.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])

        // 状态栏
        sizeSlider.target = self; sizeSlider.action = #selector(sizeChanged)
        sizeSlider.controlSize = .small
        sizeSlider.doubleValue = UserDefaults.standard.double(forKey: "cf.browseTile").clamped(92, 236, default: 132)
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        sizeSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        sizeSlider.toolTip = L("缩略图大小", "Thumbnail size")
        infoBanner.font = Typo.caption; infoBanner.lineBreakMode = .byTruncatingTail
        infoBanner.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.font = Typo.number(11.5)
        let small = NSImageView(image: NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage())
        small.symbolConfiguration = .init(pointSize: 9, weight: .regular); small.contentTintColor = .tertiaryLabelColor
        let big = NSImageView(image: NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage())
        big.symbolConfiguration = .init(pointSize: 13, weight: .regular); big.contentTintColor = .tertiaryLabelColor
        sliderBox = hstack([small, sizeSlider, big], spacing: 6)
        let status = hstack([statusLabel, infoBanner, flexibleSpacer(), sliderBox], spacing: 14)
        status.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)

        let topLine = HairlineView(), bottomLine = HairlineView()
        for v in [bar, topLine, contentBox, bottomLine, status] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(v) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: box.topAnchor, constant: 10), bar.heightAnchor.constraint(equalToConstant: 40),
            bar.leadingAnchor.constraint(equalTo: box.leadingAnchor), bar.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            topLine.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            topLine.leadingAnchor.constraint(equalTo: box.leadingAnchor), topLine.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            contentBox.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            contentBox.leadingAnchor.constraint(equalTo: box.leadingAnchor), contentBox.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            bottomLine.topAnchor.constraint(equalTo: contentBox.bottomAnchor),
            bottomLine.leadingAnchor.constraint(equalTo: box.leadingAnchor), bottomLine.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            status.topAnchor.constraint(equalTo: bottomLine.bottomAnchor), status.heightAnchor.constraint(equalToConstant: 30),
            status.leadingAnchor.constraint(equalTo: box.leadingAnchor), status.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        applyViewMode()
        return box
    }
    private var moreButton: NSView?
    private var sliderBox: NSView!

    override func viewDidLayout() {
        super.viewDidLayout()
        updateTileSize()
    }

    private func updateTileSize() {
        guard let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        let w = tileWidth
        let size = NSSize(width: w, height: w - 16 + 62)
        if layout.itemSize != size { layout.itemSize = size; layout.invalidateLayout() }
    }

    @objc private func sizeChanged() {
        UserDefaults.standard.set(sizeSlider.doubleValue, forKey: "cf.browseTile")
        updateTileSize()
        loadVisibleThumbs()
    }

    @objc private func viewModeChanged() {
        UserDefaults.standard.set(viewSeg.selectedSegment, forKey: "cf.browseView")
        applyViewMode()
    }

    private func applyViewMode() {
        gridScroll.isHidden = !gridMode
        listScroll.isHidden = gridMode
        sliderBox?.isHidden = !gridMode
        reloadViews()
    }

    // MARK: 导航

    private func open(_ r: BrowseRoot, path p: String, record: Bool = true) {
        if record, let cur = root { back.append((cur, path)); forward.removeAll() }
        root = r; path = p
        searchField.stringValue = ""
        highlightSource()
        rebuildBreadcrumb()
        updateNavButtons()
        reload(force: false)
    }
    private func goBack() {
        guard let (r, p) = back.popLast() else { return }
        if let cur = root { forward.append((cur, path)) }
        root = r; path = p; highlightSource(); rebuildBreadcrumb(); updateNavButtons(); reload(force: false)
    }
    private func goForward() {
        guard let (r, p) = forward.popLast() else { return }
        if let cur = root { back.append((cur, path)) }
        root = r; path = p; highlightSource(); rebuildBreadcrumb(); updateNavButtons(); reload(force: false)
    }
    private func goUp() {
        guard let r = root, !path.isEmpty else { return }
        open(r, path: (path as NSString).deletingLastPathComponent)
    }
    private func enter(_ e: RemoteEntry) {
        guard let r = root, e.isDir else { return }
        open(r, path: e.path)
    }
    private func updateNavButtons() { backBtn.isEnabled = !back.isEmpty; fwdBtn.isEnabled = !forward.isEmpty }

    private func rebuildBreadcrumb() {
        breadcrumb.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let r = root else { return }
        var crumbs: [(String, String)] = [(r.title, "")]
        var acc = ""
        for part in path.split(separator: "/") { acc = acc.isEmpty ? String(part) : acc + "/" + part; crumbs.append((String(part), acc)) }
        // 太深时只显示开头和最后两级
        if crumbs.count > 4 { crumbs = [crumbs[0], ("…", crumbs[crumbs.count - 3].1)] + crumbs.suffix(2) }
        for (i, c) in crumbs.enumerated() {
            if i > 0 {
                let chev = NSImageView(image: NSImage(systemSymbolName: "chevron.compact.right", accessibilityDescription: nil) ?? NSImage())
                chev.contentTintColor = .tertiaryLabelColor
                breadcrumb.addArrangedSubview(chev)
            }
            let last = i == crumbs.count - 1
            let b = CFButton(c.0, style: last ? .secondary : .plain, size: .small) { [weak self] in
                guard let self, let r = self.root, c.1 != self.path else { return }
                self.open(r, path: c.1)
            }
            b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            breadcrumb.addArrangedSubview(b)
            // 面包屑可以接收拖放：拖到上一级 = 移动到那里
            b.registerForDraggedTypes([.cfRemoteItem, .fileURL])
        }
    }

    // MARK: 读取

    private var cacheKey: String { (root?.spec ?? "") + ":" + path }

    private func reload(force: Bool) {
        guard let r = root else { showEmpty(); return }
        let key = cacheKey
        if !force, let c = cache[key] { allEntries = c; applyFilterSort() }
        spinner.startAnimation(nil)
        loadToken += 1
        let token = loadToken
        let p = path
        Task { [weak self] in
            guard let self else { return }
            let list = await self.engine.listPath(remote: r.spec, path: p)
            guard token == self.loadToken else { return }
            self.spinner.stopAnimation(nil)
            guard let list else {
                self.allEntries = []; self.applyFilterSort()
                self.emptyTitle.stringValue = L("读取失败", "Couldn't load")
                self.emptySub.stringValue = (self.engine.lastListError ?? "") + L("\n可能没有权限，或者网络有问题。", "\nYou may not have access, or the network is down.")
                self.emptyView.isHidden = false
                return
            }
            self.cache[key] = list
            self.allEntries = list
            self.applyFilterSort()
            // Google Drive：一次取回这个文件夹的缩略图、视频时长、共享状态
            let m = await self.engine.driveFolderMeta(r, path: p)
            guard token == self.loadToken else { return }
            self.meta = m
            self.reloadViews()
        }
        updateInfoBanner()
    }

    private func updateInfoBanner() {
        guard let r = root else { infoBanner.stringValue = ""; return }
        switch r.kind {
        case .sharedWithMe:
            infoBanner.stringValue = L("别人共享给你的文件 · 有「可编辑」权限的文件夹可以直接拖文件进去上传（占用你自己的空间）",
                                       "Files others shared with you · drop files into folders you can edit (uses your own storage)")
        case .link:
            infoBanner.stringValue = L("通过链接打开 · 有编辑权限才能上传", "Opened from a link · upload needs edit access")
        case .remote:
            infoBanner.stringValue = ""
        }
    }

    private func applyFilterSort() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var list = q.isEmpty ? allEntries : allEntries.filter { $0.name.lowercased().contains(q) }
        let asc = sortAsc
        list.sort { a, b in
            if a.isDir != b.isDir { return a.isDir }
            let r: Bool
            switch sortKey {
            case "size": r = a.size == b.size ? a.name.localizedStandardCompare(b.name) == .orderedAscending : a.size < b.size
            case "date": r = (a.modTime ?? .distantPast) < (b.modTime ?? .distantPast)
            case "kind": r = a.ext == b.ext ? a.name.localizedStandardCompare(b.name) == .orderedAscending : a.ext < b.ext
            default: r = a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return asc ? r : !r
        }
        entries = list
        reloadViews()
    }

    private func reloadViews() {
        if gridMode { collection.reloadData() } else { table.reloadData() }
        updateStatus()
        if entries.isEmpty && root != nil && !spinner.isHidden == false {
            emptyTitle.stringValue = searchField.stringValue.isEmpty ? L("这个文件夹是空的", "This folder is empty") : L("没有匹配的文件", "No matches")
            emptySub.stringValue = searchField.stringValue.isEmpty ? L("把文件或文件夹从访达拖进来就能上传到这里", "Drag files or folders here from Finder to upload them") : ""
        }
        emptyView.isHidden = !entries.isEmpty || root == nil && false
        if root == nil { emptyView.isHidden = false }
    }

    private func showEmpty() {
        entries = []; allEntries = []
        emptyTitle.stringValue = L("还没有连接网盘", "No cloud connected yet")
        emptySub.stringValue = L("先到「我的网盘」连接 Google Drive，或者在左下角打开一个分享链接", "Connect Google Drive under Remotes, or open a shared link (bottom left)")
        emptyView.isHidden = false
        reloadViews()
    }

    private func updateStatus() {
        let sel = selected()
        let dirs = entries.filter(\.isDir).count, files = entries.count - dirs
        var s = L("\(entries.count) 项（\(dirs) 个文件夹，\(files) 个文件）", "\(entries.count) items (\(dirs) folders, \(files) files)")
        if !sel.isEmpty {
            let bytes = sel.filter { !$0.isDir }.reduce(Int64(0)) { $0 + $1.size }
            s = L("已选 \(sel.count) 项", "\(sel.count) selected") + (bytes > 0 ? " · " + Format.bytes(bytes) : "") + "  /  " + s
        }
        statusLabel.stringValue = s
        let isDrive = root.flatMap { engine.remote(named: $0.remote) }?.isDrive ?? false
        shareBtn.isEnabled = isDrive && sel.count <= 1
    }

    // MARK: 网格数据源

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("tile"), for: ip) as! FileTileItem
        guard ip.item < entries.count else { return item }
        let e = entries[ip.item]
        item.path = e.path
        let t = item.tile
        t.nameLabel.stringValue = e.name
        t.nameLabel.toolTip = e.name
        let m = e.fileID.flatMap { meta[$0] }
        t.detailLabel.stringValue = e.isDir ? (e.sizeComputed ? Format.bytes(e.size) : "") : Format.bytes(e.size)
        t.setDuration(e.isVideo ? m?.durationMs : nil)
        t.setShared((m?.shared ?? false) && root?.kind == .remote)
        if let img = ThumbnailStore.shared.cached(thumbKey(e)) {
            t.imageView.image = img; t.hasThumbnail = true
        } else {
            t.imageView.image = FileIcons.icon(for: e); t.hasThumbnail = false
            loadThumb(for: e, item: item)
        }
        t.needsLayout = true
        return item
    }

    private func thumbPx() -> Int { tileWidth > 160 ? 640 : 400 }
    private func thumbKey(_ e: RemoteEntry) -> String { "\(root?.spec ?? ""):\(e.path)@\(thumbPx())" }

    private func canThumb(_ e: RemoteEntry) -> Bool {
        if e.isDir { return false }
        if let fid = e.fileID, meta[fid]?.thumbnailLink != nil { return true }
        return e.isImage || e.isVideo || e.ext == "pdf"
    }

    private func loadThumb(for e: RemoteEntry, item: FileTileItem?) {
        guard canThumb(e), let r = root else { return }
        let key = thumbKey(e), px = thumbPx()
        let link = e.fileID.flatMap { meta[$0]?.thumbnailLink }
        Task { [weak self] in
            guard let self else { return }
            let img = await ThumbnailStore.shared.load(key) { [weak self] in
                guard let self else { return nil }
                if let fid = e.fileID, let link {
                    return await self.engine.driveThumbnail(remote: r.remote, fileID: fid, link: link, px: px)
                }
                if let lp = await self.engine.localPath(remote: r.remote, path: e.path) {
                    return await ThumbnailStore.quickLook(path: lp, px: CGFloat(px) / 2)
                }
                return nil
            }
            guard let img else { return }
            if let item, item.path == e.path {
                item.tile.imageView.image = img; item.tile.hasThumbnail = true; item.tile.needsLayout = true
            } else if !self.gridMode, let row = self.entries.firstIndex(where: { $0.path == e.path }) {
                self.table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            }
        }
    }

    private func loadVisibleThumbs() {
        for ip in collection.indexPathsForVisibleItems() where ip.item < entries.count {
            if let item = collection.item(at: ip) as? FileTileItem, !item.tile.hasThumbnail { loadThumb(for: entries[ip.item], item: item) }
        }
    }

    func collectionView(_ cv: NSCollectionView, didSelectItemsAt ips: Set<IndexPath>) { updateStatus(); PreviewController.shared.follow(selectedFirst()) }
    func collectionView(_ cv: NSCollectionView, didDeselectItemsAt ips: Set<IndexPath>) { updateStatus() }

    // 拖出：每个项目一个「文件承诺」（拖到访达 = 下载），同时带 App 内移动用的数据
    func collectionView(_ cv: NSCollectionView, canDragItemsAt ips: Set<IndexPath>, with event: NSEvent) -> Bool { true }
    func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt ip: IndexPath) -> NSPasteboardWriting? {
        ip.item < entries.count ? promise(for: entries[ip.item]) : nil
    }

    func collectionView(_ cv: NSCollectionView, validateDrop info: NSDraggingInfo, proposedIndexPath ip: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation op: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let idx = ip.pointee.item
        if op.pointee == .on, idx < entries.count, entries[idx].isDir, !isDraggingSelf(info, onto: entries[idx]) {
            return isRemoteDrag(info) ? .move : .copy
        }
        // 其他位置 = 放到当前文件夹
        op.pointee = .before
        if isRemoteDrag(info) && dragSpec(info) == root?.spec && dragParents(info) == [path] { return [] }
        return isRemoteDrag(info) ? .move : .copy
    }

    func collectionView(_ cv: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath ip: IndexPath,
                        dropOperation op: NSCollectionView.DropOperation) -> Bool {
        let target = (op == .on && ip.item < entries.count && entries[ip.item].isDir) ? entries[ip.item].path : path
        return handleDrop(info, intoDir: target)
    }

    // MARK: 列表数据源

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tv: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count, let id = column?.identifier.rawValue else { return nil }
        let e = entries[row]
        if id == "name" {
            let cell = (tv.makeView(withIdentifier: NSUserInterfaceItemIdentifier("nameCell"), owner: self) as? BrowseNameCell) ?? {
                let c = BrowseNameCell(); c.identifier = NSUserInterfaceItemIdentifier("nameCell"); return c
            }()
            cell.label.stringValue = e.name
            if let img = ThumbnailStore.shared.cached(thumbKey(e)) { cell.icon.image = img }
            else { cell.icon.image = FileIcons.icon(for: e); loadThumb(for: e, item: nil) }
            return cell
        }
        let l = (tv.makeView(withIdentifier: NSUserInterfaceItemIdentifier(id), owner: self) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: ""); t.identifier = NSUserInterfaceItemIdentifier(id)
            t.lineBreakMode = .byTruncatingTail; return t
        }()
        l.textColor = .secondaryLabelColor
        switch id {
        case "size": l.stringValue = e.isDir ? (e.sizeComputed ? Format.bytes(e.size) : "—") : Format.bytes(e.size); l.font = Typo.number(12); l.alignment = .right
        case "kind":
            var k = FileIcons.kind(e)
            if e.isVideo, let ms = e.fileID.flatMap({ meta[$0]?.durationMs }) { k += " · " + Format.timecode(Double(ms) / 1000) }
            l.stringValue = k; l.font = .systemFont(ofSize: 12); l.alignment = .left
        default: l.stringValue = Format.dateShort(e.modTime); l.font = Typo.number(12); l.alignment = .left
        }
        return l
    }

    func tableViewSelectionDidChange(_ n: Notification) { updateStatus(); PreviewController.shared.follow(selectedFirst()) }

    func tableView(_ tv: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        guard let d = tv.sortDescriptors.first, let k = d.key else { return }
        sortKey = k; sortAsc = d.ascending
        UserDefaults.standard.set(k, forKey: "cf.browseSort")
        applyFilterSort()
    }

    func tableView(_ tv: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        row < entries.count ? promise(for: entries[row]) : nil
    }

    func tableView(_ tv: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        if op == .on, row < entries.count, entries[row].isDir, !isDraggingSelf(info, onto: entries[row]) {
            return isRemoteDrag(info) ? .move : .copy
        }
        tv.setDropRow(-1, dropOperation: .on)
        if isRemoteDrag(info) && dragSpec(info) == root?.spec && dragParents(info) == [path] { return [] }
        return isRemoteDrag(info) ? .move : .copy
    }

    func tableView(_ tv: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        let target = (row >= 0 && row < entries.count && entries[row].isDir) ? entries[row].path : path
        return handleDrop(info, intoDir: target)
    }

    // MARK: 拖放

    private func promise(for e: RemoteEntry) -> NSPasteboardWriting {
        let type = e.isDir ? UTType.folder.identifier : (UTType(filenameExtension: e.ext) ?? .data).identifier
        let p = RemotePromiseProvider(fileType: type, delegate: self)
        let item = DragItem(spec: root?.spec ?? "", path: e.path, name: e.name, isDir: e.isDir, size: e.size)
        p.userInfo = item.path
        p.payload = try? JSONEncoder().encode(item)
        promisedItems[e.path] = (item, e)
        return p
    }
    private var promisedItems: [String: (DragItem, RemoteEntry)] = [:]

    private func dragItems(_ info: NSDraggingInfo) -> [DragItem] {
        (info.draggingPasteboard.pasteboardItems ?? []).compactMap { pi in
            pi.data(forType: .cfRemoteItem).flatMap { try? JSONDecoder().decode(DragItem.self, from: $0) }
        }
    }
    private func isRemoteDrag(_ info: NSDraggingInfo) -> Bool { !dragItems(info).isEmpty }
    private func dragSpec(_ info: NSDraggingInfo) -> String? { dragItems(info).first?.spec }
    private func dragParents(_ info: NSDraggingInfo) -> Set<String> { Set(dragItems(info).map { ($0.path as NSString).deletingLastPathComponent }) }
    private func isDraggingSelf(_ info: NSDraggingInfo, onto e: RemoteEntry) -> Bool {
        dragItems(info).contains { $0.spec == root?.spec && ($0.path == e.path || e.path.hasPrefix($0.path + "/")) }
    }

    private func handleDrop(_ info: NSDraggingInfo, intoDir dir: String) -> Bool {
        guard let r = root else { return false }
        let items = dragItems(info)
        if !items.isEmpty {
            // App 内拖动 = 移动（可以跨「我的网盘」和共享文件夹）
            guard let fromSpec = items.first?.spec else { return false }
            let entries = items.map { RemoteEntry(name: $0.name, path: $0.path, size: $0.size, isDir: $0.isDir, modTime: nil) }
            setInfo(L("正在移动 \(entries.count) 项…", "Moving \(entries.count) item(s)…"))
            spinner.startAnimation(nil)
            Task { [weak self] in
                guard let self else { return }
                let failed = await self.engine.moveEntries(fromSpec: fromSpec, entries, toSpec: r.spec, toDir: dir)
                self.cache.removeAll()
                self.reload(force: true)
                self.setInfo(failed == 0 ? L("已移动 \(entries.count) 项", "Moved \(entries.count) item(s)")
                                         : L("\(failed) 项移动失败（详见运行日志）", "\(failed) move(s) failed (see Logs)"))
            }
            return true
        }
        // 从访达拖进来 = 上传到这个文件夹
        let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        engine.addUploadJobs(sources: urls, destRemote: r.spec, destPath: dir)
        setInfo(L("已加入 \(urls.count) 个上传任务 → ", "Queued \(urls.count) upload(s) → ") + (dir.isEmpty ? r.title : dir))
        return true
    }

    private func setInfo(_ s: String) { infoBanner.stringValue = s; infoBanner.textColor = Theme.accent }

    // NSFilePromiseProviderDelegate：在主线程处理（operationQueue 返回 main）
    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }

    nonisolated func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        let path = p.userInfo as? String ?? "file"
        return (path as NSString).lastPathComponent
    }

    nonisolated func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let path = p.userInfo as? String ?? ""
        MainActor.assumeIsolated {
            guard let (item, e) = promisedItems[path], let r = root else { completionHandler(nil); return }
            let dir = url.deletingLastPathComponent()
            if e.isDir || e.size > 300_000_000 {
                // 大文件 / 文件夹：交给下载队列（有进度、可暂停、断网会重试）
                let dest = e.isDir ? dir.appendingPathComponent(e.name).path : dir.path
                engine.addJob(sourceFs: "\(item.spec):\(e.path)", sourceLabel: e.name, destFs: dest, destLabel: dir.lastPathComponent,
                              direction: .download, isSingleFile: !e.isDir)
                setInfo(L("「\(e.name)」已加入下载队列 → ", "“\(e.name)” queued for download → ") + dir.lastPathComponent)
                completionHandler(nil)
            } else {
                setInfo(L("正在下载「\(e.name)」…", "Downloading “\(e.name)”…"))
                Task { [weak self] in
                    let ok = await self?.engine.fetchToLocal(spec: r.spec, e, into: dir) ?? false
                    self?.setInfo(ok ? L("已下载「\(e.name)」", "Downloaded “\(e.name)”") : L("下载失败「\(e.name)」", "Download failed “\(e.name)”"))
                    completionHandler(ok ? nil : NSError(domain: "CloudFerry", code: 1))
                }
            }
        }
    }

    // MARK: 选择 / 打开 / 预览

    private func selected() -> [RemoteEntry] {
        if gridMode { return collection.selectionIndexPaths.map(\.item).sorted().compactMap { $0 < entries.count ? entries[$0] : nil } }
        return table.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0] : nil }
    }
    private func selectedFirst() -> RemoteEntry? { selected().first }

    @objc private func gridDoubleClick(_ g: NSClickGestureRecognizer) {
        let p = g.location(in: collection)
        guard let ip = collection.indexPathForItem(at: p), ip.item < entries.count else { return }
        openItem(entries[ip.item])
    }
    @objc private func listDoubleClick() {
        let r = table.clickedRow
        guard r >= 0, r < entries.count else { return }
        openItem(entries[r])
    }
    private func openItem(_ e: RemoteEntry) { if e.isDir { enter(e) } else { preview(e) } }

    private func preview(_ e: RemoteEntry?) {
        guard let r = root else { return }
        let files = entries.filter { !$0.isDir }
        guard let e = e ?? files.first, let idx = files.firstIndex(where: { $0.path == e.path }) else { return }
        PreviewController.shared.show(engine: engine, root: r, items: files, index: idx, meta: meta)
    }

    private func handleKey(_ ev: NSEvent) -> Bool {
        let cmd = ev.modifierFlags.contains(.command), shift = ev.modifierFlags.contains(.shift)
        switch ev.keyCode {
        case 49: // 空格：快速预览
            if PreviewController.shared.isVisible { PreviewController.shared.close() } else { preview(selectedFirst()) }
            return true
        case 36, 76: // 回车：打开
            if let e = selectedFirst() { openItem(e) }; return true
        case 51 where cmd, 117: // ⌘⌫ / Delete
            deleteSelected(); return true
        case 126 where cmd: goUp(); return true // ⌘↑
        case 125 where cmd: if let e = selectedFirst() { openItem(e) }; return true // ⌘↓
        case 33 where cmd: goBack(); return true // ⌘[
        case 30 where cmd: goForward(); return true // ⌘]
        case 34 where cmd: getInfo(); return true // ⌘I
        case 45 where cmd && shift: newFolder(); return true // ⇧⌘N
        default: return false
        }
    }

    // MARK: 菜单

    private func itemMenu() -> NSMenu {
        let m = NSMenu(); m.delegate = self
        return m
    }
    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        let sel = selected()
        guard !sel.isEmpty else { for it in backgroundMenu().items { m.addItem(it.copy() as! NSMenuItem) }; return }
        let isDrive = root.flatMap { engine.remote(named: $0.remote) }?.isDrive ?? false
        func add(_ t: String, _ s: String, _ sel: Selector, key: String = "") {
            let it = NSMenuItem(title: t, action: sel, keyEquivalent: key); it.target = self
            it.image = NSImage(systemSymbolName: s, accessibilityDescription: nil); m.addItem(it)
        }
        if sel.count == 1, let e = sel.first {
            add(e.isDir ? L("打开", "Open") : L("快速预览", "Quick Look"), e.isDir ? "folder" : "eye", #selector(menuOpen))
        }
        add(L("下载到…", "Download to…"), "arrow.down.circle", #selector(menuDownload))
        if isDrive && sel.count == 1 {
            add(L("共享…", "Share…"), "person.crop.circle.badge.plus", #selector(menuShare))
            add(L("拷贝链接", "Copy link"), "link", #selector(menuCopyLink))
            add(L("在 Google Drive 网页中打开", "Open in Google Drive"), "safari", #selector(menuOpenWeb))
        }
        m.addItem(.separator())
        if sel.count == 1 { add(L("重命名…", "Rename…"), "pencil", #selector(menuRename)) }
        if sel.contains(where: \.isDir) { add(L("计算大小", "Calculate size"), "sum", #selector(menuCalcSize)) }
        if sel.count == 1 { add(L("简介", "Get Info"), "info.circle", #selector(menuInfo), key: "i") }
        add(L("拷贝路径", "Copy path"), "doc.on.doc", #selector(menuCopyPath))
        m.addItem(.separator())
        add(isDrive ? L("移到 Google Drive 回收站", "Move to Drive Trash") : L("删除", "Delete"), "trash", #selector(menuDelete))
    }

    private func backgroundMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ t: String, _ s: String, _ sel: Selector) {
            let it = NSMenuItem(title: t, action: sel, keyEquivalent: ""); it.target = self
            it.image = NSImage(systemSymbolName: s, accessibilityDescription: nil); m.addItem(it)
        }
        add(L("新建文件夹", "New folder"), "folder.badge.plus", #selector(menuNewFolder))
        add(L("上传到这里…", "Upload here…"), "arrow.up.doc", #selector(menuUpload))
        if root.flatMap({ engine.remote(named: $0.remote) })?.isDrive == true {
            add(L("共享这个文件夹…", "Share this folder…"), "person.crop.circle.badge.plus", #selector(menuShareFolder))
        }
        add(L("刷新", "Refresh"), "arrow.clockwise", #selector(menuRefresh))
        return m
    }

    private func showMoreMenu() {
        let m = NSMenu()
        for (k, t) in [("name", L("按名称", "By name")), ("date", L("按修改日期", "By date")), ("size", L("按大小", "By size")), ("kind", L("按种类", "By kind"))] {
            let it = NSMenuItem(title: t, action: #selector(menuSort(_:)), keyEquivalent: ""); it.target = self
            it.representedObject = k; it.state = sortKey == k ? .on : .off; m.addItem(it)
        }
        let asc = NSMenuItem(title: sortAsc ? L("升序", "Ascending") : L("降序", "Descending"), action: #selector(menuToggleAsc), keyEquivalent: "")
        asc.target = self; m.addItem(asc)
        m.addItem(.separator())
        for it in backgroundMenu().items { m.addItem(it.copy() as! NSMenuItem) }
        if let b = moreButton { m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b) }
    }

    @objc private func menuSort(_ s: NSMenuItem) { sortKey = s.representedObject as? String ?? "name"; UserDefaults.standard.set(sortKey, forKey: "cf.browseSort"); applyFilterSort() }
    @objc private func menuToggleAsc() { sortAsc.toggle(); applyFilterSort() }
    @objc private func menuOpen() { if let e = selectedFirst() { openItem(e) } }
    @objc private func menuDownload() { downloadSelected() }
    @objc private func menuShare() { shareSelected() }
    @objc private func menuShareFolder() { shareCurrentFolder() }
    @objc private func menuCopyLink() { copyLink() }
    @objc private func menuOpenWeb() { openWeb() }
    @objc private func menuRename() { renameSelected() }
    @objc private func menuCalcSize() { for e in selected() where e.isDir { calcSize(e) } }
    @objc private func menuInfo() { getInfo() }
    @objc private func menuCopyPath() {
        let text = selected().map { "\(root?.spec ?? ""):\($0.path)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        setInfo(L("已拷贝路径", "Path copied"))
    }
    @objc private func menuDelete() { deleteSelected() }
    @objc private func menuNewFolder() { newFolder() }
    @objc private func menuUpload() { uploadHere() }
    @objc private func menuRefresh() { cache.removeAll(); reload(force: true) }
    @objc private func searchChanged() { applyFilterSort() }

    // MARK: 动作

    private func downloadSelected() {
        guard let r = root else { return }
        let sel = selected(); guard !sel.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = L("下载到这里", "Download here")
        guard panel.runModal() == .OK, let dest = panel.urls.first else { return }
        for e in sel {
            let localDest = e.isDir ? dest.appendingPathComponent(e.name).path : dest.path
            engine.addJob(sourceFs: "\(r.spec):\(e.path)", sourceLabel: e.name, destFs: localDest, destLabel: dest.lastPathComponent,
                          direction: .download, isSingleFile: !e.isDir)
        }
        setInfo(L("已加入 \(sel.count) 个下载任务", "Queued \(sel.count) download(s)"))
    }

    private func deleteSelected() {
        guard let r = root else { return }
        let sel = selected(); guard !sel.isEmpty else { return }
        let isDrive = engine.remote(named: r.remote)?.isDrive ?? false
        let a = NSAlert()
        a.messageText = L("删除选中的 \(sel.count) 项？", "Delete \(sel.count) item(s)?")
        a.informativeText = isDrive
            ? L("会移到 Google Drive 的回收站，30 天内可以在网页版 Drive 的「回收站」里恢复。", "Moves to Google Drive's Trash; recoverable on drive.google.com for 30 days.")
            : L("会从云端删除（文件夹含全部内容），可能无法撤销。", "Deletes from the cloud (folders include all contents). May not be undoable.")
        a.addButton(withTitle: L("删除", "Delete")); a.addButton(withTitle: L("取消", "Cancel"))
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else { return }
        spinner.startAnimation(nil)
        Task { [weak self] in
            guard let self else { return }
            var failed = 0
            for e in sel { if await self.engine.deleteEntry(remote: r.spec, entry: e) == false { failed += 1 } }
            self.cache.removeAll(); self.reload(force: true)
            self.setInfo(failed == 0 ? L("已删除 \(sel.count) 项", "Deleted \(sel.count) item(s)") : L("\(failed) 项删除失败", "\(failed) deletion(s) failed"))
        }
    }

    private func renameSelected() {
        guard let r = root, let e = selectedFirst() else { return }
        let a = NSAlert()
        a.messageText = L("重命名", "Rename")
        let field = NSTextField(string: e.name); field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: L("重命名", "Rename")); a.addButton(withTitle: L("取消", "Cancel"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != e.name, !name.contains("/") else { return }
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.engine.renameEntry(spec: r.spec, e, to: name)
            self.cache.removeAll(); self.reload(force: true)
            self.setInfo(ok ? L("已重命名为「\(name)」", "Renamed to “\(name)”") : L("重命名失败", "Rename failed"))
        }
    }

    private func newFolder() {
        guard let r = root else { return }
        let a = NSAlert()
        a.messageText = L("新建文件夹", "New folder")
        let field = NSTextField(string: L("未命名文件夹", "untitled folder")); field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: L("创建", "Create")); a.addButton(withTitle: L("取消", "Cancel"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces); guard !name.isEmpty else { return }
        let newPath = path.isEmpty ? name : "\(path)/\(name)"
        Task { [weak self] in
            _ = await self?.engine.makeFolder(remote: r.spec, path: newPath)
            self?.cache.removeAll(); self?.reload(force: true)
        }
    }

    private func uploadHere() {
        guard let r = root else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.prompt = L("上传到这里", "Upload here")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        engine.addUploadJobs(sources: panel.urls, destRemote: r.spec, destPath: path)
        setInfo(L("已加入 \(panel.urls.count) 个上传任务", "Queued \(panel.urls.count) upload(s)"))
    }

    private func calcSize(_ e: RemoteEntry) {
        guard let r = root else { return }
        setInfo(L("正在计算「\(e.name)」大小…", "Calculating “\(e.name)”…"))
        Task { [weak self] in
            guard let self, let res = await self.engine.sizePath(remote: r.spec, path: e.path) else { return }
            for i in self.allEntries.indices where self.allEntries[i].path == e.path { self.allEntries[i].size = res.bytes; self.allEntries[i].sizeComputed = true }
            self.applyFilterSort()
            self.setInfo(L("「\(e.name)」= ", "“\(e.name)” = ") + Format.bytes(res.bytes) + L("（\(res.count) 个文件）", " (\(res.count) files)"))
        }
    }

    private func getInfo() {
        guard let r = root, let e = selectedFirst() else { return }
        let vc = InfoSheetVC(entry: e, remote: r.spec, engine: engine) { [weak self] bytes in
            guard let self else { return }
            for i in self.allEntries.indices where self.allEntries[i].path == e.path { self.allEntries[i].size = bytes; self.allEntries[i].sizeComputed = true }
            self.applyFilterSort()
        }
        presentAsSheet(vc)
    }

    private func fileID(for e: RemoteEntry?) async -> String? {
        guard let r = root else { return nil }
        if let e {
            if let id = e.fileID { return id }
            return await engine.driveFolderID(r, path: e.path)
        }
        return await engine.driveFolderID(r, path: path)
    }

    private func shareSelected() {
        guard let r = root else { return }
        let e = selectedFirst()
        Task { [weak self] in
            guard let self else { return }
            guard let fid = await self.fileID(for: e) else { self.setInfo(L("这个位置不能共享", "This location can't be shared")); return }
            let name = e?.name ?? (self.path.isEmpty ? r.title : (self.path as NSString).lastPathComponent)
            self.presentAsSheet(ShareSheetVC(engine: self.engine, remote: r.remote, fileID: fid, name: name, isDir: e?.isDir ?? true))
        }
    }
    private func shareCurrentFolder() {
        guard let r = root else { return }
        Task { [weak self] in
            guard let self, let fid = await self.fileID(for: nil) else { return }
            let name = self.path.isEmpty ? r.title : (self.path as NSString).lastPathComponent
            self.presentAsSheet(ShareSheetVC(engine: self.engine, remote: r.remote, fileID: fid, name: name, isDir: true))
        }
    }

    private func copyLink() {
        guard let r = root, let e = selectedFirst() else { return }
        Task { [weak self] in
            guard let self, let fid = await self.fileID(for: e) else { return }
            let link = (await self.engine.driveFileInfo(remote: r.remote, fileID: fid))?["webViewLink"] as? String
                ?? (e.isDir ? "https://drive.google.com/drive/folders/\(fid)" : "https://drive.google.com/file/d/\(fid)/view")
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string)
            self.setInfo(L("已拷贝链接（别人能否打开取决于共享设置）", "Link copied (whether others can open it depends on sharing)"))
        }
    }

    private func openWeb() {
        guard let e = selectedFirst() else { return }
        Task { [weak self] in
            guard let self, let fid = await self.fileID(for: e) else { return }
            NSWorkspace.shared.open(URL(string: e.isDir ? "https://drive.google.com/drive/folders/\(fid)" : "https://drive.google.com/file/d/\(fid)/view")!)
        }
    }

    // MARK: 打开分享链接

    private func promptOpenLink() {
        guard let drive = engine.remotes.first(where: \.isDrive) else {
            setInfo(L("先在「我的网盘」连接 Google Drive", "Connect Google Drive first (Remotes)")); return
        }
        let a = NSAlert()
        a.messageText = L("打开 Google Drive 分享链接", "Open a Google Drive link")
        a.informativeText = L("粘贴朋友发来的文件夹或文件链接。文件夹会出现在左边「链接」里，可以浏览、预览、下载；有编辑权限还能上传。",
                              "Paste a folder or file link. Folders appear under “Links” on the left to browse, preview and download — and upload, if you can edit.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "https://drive.google.com/drive/folders/…"
        if let s = NSPasteboard.general.string(forType: .string), DriveLink.parse(s) != nil { field.stringValue = s }
        a.accessoryView = field
        a.addButton(withTitle: L("打开", "Open")); a.addButton(withTitle: L("取消", "Cancel"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let parsed = DriveLink.parse(field.stringValue) else { setInfo(L("看不懂这个链接", "That doesn't look like a Drive link")); return }
        spinner.startAnimation(nil)
        setInfo(L("正在打开链接…", "Opening link…"))
        Task { [weak self] in
            guard let self else { return }
            let info = await self.engine.driveFileInfo(remote: drive.name, fileID: parsed.id)
            self.spinner.stopAnimation(nil)
            guard let info else {
                self.setInfo(L("打不开：链接无效，或者你的账号没有访问权限", "Can't open: invalid link, or your account has no access")); return
            }
            let name = info["name"] as? String ?? parsed.id
            if (info["mimeType"] as? String) == "application/vnd.google-apps.folder" {
                let r = BrowseRoot(kind: .link, remote: drive.name, folderID: parsed.id, title: name)
                var links = BrowseRoot.savedLinks; links.removeAll { $0.folderID == parsed.id }; links.insert(r, at: 0)
                BrowseRoot.savedLinks = links
                self.rebuildSources()
                self.open(r, path: "")
                let canAdd = ((info["capabilities"] as? [String: Any])?["canAddChildren"] as? Bool) ?? false
                self.setInfo(canAdd ? L("已打开「\(name)」· 你可以往里上传", "Opened “\(name)” · you can upload here")
                                    : L("已打开「\(name)」· 只读（没有上传权限）", "Opened “\(name)” · read-only"))
            } else {
                let size = (info["size"] as? String).flatMap(Int64.init) ?? 0
                let b = NSAlert()
                b.messageText = L("下载「\(name)」？", "Download “\(name)”?")
                b.informativeText = (size > 0 ? Format.bytes(size) + " · " : "") + L("会保存到「下载」文件夹。", "Saves to your Downloads folder.")
                b.addButton(withTitle: L("下载", "Download")); b.addButton(withTitle: L("取消", "Cancel"))
                guard b.runModal() == .alertFirstButtonReturn else { return }
                let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                self.setInfo(L("正在下载「\(name)」…", "Downloading “\(name)”…"))
                let ok = await self.engine.driveDownloadByID(remote: drive.name, fileID: parsed.id, into: dl)
                self.setInfo(ok ? L("已下载到「下载」：\(name)", "Downloaded to Downloads: \(name)") : L("下载失败（详见运行日志）", "Download failed (see Logs)"))
                if ok { NSWorkspace.shared.activateFileViewerSelecting([dl.appendingPathComponent(name)]) }
            }
        }
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double, default d: Double) -> Double { self == 0 ? d : Swift.min(hi, Swift.max(lo, self)) }
}

// MARK: - 快速预览（图片 / 视频在线播放）

@MainActor
final class PreviewController: NSObject, NSWindowDelegate {
    static let shared = PreviewController()
    private var panel: NSPanel?
    private let imageView = NSImageView()
    private let playerView = AVPlayerView()
    private let iconView = NSImageView()
    private let titleLabel = makeLabel("", size: 13, weight: .semibold)
    private let detailLabel = makeLabel("", size: 11.5, color: .secondaryLabelColor)
    private let spinner = NSProgressIndicator()
    private var engine: QueueEngine?
    private var root: BrowseRoot?
    private var items: [RemoteEntry] = []
    private var meta: [String: DriveFileMeta] = [:]
    private var index = 0
    private var loadToken = 0
    var isVisible: Bool { panel?.isVisible ?? false }

    func show(engine: QueueEngine, root: BrowseRoot, items: [RemoteEntry], index: Int, meta: [String: DriveFileMeta]) {
        self.engine = engine; self.root = root; self.items = items; self.index = index; self.meta = meta
        if panel == nil { build() }
        panel?.makeKeyAndOrderFront(nil)
        load()
    }
    /// 预览开着时，选中别的文件就跟着切换（和访达的空格预览一样）
    func follow(_ e: RemoteEntry?) {
        guard isVisible, let e, !e.isDir, let i = items.firstIndex(where: { $0.path == e.path }), i != index else { return }
        index = i; load()
    }
    func close() { playerView.player?.pause(); panel?.orderOut(nil) }

    private func build() {
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
                         backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true; p.titleVisibility = .hidden
        p.isFloatingPanel = true; p.hidesOnDeactivate = false
        p.appearance = NSAppearance(named: .darkAqua)
        p.backgroundColor = NSColor(white: 0.07, alpha: 1)
        p.delegate = self
        p.onKey = { [weak self] ev in
            switch ev.keyCode {
            case 49, 53: self?.close(); return true
            case 123: self?.step(-1); return true
            case 124: self?.step(1); return true
            default: return false
            }
        }
        let v = NSView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        spinner.style = .spinning; spinner.isDisplayedWhenStopped = false
        let prev = CFButton("", style: .icon, symbol: "chevron.left") { [weak self] in self?.step(-1) }
        let next = CFButton("", style: .icon, symbol: "chevron.right") { [weak self] in self?.step(1) }
        let bar = hstack([prev, next, vstack([titleLabel, detailLabel], spacing: 2), flexibleSpacer()], spacing: 8)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 80, bottom: 0, right: 16)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        for x in [imageView, playerView, iconView, spinner, bar] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: v.topAnchor, constant: 6), bar.heightAnchor.constraint(equalToConstant: 40),
            bar.leadingAnchor.constraint(equalTo: v.leadingAnchor), bar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6), imageView.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -12),
            imageView.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12), imageView.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            playerView.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6), playerView.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: v.leadingAnchor), playerView.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            iconView.centerXAnchor.constraint(equalTo: v.centerXAnchor), iconView.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 160), iconView.heightAnchor.constraint(equalToConstant: 160),
            spinner.centerXAnchor.constraint(equalTo: v.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        p.contentView = v
        p.center()
        panel = p
    }

    private func step(_ d: Int) {
        guard !items.isEmpty else { return }
        index = (index + d + items.count) % items.count
        load()
    }

    private func load() {
        guard let engine, let root, index < items.count else { return }
        let e = items[index]
        loadToken += 1; let token = loadToken
        titleLabel.stringValue = e.name
        var d = [Format.bytes(e.size), FileIcons.kind(e)]
        if let m = e.fileID.flatMap({ meta[$0] }) {
            if let w = m.width, let h = m.height { d.append("\(w)×\(h)") }
            if let ms = m.durationMs { d.append(Format.timecode(Double(ms) / 1000)) }
        }
        detailLabel.stringValue = d.joined(separator: "  ·  ") + "   " + L("（←/→ 切换，空格关闭）", "(←/→ to switch, Space to close)")
        playerView.player?.pause(); playerView.player = nil
        imageView.image = nil
        imageView.isHidden = true; playerView.isHidden = true; iconView.isHidden = true
        spinner.startAnimation(nil)
        if e.isVideo, let url = engine.serveURL(spec: root.spec, path: e.path) {
            // 视频：通过本机 rclone 边下边播（支持拖动进度条）
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": engine.serveHeaders])
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            playerView.player = player
            playerView.isHidden = false
            spinner.stopAnimation(nil)
            player.play()
            return
        }
        if e.isImage {
            Task { [weak self] in
                guard let self else { return }
                var img: NSImage? = nil
                if let fid = e.fileID, let link = self.meta[fid]?.thumbnailLink {
                    img = await engine.driveThumbnail(remote: root.remote, fileID: fid, link: link, px: 2000)
                }
                if img == nil, let lp = await engine.localPath(remote: root.remote, path: e.path) { img = NSImage(contentsOfFile: lp) }
                if img == nil, e.size < 120_000_000, let url = engine.serveURL(spec: root.spec, path: e.path) {
                    var req = URLRequest(url: url); req.timeoutInterval = 120
                    for (k, v) in engine.serveHeaders { req.setValue(v, forHTTPHeaderField: k) }
                    if let (data, _) = try? await URLSession.shared.data(for: req) { img = NSImage(data: data) }
                }
                guard token == self.loadToken else { return }
                self.spinner.stopAnimation(nil)
                if let img { self.imageView.image = img; self.imageView.isHidden = false } else { self.showIcon(e) }
            }
            return
        }
        spinner.stopAnimation(nil)
        showIcon(e)
    }

    private func showIcon(_ e: RemoteEntry) { iconView.image = FileIcons.icon(for: e); iconView.isHidden = false }

    func windowWillClose(_ notification: Notification) { playerView.player?.pause() }
}

/// 能接收方向键/空格的预览窗
final class KeyPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
}

// MARK: - 共享面板

@MainActor
final class ShareSheetVC: NSViewController {
    private let engine: QueueEngine
    private let remote: String
    private let fileID: String
    private let name: String
    private let isDir: Bool
    private var perms: [DrivePermission] = []
    private let peopleStack = NSStackView()
    private let generalPopup = NSPopUpButton()
    private let emailField = NSTextField()
    private let rolePopup = NSPopUpButton()
    private let notifyCheck = NSButton(checkboxWithTitle: L("发邮件通知对方", "Notify by email"), target: nil, action: nil)
    private let status = makeLabel("", size: 11.5, color: .secondaryLabelColor)
    private var link = ""

    init(engine: QueueEngine, remote: String, fileID: String, name: String, isDir: Bool) {
        self.engine = engine; self.remote = remote; self.fileID = fileID; self.name = name; self.isDir = isDir
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 520)) }

    override func viewDidLoad() {
        super.viewDidLoad()
        let title = makeLabel(L("共享「\(name)」", "Share “\(name)”"), size: 16, weight: .bold)
        title.lineBreakMode = .byTruncatingMiddle
        let addTitle = makeLabel(L("添加人员", "Add people"), size: 12.5, weight: .semibold)
        emailField.placeholderString = L("对方的 Gmail 邮箱", "Their Google email")
        emailField.translatesAutoresizingMaskIntoConstraints = false
        rolePopup.addItems(withTitles: [L("可查看", "Viewer"), L("可评论", "Commenter"), L("可编辑", "Editor")])
        rolePopup.selectItem(at: isDir ? 2 : 0)
        notifyCheck.state = .on
        let send = CFButton(L("发送邀请", "Invite"), style: .primary, size: .small) { [weak self] in self?.invite() }
        let addRow = hstack([emailField, rolePopup, send], spacing: 8)
        emailField.widthAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true

        let peopleTitle = makeLabel(L("有访问权限的人", "People with access"), size: 12.5, weight: .semibold)
        peopleStack.orientation = .vertical; peopleStack.alignment = .leading; peopleStack.spacing = 4

        let generalTitle = makeLabel(L("常规访问（链接）", "General access (link)"), size: 12.5, weight: .semibold)
        generalPopup.addItems(withTitles: [L("仅限受邀的人", "Restricted"), L("任何获得链接的人 · 可查看", "Anyone with the link · Viewer"),
                                           L("任何获得链接的人 · 可编辑", "Anyone with the link · Editor")])
        generalPopup.target = self; generalPopup.action = #selector(generalChanged)
        let copy = CFButton(L("复制链接", "Copy link"), style: .secondary, size: .small, symbol: "link") { [weak self] in self?.copyLink() }

        let note = captionLabel(L("空间算谁的：在 Google Drive 里，文件占用「上传者（文件所有者）」的空间。朋友往你共享的文件夹里上传，占的是朋友自己的空间；你往朋友的文件夹里上传，占的是你的空间。",
                                  "Storage: in Google Drive, files count against the uploader's (owner's) storage. Friends uploading into your shared folder use their own quota; you uploading into theirs uses yours."),
                                maxWidth: 470)
        let done = CFButton(L("完成", "Done"), style: .secondary) { [weak self] in self?.dismiss(nil) }
        let col = vstack([title, generalTitle, hstack([generalPopup, copy], spacing: 8), HairlineView(),
                          addTitle, addRow, notifyCheck, HairlineView(), peopleTitle, peopleStack, note,
                          hstack([status, flexibleSpacer(), done], spacing: 8)], spacing: 10)
        col.setCustomSpacing(16, after: title)
        col.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: view.topAnchor, constant: 22), col.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            col.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), col.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
        ])
        for v in col.arrangedSubviews where v is HairlineView || v is NSStackView { v.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true }
        refresh()
    }

    private func refresh() {
        status.stringValue = L("正在读取共享设置…", "Loading sharing settings…")
        Task { [weak self] in
            guard let self else { return }
            async let p = self.engine.drivePermissions(remote: self.remote, fileID: self.fileID)
            async let info = self.engine.driveFileInfo(remote: self.remote, fileID: self.fileID)
            let (perms, meta) = await (p, info)
            self.link = meta?["webViewLink"] as? String ?? ""
            guard let perms else {
                self.status.stringValue = L("读取不到共享设置（可能只有所有者能看）", "Can't read sharing (only the owner may see it)"); return
            }
            self.perms = perms
            self.status.stringValue = ""
            let anyone = perms.first { $0.type == "anyone" }
            self.generalPopup.selectItem(at: anyone == nil ? 0 : (anyone!.role == "writer" ? 2 : 1))
            self.peopleStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for p in perms where p.type != "anyone" {
                let who = makeLabel(p.who, size: 12.5); who.lineBreakMode = .byTruncatingMiddle
                who.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let role = makeLabel(p.roleLabel, size: 12, color: .secondaryLabelColor)
                var row: [NSView] = [who, flexibleSpacer(), role]
                if p.role != "owner" {
                    let pid = p.id
                    row.append(CFButton(L("移除", "Remove"), style: .danger, size: .small) { [weak self] in self?.remove(pid) })
                }
                let h = hstack(row, spacing: 8)
                self.peopleStack.addArrangedSubview(h)
                h.widthAnchor.constraint(equalTo: self.peopleStack.widthAnchor).isActive = true
            }
        }
    }

    @objc private func generalChanged() {
        let want = generalPopup.indexOfSelectedItem
        status.stringValue = L("正在保存…", "Saving…")
        Task { [weak self] in
            guard let self else { return }
            var err: String? = nil
            if let cur = self.perms.first(where: { $0.type == "anyone" }) { err = await self.engine.driveUnshare(remote: self.remote, fileID: self.fileID, permissionID: cur.id) }
            if err == nil, want > 0 { err = await self.engine.driveShare(remote: self.remote, fileID: self.fileID, type: "anyone", role: want == 2 ? "writer" : "reader") }
            if let err { self.status.stringValue = err } else { self.refresh() }
            if err == nil && want > 0 { self.copyLink() }
        }
    }

    private func invite() {
        let email = emailField.stringValue.trimmingCharacters(in: .whitespaces)
        guard email.contains("@") else { status.stringValue = L("请填写对方的邮箱", "Enter an email address"); return }
        let role = ["reader", "commenter", "writer"][rolePopup.indexOfSelectedItem]
        status.stringValue = L("正在发送…", "Sending…")
        Task { [weak self] in
            guard let self else { return }
            if let err = await self.engine.driveShare(remote: self.remote, fileID: self.fileID, type: "user", role: role, email: email, notify: self.notifyCheck.state == .on) {
                self.status.stringValue = err
            } else {
                self.emailField.stringValue = ""
                self.refresh()
                self.status.stringValue = L("已共享给 \(email)", "Shared with \(email)")
            }
        }
    }

    private func remove(_ pid: String) {
        Task { [weak self] in
            guard let self else { return }
            if let err = await self.engine.driveUnshare(remote: self.remote, fileID: self.fileID, permissionID: pid) { self.status.stringValue = err }
            else { self.refresh() }
        }
    }

    private func copyLink() {
        let l = link.isEmpty ? (isDir ? "https://drive.google.com/drive/folders/\(fileID)" : "https://drive.google.com/file/d/\(fileID)/view") : link
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(l, forType: .string)
        status.stringValue = L("链接已复制，可以直接发给朋友", "Link copied — paste it to your friend")
    }
}

// MARK: - Get Info sheet

@MainActor
final class InfoSheetVC: NSViewController {
    private let entry: RemoteEntry
    private let remote: String
    private let engine: QueueEngine
    private let onSized: (Int64) -> Void
    private let sizeValue = makeLabel("", size: 13, weight: .medium)
    private let spinner = NSProgressIndicator()

    init(entry: RemoteEntry, remote: String, engine: QueueEngine, onSized: @escaping (Int64) -> Void) {
        self.entry = entry; self.remote = remote; self.engine = engine; self.onSized = onSized
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260)) }

    override func viewDidLoad() {
        super.viewDidLoad()
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: entry.isDir ? "folder.fill" : "doc", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 34, weight: .regular)
        icon.contentTintColor = Theme.accent
        let name = makeLabel(entry.name, size: 16, weight: .bold, multiline: true)

        sizeValue.stringValue = entry.isDir ? (entry.sizeComputed ? Format.bytes(entry.size) : L("（未计算）", "(not calculated)")) : Format.bytes(entry.size)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isHidden = true

        var rows: [NSView] = [
            infoRow(L("类型", "Kind"), entry.isDir ? L("文件夹", "Folder") : ((entry.name as NSString).pathExtension.uppercased() + " " + L("文件", "file"))),
            infoRow(L("位置", "Where"), "\(remote):\(entry.path)"),
            infoRow(L("修改时间", "Modified"), Format.dateShort(entry.modTime)),
        ]
        let sizeRow = hstack([makeLabel(L("大小", "Size") + "：", size: 12, color: .secondaryLabelColor), sizeValue, spinner, flexibleSpacer()])
        rows.append(sizeRow)
        if entry.isDir {
            let calc = NSButton(title: L("计算大小", "Calculate size"), target: nil, action: nil)
            calc.bezelStyle = .rounded; calc.controlSize = .small
            calc.onAction { [weak self] in self?.calculate() }
            rows.append(hstack([calc, flexibleSpacer()]))
        }

        let close = NSButton(title: L("完成", "Done"), target: nil, action: nil)
        close.bezelStyle = .rounded; close.keyEquivalent = "\r"
        close.onAction { [weak self] in self.map { $0.dismiss($0) } }

        let stack = vstack([hstack([icon, name]), divider()] + rows + [hstack([flexibleSpacer(), close])], spacing: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])
        for r in rows { r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    private func infoRow(_ k: String, _ v: String) -> NSView {
        let kl = makeLabel(k + "：", size: 12, color: .secondaryLabelColor)
        kl.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let vl = makeLabel(v, size: 12, multiline: true); vl.isSelectable = true
        return hstack([kl, vl])
    }

    private func calculate() {
        spinner.isHidden = false; spinner.startAnimation(nil)
        sizeValue.stringValue = L("计算中…", "Calculating…")
        let rn = remote, p = entry.path
        Task { [weak self] in
            let r = await self?.engine.sizePath(remote: rn, path: p)
            self?.spinner.stopAnimation(nil); self?.spinner.isHidden = true
            if let r {
                self?.sizeValue.stringValue = Format.bytes(r.bytes) + L("（\(r.count) 个文件）", " (\(r.count) files)")
                self?.onSized(r.bytes)
            } else {
                self?.sizeValue.stringValue = L("计算失败", "Failed")
            }
        }
    }
}
