import AppKit
import Combine

enum AppSection: String, CaseIterable {
    case transfers, history, remotes, browse, speedtest, settings, log, help
    var title: String {
        switch self {
        case .transfers: return L("传输队列", "Transfers")
        case .history: return L("历史记录", "History")
        case .remotes: return L("我的网盘", "Remotes")
        case .browse: return L("浏览网盘", "Browse")
        case .speedtest: return L("测速与推荐", "Speed test")
        case .settings: return L("上传设置", "Settings")
        case .log: return L("运行日志", "Logs")
        case .help: return L("帮助 / 关于", "Help / About")
        }
    }
    var icon: String {
        switch self {
        case .transfers: return "arrow.up.arrow.down.circle"
        case .history: return "clock.arrow.circlepath"
        case .remotes: return "cloud"
        case .browse: return "folder"
        case .speedtest: return "speedometer"
        case .settings: return "slider.horizontal.3"
        case .log: return "terminal"
        case .help: return "questionmark.circle"
        }
    }
    // 侧边栏分组
    static let groups: [(String, [AppSection])] = [
        (L("备份", "BACKUP"), [.transfers, .history, .remotes, .browse]),
        (L("调优", "TUNING"), [.speedtest, .settings]),
        (L("系统", "SYSTEM"), [.log, .help]),
    ]
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = QueueEngine()
    var windowController: MainWindowController!
    private var statusItem: NSStatusItem?
    private var statusHeaderItem: NSMenuItem?
    private var pauseItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()

    private var rootSplit: RootSplitVC? { windowController?.window?.contentViewController as? RootSplitVC }

    // 菜单栏面板打开期间每秒刷新（菜单追踪时普通 RunLoop 不跑，要用 .common 模式）
    func menuWillOpen(_ menu: NSMenu) {
        statusPanel.update(engine, structural: true)
        menu.items.first?.view = statusPanel
        menuTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.statusPanel.update(self.engine, structural: false)
                self.updateStatusItem()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        menuTimer = t
    }
    func menuDidClose(_ menu: NSMenu) { menuTimer?.invalidate(); menuTimer = nil }
    private var pendingOpenURLs: [URL] = []
    private var didLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.url(forResource: "CloudFerry", withExtension: "icns") == nil {
            NSApp.applicationIconImage = makeLogoImage(size: 512)
        }
        engine.loadIfNeeded()
        setupMainMenu()
        setupStatusItem()
        windowController = MainWindowController(engine: engine)
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(forName: .cfLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setupMainMenu()
                self?.rebuildStatusMenu()
                self?.engine.relocalizeStatus()
            }
        }
        NotificationCenter.default.addObserver(forName: .cfShowMainWindow, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showMainWindow() }
        }
        didLaunch = true
        Task {
            await engine.bootstrap()
            if !pendingOpenURLs.isEmpty { let u = pendingOpenURLs; pendingOpenURLs = []; handleOpened(u) }
        }
        AppTheme.apply()   // 外观：跟随系统 / 浅色 / 深色 / 深色玻璃（调试可用 CLOUDFERRY_THEME 指定）
        if let snap = ProcessInfo.processInfo.environment["CLOUDFERRY_SNAPSHOT"] { runSnapshots(to: snap) }
    }

    // 关窗后后台常驻（传输不中断），可从菜单栏 / Dock 重新打开
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController.showWindow(nil); NSApp.activate(ignoringOtherApps: true) }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { engine.shutdown() }

    /// 正在传输时退出要确认：退出会中断，正在传的大文件下次会从头传
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let job = engine.activeJob else { return .terminateNow }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = L("正在传输，确定退出吗？", "A transfer is running. Quit anyway?")
        a.informativeText = L("「\(job.sourceLabel)」正在传输（\(Int(job.progress * 100))%）。退出会中断传输：已传完的文件不受影响，下次打开会自动续传，但正在传的那个大文件要从头传。\n\n只想关窗口的话，点左上角红色按钮即可，传输会在后台继续。",
                              "“\(job.sourceLabel)” is transferring (\(Int(job.progress * 100))%). Quitting interrupts it: finished files are safe and the queue resumes next launch, but the file in flight restarts from zero.\n\nTo just close the window, use the red button — transfers keep running in the background.")
        a.addButton(withTitle: L("继续传输", "Keep transferring"))
        a.addButton(withTitle: L("退出", "Quit"))
        return a.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    /// 把文件夹/储存卡拖到 Dock 图标上，或在访达里「打开方式 → CloudFerry」= 备份到默认网盘
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return }
        if !didLaunch || !engine.ready { pendingOpenURLs += files; return }
        handleOpened(files)
    }

    /// 打开的文件里如果有 Google 下载的 client_secret_….json：交给「换成你自己的通道」向导自动导入并开始连接
    /// （也避免把这个含密钥的文件误当成要上传的文件）。其余文件照常询问是否备份。
    private func handleOpened(_ urls: [URL]) {
        var rest: [URL] = []
        for u in urls {
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if u.pathExtension.lowercased() == "json", size > 0, size < 64_000,
               let d = try? Data(contentsOf: u), case .success(let creds) = GoogleClientCredentials.parse(jsonData: d) {
                showMainWindow()
                engine.addLog(.info, L("已从文件导入 Google 凭据：", "Imported Google credentials from: ") + u.lastPathComponent)
                rootSplit?.openClientSetup(nil, credentials: creds, sourceName: u.lastPathComponent, autoConnect: true)
            } else {
                rest.append(u)
            }
        }
        if !rest.isEmpty { confirmUpload(rest) }
    }

    private func confirmUpload(_ urls: [URL]) {
        showMainWindow()
        rootSplit?.selectSection(.transfers)
        guard let remote = engine.defaultDestRemote, !remote.isEmpty else {
            let a = NSAlert()
            a.messageText = L("请先连接网盘", "Connect a remote first")
            a.informativeText = L("还没有设置备份目的地。请到「我的网盘」连接 Google Drive。", "No backup destination yet. Connect Google Drive under Remotes.")
            a.runModal(); return
        }
        let a = NSAlert()
        a.messageText = L("备份 \(urls.count) 个项目到网盘？", "Back up \(urls.count) item(s)?")
        a.informativeText = urls.prefix(6).map { "• " + $0.lastPathComponent }.joined(separator: "\n")
            + (urls.count > 6 ? "\n…" : "") + "\n\n→ \(remote):\(engine.defaultDestPath)"
        a.addButton(withTitle: L("加入队列", "Add to queue"))
        a.addButton(withTitle: L("取消", "Cancel"))
        if a.runModal() == .alertFirstButtonReturn {
            engine.addUploadJobs(sources: urls, destRemote: remote, destPath: engine.defaultDestPath)
        }
    }

    /// 调试用：把每个页面渲染成 PNG（CLOUDFERRY_SNAPSHOT=<目录>），用于自动检查界面，不需要屏幕录制权限
    private func runSnapshots(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sections = (ProcessInfo.processInfo.environment["CLOUDFERRY_SNAPSHOT_SECTIONS"] ?? "")
            .split(separator: ",").compactMap { AppSection(rawValue: String($0)) }
        let list = sections.isEmpty ? AppSection.allCases : sections
        Task { @MainActor in
            if let hs = ProcessInfo.processInfo.environment["CLOUDFERRY_SNAPSHOT_SIZE"] {
                let parts = hs.split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { windowController.window?.setContentSize(NSSize(width: parts[0], height: parts[1])) }
            }
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            func render(_ v: NSView, _ name: String) {
                v.layoutSubtreeIfNeeded()
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds),
                   let out = v.bitmapImageRepForCachingDisplay(in: v.bounds),
                   let ctx = NSGraphicsContext(bitmapImageRep: out) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = ctx
                    v.effectiveAppearance.performAsCurrentDrawingAppearance {
                        NSColor.windowBackgroundColor.setFill()
                        NSRect(origin: .zero, size: v.bounds.size).fill()
                    }
                    rep.draw(in: NSRect(origin: .zero, size: v.bounds.size), from: .zero, operation: .sourceOver,
                             fraction: 1, respectFlipped: true, hints: nil)
                    NSGraphicsContext.restoreGraphicsState()
                    try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
                }
            }
            if ProcessInfo.processInfo.environment["CLOUDFERRY_SNAPSHOT_MENUBAR"] != nil {
                // 菜单栏下拉面板（放在菜单同款毛玻璃底上渲染）
                statusPanel.update(engine, structural: true)
                let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: statusPanel.frame.size))
                bg.material = .menu; bg.blendingMode = .withinWindow; bg.state = .active
                statusPanel.frame.origin = .zero
                bg.addSubview(statusPanel)
                let w = NSWindow(contentRect: bg.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                w.contentView = bg
                w.orderBack(nil)
                try? await Task.sleep(nanoseconds: 600_000_000)
                render(bg, "menubar-panel")
            }
            if ProcessInfo.processInfo.environment["CLOUDFERRY_SNAPSHOT_WIZARD"] != nil {
                let vc = ClientSetupVC(engine: engine)
                let w = NSWindow(contentViewController: vc)
                w.setContentSize(NSSize(width: 700, height: 1180))
                w.orderBack(nil)
                try? await Task.sleep(nanoseconds: 800_000_000)
                if let v = w.contentView { render(v, "clientsetup") }
                w.close()
            }
            for s in list {
                rootSplit?.selectSection(s)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard let v = windowController.window?.contentView else { continue }
                v.layoutSubtreeIfNeeded()
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds),
                   let out = v.bitmapImageRepForCachingDisplay(in: v.bounds),
                   let ctx = NSGraphicsContext(bitmapImageRep: out) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    // 先铺窗口背景色（离屏渲染不会画窗口背景），再叠上内容
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = ctx
                    v.effectiveAppearance.performAsCurrentDrawingAppearance {
                        NSColor.windowBackgroundColor.setFill()
                        NSRect(origin: .zero, size: v.bounds.size).fill()
                    }
                    rep.draw(in: NSRect(origin: .zero, size: v.bounds.size), from: .zero, operation: .sourceOver,
                             fraction: 1, respectFlipped: true, hints: nil)
                    NSGraphicsContext.restoreGraphicsState()
                    try? out.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: "\(dir)/\(s.rawValue).png"))
                }
            }
            if ProcessInfo.processInfo.environment["CLOUDFERRY_SNAPSHOT_WINDOW"] != nil, let w = windowController.window {
                if let sec = ProcessInfo.processInfo.environment["CLOUDFERRY_SECTION"].flatMap({ AppSection(rawValue: $0) }) {
                    rootSplit?.selectSection(sec)
                }
                w.orderFrontRegardless()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if let img = captureOwnWindow(w) {
                    let rep = NSBitmapImageRep(cgImage: img)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/window-\(AppTheme.current.rawValue).png"))
                    FileHandle.standardError.write(Data("WINDOW_CAPTURED \(img.width)x\(img.height)\n".utf8))
                } else {
                    FileHandle.standardError.write(Data("WINDOW_CAPTURE_FAILED\n".utf8))
                }
            }
            FileHandle.standardError.write(Data("SNAPSHOT_DONE\n".utf8))
            engine.shutdown()
            exit(0)
        }
    }

    // MARK: 菜单栏常驻图标（v1.3：单色模板图标 + 实时状态面板）

    private let statusPanel = StatusPanelView()
    private var menuTimer: Timer?

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = menuBarGlyph(.idle)
        item.button?.imagePosition = .imageLeading
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        item.button?.toolTip = "CloudFerry"
        statusItem = item
        rebuildStatusMenu()
        engine.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.updateStatusItem() }.store(in: &cancellables)
    }

    private func menuItem(_ title: String, _ symbol: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return it
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let panelItem = NSMenuItem()
        panelItem.view = statusPanel
        menu.addItem(panelItem)
        menu.addItem(.separator())
        pauseItem = menuItem(L("全部暂停", "Pause all"), "pause.fill", #selector(togglePause))
        menu.addItem(pauseItem!)
        menu.addItem(menuItem(L("新建任务…", "New transfer…"), "plus", #selector(statusNewTransfer)))
        menu.addItem(.separator())
        menu.addItem(menuItem(L("打开 CloudFerry", "Open CloudFerry"), "macwindow", #selector(showMainWindow)))
        menu.addItem(menuItem(L("历史记录", "History"), "clock.arrow.circlepath", #selector(statusHistory)))
        menu.addItem(menuItem(L("设置…", "Settings…"), "gearshape", #selector(statusSettings), key: ","))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("退出 CloudFerry", "Quit CloudFerry"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)
        statusItem?.menu = menu
        statusPanel.update(engine, structural: true)
        updateStatusItem()
    }

    @objc private func togglePause() { engine.globalPaused ? engine.resumeAll() : engine.pauseAll() }
    @objc private func showMainWindow() { windowController.showWindow(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func statusNewTransfer() { showMainWindow(); rootSplit?.newTransfer() }
    @objc private func statusHistory() { showMainWindow(); rootSplit?.selectSection(.history) }
    @objc private func statusSettings() { showMainWindow(); rootSplit?.selectSection(.settings) }

    private var lastBadge: String? = "__"
    private func updateStatusItem() {
        var badge: String? = nil
        let failed = engine.jobs.contains(where: { $0.status == .failed })
        let button = statusItem?.button
        if engine.globalPaused && (engine.activeJob != nil || engine.queuedCount > 0 || engine.jobs.contains { $0.status == .paused }) {
            button?.image = menuBarGlyph(.paused)
            button?.title = ""
        } else if let job = engine.activeJob {
            button?.image = menuBarGlyph(.active)
            button?.title = " " + Format.speed(job.speed)
            if job.hasSizeInfo { badge = "\(Int(job.progress * 100))%" } else { badge = "…" }
        } else if engine.queuedCount > 0 {
            button?.image = menuBarGlyph(.idle)
            button?.title = " \(engine.queuedCount)"
            badge = "\(engine.queuedCount)"
        } else {
            button?.image = menuBarGlyph(failed ? .failed : .idle)
            button?.title = failed ? " !" : ""
        }
        if failed && engine.activeJob == nil { badge = "!" }
        // Dock 图标角标：传输进度 / 排队数 / 有失败
        if badge != lastBadge { lastBadge = badge; NSApp.dockTile.badgeLabel = badge }
        pauseItem?.title = engine.globalPaused ? L("全部继续", "Resume all") : L("全部暂停", "Pause all")
        pauseItem?.image = NSImage(systemSymbolName: engine.globalPaused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
    }

    // MARK: 主菜单 + 快捷键

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App 菜单
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("关于 CloudFerry", "About CloudFerry"), action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("设置…", "Preferences…"), action: #selector(showPreferences), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("隐藏 CloudFerry", "Hide CloudFerry"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L("退出 CloudFerry", "Quit CloudFerry"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // 文件
        let fileItem = NSMenuItem(); mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: L("文件", "File"))
        fileMenu.addItem(withTitle: L("新建任务…", "New Transfer…"), action: #selector(menuNewTransfer), keyEquivalent: "n").target = self
        fileMenu.addItem(withTitle: L("连接 Google Drive…", "Connect Google Drive…"), action: #selector(menuConnect), keyEquivalent: "").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L("刷新", "Refresh"), action: #selector(menuRefresh), keyEquivalent: "r").target = self
        fileMenu.addItem(withTitle: L("在当前处搜索", "Find"), action: #selector(menuFind), keyEquivalent: "f").target = self
        fileItem.submenu = fileMenu

        // 编辑
        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: L("编辑", "Edit"))
        editMenu.addItem(withTitle: L("剪切", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("拷贝", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("粘贴", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("全选", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        // 视图
        let viewItem = NSMenuItem(); mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: L("视图", "View"))
        let palette = viewMenu.addItem(withTitle: L("命令面板…", "Command Palette…"), action: #selector(menuPalette), keyEquivalent: "k")
        palette.target = self
        viewMenu.addItem(.separator())
        for (i, s) in AppSection.allCases.enumerated() {
            let it = viewMenu.addItem(withTitle: s.title, action: #selector(menuSelectSection(_:)), keyEquivalent: "\(i + 1)")
            it.tag = i; it.target = self
        }
        viewMenu.addItem(.separator())
        let toggle = viewMenu.addItem(withTitle: L("显示/隐藏侧边栏", "Toggle Sidebar"), action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        toggle.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu

        // 窗口
        let windowItem = NSMenuItem(); mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: L("窗口", "Window"))
        windowMenu.addItem(withTitle: L("最小化", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("缩放", "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: L("关闭", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        let credits = NSAttributedString(
            string: L("基于开源 rclone 的原生 macOS 图形前端。\n为摄影师的储存卡备份而生。",
                      "A native macOS GUI for the open-source rclone.\nBuilt for photographers backing up camera cards."),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "CloudFerry",
            .applicationVersion: AppInfo.version,
            .version: engine.rcloneVersion.isEmpty ? "" : "rclone \(engine.rcloneVersion)",
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func showPreferences() { rootSplit?.selectSection(.settings) }
    @objc private func menuNewTransfer() { rootSplit?.newTransfer() }
    @objc private func menuConnect() { rootSplit?.connectDrive() }
    @objc private func menuRefresh() { rootSplit?.refreshCurrent() }
    @objc private func menuFind() { rootSplit?.focusSearch() }
    @objc private func menuPalette() { rootSplit?.showPalette() }
    @objc private func menuSelectSection(_ sender: NSMenuItem) {
        let all = AppSection.allCases
        if sender.tag >= 0, sender.tag < all.count { rootSplit?.selectSection(all[sender.tag]) }
    }
}

@MainActor
final class MainWindowController: NSWindowController {
    init(engine: QueueEngine) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "CloudFerry"
        window.titleVisibility = .hidden          // 标题文字不画出来（否则会和侧边栏重叠）
        window.minSize = NSSize(width: 960, height: 640)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = false
        window.contentViewController = RootSplitVC(engine: engine)
        super.init(window: window)
        // 记忆窗口大小/位置；首次启动才居中
        window.setFrameAutosaveName("CloudFerryMain")
        if window.frame.origin == .zero { window.center() }
    }
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class RootSplitVC: NSSplitViewController {
    let engine: QueueEngine
    private var contentVCs: [AppSection: NSViewController] = [:]
    private let container = ContainerVC()
    private var sidebar: SidebarVC!
    private(set) var currentSection: AppSection = .transfers

    var currentVC: NSViewController? { contentVCs[currentSection] }

    init(engine: QueueEngine) {
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        sidebar = SidebarVC(engine: engine) { [weak self] section in self?.selectSection(section) }

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 208
        sidebarItem.maximumThickness = 248
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(viewController: container)
        addSplitViewItem(contentItem)

        let restored = UserDefaults.standard.string(forKey: "cf.section").flatMap { AppSection(rawValue: $0) }
        let envSection = ProcessInfo.processInfo.environment["CLOUDFERRY_SECTION"].flatMap { AppSection(rawValue: $0) }
        selectSection(envSection ?? restored ?? .transfers)

        NotificationCenter.default.addObserver(forName: .cfLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sidebar.relocalize()
                self.contentVCs.removeAll()
                self.selectSection(self.currentSection)
            }
        }
    }

    func selectSection(_ section: AppSection) {
        currentSection = section
        UserDefaults.standard.set(section.rawValue, forKey: "cf.section")
        let vc = contentVCs[section] ?? make(section)
        contentVCs[section] = vc
        container.setContent(vc)
        sidebar.setSelected(section)
    }

    // 菜单/快捷键入口
    func newTransfer() { selectSection(.transfers); (currentVC as? TransfersVC)?.presentNewSheet() }
    func connectDrive() { selectSection(.remotes); (currentVC as? RemotesVC)?.presentAddRemote() }
    /// 「换成你自己的 Google 通道」向导
    func openClientSetup(_ remote: String? = nil, credentials: GoogleClientCredentials? = nil,
                         sourceName: String? = nil, autoConnect: Bool = false) {
        selectSection(.remotes)
        currentVC?.presentAsModalWindow(ClientSetupVC(engine: engine, preselect: remote, prefill: credentials,
                                                      prefillSource: sourceName, autoConnect: autoConnect))
    }
    /// 授权失效时：还在用公用通道 → 打开向导；已是自己的通道 → 普通重新连接
    func reconnectBestWay() {
        let target = engine.remote(named: engine.defaultDestRemote ?? "") ?? engine.remotes.first(where: { $0.isDrive })
        if let t = target, t.isDrive, !t.usesOwnClient { openClientSetup(t.name) } else { connectDrive() }
    }
    func refreshCurrent() { (currentVC as? Refreshable)?.refreshOnShow() }
    func focusSearch() { selectSection(.browse); (currentVC as? BrowseVC)?.focusSearch() }
    func showPalette() { CommandPalette.present(in: self, engine: engine) }

    private func make(_ section: AppSection) -> NSViewController {
        switch section {
        case .transfers: return TransfersVC(engine: engine)
        case .history: return HistoryVC(engine: engine)
        case .remotes: return RemotesVC(engine: engine)
        case .browse: return BrowseVC(engine: engine)
        case .speedtest: return SpeedTestVC(engine: engine)
        case .settings: return SettingsVC(engine: engine)
        case .log: return LogVC(engine: engine)
        case .help: return HelpVC(engine: engine)
        }
    }
}

@MainActor
protocol Refreshable: AnyObject { func refreshOnShow() }

@MainActor
final class ContainerVC: NSViewController {
    private var current: NSViewController?
    override func loadView() { view = BackdropView() }

    func setContent(_ vc: NSViewController) {
        if current === vc { (vc as? Refreshable)?.refreshOnShow(); return }
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: view.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            vc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        current = vc
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { fadeIn(vc.view) }
        (vc as? Refreshable)?.refreshOnShow()
    }
}

@MainActor
final class SidebarVC: NSViewController {
    let engine: QueueEngine
    let onSelect: (AppSection) -> Void
    private var items: [AppSection: SidebarItem] = [:]
    private var groupLabels: [(NSTextField, Int)] = []
    private let statusDot = NSView()
    private let statusLabel = makeLabel("", size: 11.5, weight: .medium, color: .secondaryLabelColor)
    private let pathLabel = makeLabel("", size: 10.5, color: .tertiaryLabelColor, mono: true)
    private let themeButton = CFButton("", style: .icon, symbol: AppTheme.current.symbol)
    private var cancellables = Set<AnyCancellable>()

    init(engine: QueueEngine, onSelect: @escaping (AppSection) -> Void) {
        self.engine = engine
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // 侧边栏用系统「侧边栏材质」：深色下是磨砂半透明，透出一点桌面颜色（和访达一致）
    /// 侧边栏内容实际放在这里（macOS 26+ 是一块悬浮的 Liquid Glass 面板）
    private var panel: NSView!

    override func loadView() {
        let root = BackdropView()
        if #available(macOS 26.0, *) {
            // 悬浮玻璃面板：四周留 8pt，圆角 18，红黄绿按钮落在面板里（和 macOS 26 的访达一致）
            let glass = NSGlassEffectView()
            glass.cornerRadius = 18
            glass.style = .regular
            glass.tintColor = NSColor(srgbRed: 0.03, green: 0.05, blue: 0.06, alpha: 0.18)
            glass.translatesAutoresizingMaskIntoConstraints = false
            let inner = NSView()
            glass.contentView = inner
            inner.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(glass)
            NSLayoutConstraint.activate([
                glass.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
                glass.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
                glass.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
                glass.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
                inner.topAnchor.constraint(equalTo: glass.topAnchor), inner.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
                inner.leadingAnchor.constraint(equalTo: glass.leadingAnchor), inner.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            ])
            panel = inner
        } else {
            let v = NSVisualEffectView()
            v.material = .sidebar
            v.blendingMode = .behindWindow
            v.state = .followsWindowActiveState
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: root.topAnchor), v.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: root.leadingAnchor), v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
            panel = v
        }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 品牌区：放在窗口红黄绿按钮的下方（顶部留 52pt），不再和它们重叠
        let logo = NSImageView(image: makeLogoImage(size: 30))
        logo.wantsLayer = true; logo.layer?.cornerRadius = 7; logo.layer?.masksToBounds = true
        logo.widthAnchor.constraint(equalToConstant: 30).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let name = makeLabel("CloudFerry", size: 15, weight: .bold)
        let tag = makeLabel(L("储存卡 → 云端", "Cards → cloud"), size: 11, color: .tertiaryLabelColor)
        let brand = hstack([logo, vstack([name, tag], spacing: 0)], spacing: 10)

        var navChildren: [NSView] = []
        for (gi, group) in AppSection.groups.enumerated() {
            let header = NSTextField(labelWithString: "")
            header.attributedStringValue = sidebarGroupTitle(gi, group.0)
            groupLabels.append((header, gi))
            let headerWrap = NSView(); headerWrap.translatesAutoresizingMaskIntoConstraints = false
            header.translatesAutoresizingMaskIntoConstraints = false
            headerWrap.addSubview(header)
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: headerWrap.leadingAnchor, constant: 10),
                header.bottomAnchor.constraint(equalTo: headerWrap.bottomAnchor, constant: -4),
                headerWrap.heightAnchor.constraint(equalToConstant: gi == 0 ? 22 : 34),
            ])
            navChildren.append(headerWrap)
            for section in group.1 {
                let it = SidebarItem(symbol: section.icon, title: section.title)
                it.onClick = { [weak self] in self?.onSelect(section) }
                items[section] = it
                navChildren.append(it)
            }
        }
        let nav = vstack(navChildren, spacing: 2)
        nav.translatesAutoresizingMaskIntoConstraints = false
        for v in navChildren { v.widthAnchor.constraint(equalTo: nav.widthAnchor).isActive = true }

        // 底部：引擎状态 + 外观切换
        statusDot.wantsLayer = true; statusDot.layer?.cornerRadius = 3.5
        statusDot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        pathLabel.lineBreakMode = .byTruncatingMiddle; pathLabel.maximumNumberOfLines = 1
        themeButton.onAction { [weak self] in self?.showThemeMenu() }
        let statusCol = vstack([hstack([statusDot, statusLabel], spacing: 6), pathLabel], spacing: 1)
        let footer = hstack([statusCol, flexibleSpacer(), themeButton], spacing: 6)
        footer.translatesAutoresizingMaskIntoConstraints = false
        brand.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(brand)
        panel.addSubview(nav)
        panel.addSubview(footer)
        NSLayoutConstraint.activate([
            brand.topAnchor.constraint(equalTo: panel.topAnchor, constant: 44),
            brand.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            nav.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 18),
            nav.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            nav.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -14),
        ])

        engine.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.updateStatus() }.store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: .cfThemeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateThemeButton() }
        }
        updateThemeButton()
        updateStatus()
    }

    func setSelected(_ section: AppSection) {
        for (s, b) in items { b.isSelectedRow = (s == section) }
    }

    func relocalize() {
        for (s, b) in items { b.setTitle(s.title) }
        for (h, gi) in groupLabels { h.attributedStringValue = sidebarGroupTitle(gi, AppSection.groups[gi].0) }
        updateThemeButton()
        updateStatus()
    }

    private func updateThemeButton() {
        themeButton.setSymbol(AppTheme.current.symbol)
        themeButton.toolTip = L("外观：", "Appearance: ") + AppTheme.current.title + L("（点击切换）", " (click to change)")
    }

    private func showThemeMenu() {
        let m = NSMenu()
        for t in AppTheme.allCases {
            let it = NSMenuItem(title: t.title, action: #selector(MenuAction.fire), keyEquivalent: "")
            let a = MenuAction { AppTheme.current = t }
            it.target = a; it.representedObject = a
            it.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: nil)
            it.state = AppTheme.current == t ? .on : .off
            m.addItem(it)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: themeButton.bounds.height + 4), in: themeButton)
    }

    private func updateStatus() {
        statusLabel.stringValue = engine.status
        pathLabel.attributedStringValue = osdString(engine.rcloneVersion.isEmpty ? "" : "rclone " + engine.rcloneVersion, color: .secondaryLabelColor, size: 9.5)
        pathLabel.toolTip = engine.rclonePath
        let color: NSColor = engine.ready ? .systemGreen : (engine.lastError != nil ? .systemRed : .systemOrange)
        statusDot.layer?.backgroundColor = color.cgColor
        // 侧边栏角标：正在传输显示百分比；否则显示排队数
        if let a = engine.activeJob, a.hasSizeInfo {
            items[.transfers]?.setBadge("\(Int(a.progress * 100))%")
        } else {
            let n = engine.jobs.filter { !$0.status.isFinal }.count
            items[.transfers]?.setBadge(n > 0 ? "\(n)" : nil)
        }
    }
}


/// 给自己的窗口拍照（窗口服务器合成后的样子，含毛玻璃/Liquid Glass）。
/// 只拍本 App 自己的窗口，不需要屏幕录制权限。CGWindowListCreateImage 在新 SDK 里被标为不可用，所以动态查找。
@MainActor func captureOwnWindow(_ w: NSWindow) -> CGImage? {
    typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    guard let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "CGWindowListCreateImage") else { return nil }
    let fn = unsafeBitCast(sym, to: Fn.self)
    // includingWindow = 1<<3；boundsIgnoreFraming = 1<<0 | bestResolution = 1<<3
    if ProcessInfo.processInfo.environment["CLOUDFERRY_SNAPSHOT_WINDOW"] == "below", let screen = w.screen ?? NSScreen.main {
        // 窗口 + 它下面的桌面壁纸（没有屏幕录制权限时，别的 App 的窗口会被系统自动排除）
        let f = w.frame
        let cg = CGRect(x: f.minX, y: screen.frame.maxY - f.maxY, width: f.width, height: f.height)
        return fn(cg, (1 << 2) | (1 << 3), UInt32(w.windowNumber), 1 << 3)?.takeRetainedValue()
    }
    return fn(.null, 1 << 3, UInt32(w.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue()
}


/// 侧边栏分组标题：「01  备份」——编号用等宽青色，像取景器屏显的通道号
@MainActor func sidebarGroupTitle(_ index: Int, _ title: String) -> NSAttributedString {
    let out = NSMutableAttributedString(attributedString: osdString(String(format: "%02d", index + 1), color: Theme.accent.withAlphaComponent(0.8), size: 10))
    out.append(NSAttributedString(string: "  " + title, attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor]))
    return out
}
