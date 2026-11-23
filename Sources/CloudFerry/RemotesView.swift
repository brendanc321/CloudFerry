import AppKit
import Combine

@MainActor
final class RemotesVC: NSViewController, Refreshable {
    let engine: QueueEngine
    private var content: NSStackView!
    private let listBox = NSStackView()
    private let bannerBox = NSStackView()
    private var lastBannerSig = ""
    private var cancellables = Set<AnyCancellable>()

    init(engine: QueueEngine) { self.engine = engine; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let (scroll, stack) = makeVScroll(); content = stack; view = scroll
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        buildHeader()
        bannerBox.orientation = .vertical; bannerBox.alignment = .leading; bannerBox.spacing = 8
        add(bannerBox)
        listBox.orientation = .vertical; listBox.alignment = .leading; listBox.spacing = 14
        add(listBox)
        engine.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.rebuildList() }.store(in: &cancellables)
        rebuildList()
        if ProcessInfo.processInfo.environment["CLOUDFERRY_OPENADD"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.openAdd() }
        }
    }
    func refreshOnShow() { Task { await engine.refreshRemotes() }; rebuildList() }
    private func add(_ v: NSView) { content.addArrangedSubview(v); pinWidth(v, to: content) }

    private func buildHeader() {
        let refresh = CFButton(L("刷新", "Refresh"), style: .secondary, symbol: "arrow.clockwise") { [weak self] in Task { await self?.engine.refreshRemotes() } }
        let addBtn = CFButton(L("添加网盘", "Add remote"), style: .primary, symbol: "plus") { [weak self] in self?.openAdd() }
        add(pageHeader(L("我的网盘", "Remotes"),
                       subtitleText: L("已连接的云盘 · 支持 Google Drive、Dropbox、OneDrive、S3 等 70+ 种", "Connected clouds · Google Drive, Dropbox, OneDrive, S3 and 70+ more"),
                       actions: [refresh, addBtn]))
    }

    private func rebuildBanner() {
        let shared = engine.remotes.filter { $0.isDrive && !$0.usesOwnClient }.map { $0.name }
        let sig = shared.joined(separator: ",") + "|\(Loc.current)"
        guard sig != lastBannerSig else { return }
        lastBannerSig = sig
        bannerBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let first = shared.first else { return }
        let b = BannerView(kind: .warning,
                           title: L("「\(shared.joined(separator: "、"))」还在用 rclone 公用通道，2026 年内会停止工作", "“\(shared.joined(separator: ", "))” still uses rclone's shared client, which stops working during 2026"),
                           message: L("公用通道全球共用、会被限速。换成你自己的 Google 通道：免费、更稳，约 5 分钟，网盘里的文件和备份文件夹都不变。",
                                      "It's shared worldwide and rate-limited. Switch to your own Google client: free, steadier, ~5 minutes, and your files and backup folders stay as they are."),
                           actionTitle: L("开始设置", "Set it up")) { [weak self] in self?.openClientSetup(first) }
        bannerBox.addArrangedSubview(b); pinWidth(b, to: bannerBox)
    }

    private func openClientSetup(_ name: String?) { presentAsModalWindow(ClientSetupVC(engine: engine, preselect: name)) }

    private func rebuildList() {
        rebuildBanner()
        listBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if engine.remotes.isEmpty {
            let card = CardBox(title: nil)
            let l = makeLabel(L("还没有连接任何网盘。点右上角「添加网盘」。", "No remotes yet. Click “Add remote” at the top-right."), size: 13, color: .secondaryLabelColor)
            card.addRow(l)
            listBox.addArrangedSubview(card); pinWidth(card, to: listBox)
            return
        }
        for r in engine.remotes {
            let card = remoteCard(r)
            listBox.addArrangedSubview(card); pinWidth(card, to: listBox)
        }
    }

    private func remoteCard(_ r: Remote) -> NSView {
        let card = CardBox(title: nil)
        let name = makeLabel(r.name); name.font = .systemFont(ofSize: 15, weight: .semibold)
        var titleRow: [NSView] = [name, Pill(r.typeLabel, tint: .secondaryLabelColor)]
        if engine.defaultDestRemote == r.name { titleRow.append(Pill(L("默认目的地", "Default"), tint: Theme.accent, symbol: "star.fill")) }
        var infoViews: [NSView] = [hstack(titleRow, spacing: 8)]

        // 容量
        if let q = engine.quotas[r.name], let total = q.total, let used = q.used, total > 0 {
            let bar = GradientProgressBar(); bar.barHeight = 5
            bar.progress = Double(used) / Double(total)
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 300).isActive = true
            let txt = makeLabel(L("已用 ", "Used ") + Format.bytes(used) + L(" / 共 ", " of ") + Format.bytes(total)
                                + L(" · 剩余 ", " · free ") + Format.bytes(q.free ?? (total - used)), color: .secondaryLabelColor)
            txt.font = Typo.number(11.5)
            infoViews.append(vstack([bar, txt], spacing: 6))
        } else {
            infoViews.append(captionLabel(L("点「查询容量」查看已用 / 剩余空间", "Click “Check usage” to see used / free space"), color: .tertiaryLabelColor))
        }
        let infoCol = vstack(infoViews, spacing: 10)
        infoCol.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let quotaBtn = CFButton(L("查询容量", "Check usage"), style: .secondary, size: .small) { [weak self] in Task { await self?.engine.refreshQuota(for: r) } }
        let more = CFButton("", style: .icon, symbol: "ellipsis")
        more.toolTip = L("更多", "More")
        more.onAction { [weak self, weak more] in
            guard let self, let more else { return }
            let m = NSMenu()
            func item(_ t: String, _ sym: String, _ act: @escaping () -> Void) {
                let it = NSMenuItem(title: t, action: #selector(MenuAction.fire), keyEquivalent: "")
                let a = MenuAction(act); it.target = a; it.representedObject = a
                it.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil); m.addItem(it)
            }
            if self.engine.defaultDestRemote != r.name {
                item(L("设为默认备份目的地", "Set as default destination"), "star") { [weak self] in self?.engine.defaultDestRemote = r.name; self?.rebuildList() }
            }
            m.addItem(.separator())
            item(L("删除这个网盘的登录配置…", "Remove this remote's login…"), "trash") { [weak self] in self?.confirmDelete(r) }
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
        }
        var btns: [NSView] = [quotaBtn]
        if r.isDrive {
            let own = r.usesOwnClient
            btns.append(CFButton(own ? L("重新授权…", "Re-authorize…") : L("换成我自己的通道…", "Use my own client…"),
                                 style: own ? .secondary : .primary, size: .small) { [weak self] in self?.openClientSetup(r.name) })
        }
        btns.append(more)
        let row = hstack([iconTile(r.iconName, size: 40), infoCol, flexibleSpacer()] + btns, spacing: 10, alignment: .top)
        card.addRow(row)

        if r.isDrive {
            card.addDivider()
            let own = r.usesOwnClient
            let ch = Pill(own ? L("通道：你自己的", "Client: your own") + "（" + GoogleClientCredentials.shortID(r.clientID ?? "") + "）"
                              : L("通道：rclone 公用 · 2026 年内停用", "Client: rclone shared · retiring in 2026"),
                          tint: own ? .systemGreen : .systemOrange, symbol: own ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
            let note = captionLabel(own ? L("上传走你自己 Google 账号名下的通道，不和别人抢配额。", "Uploads go through a client under your own Google account — no shared quota.")
                                        : L("「通道」就是 Google 用来识别这个软件的通行证。公用的那张全世界共用、会被限速，而且快要作废了。",
                                            "The “client” is the pass Google uses to recognise this app. The shared one is used worldwide, throttled, and about to be retired."),
                                    maxWidth: 560)
            card.addRow(hstack([ch, note, flexibleSpacer()], spacing: 10, alignment: .centerY))
        }
        return card
    }

    private func confirmDelete(_ r: Remote) {
        let a = NSAlert()
        a.messageText = L("删除网盘配置「\(r.name)」？", "Remove remote “\(r.name)”?")
        a.informativeText = L("只删除本地登录配置，不会删除云端任何数据。", "This only removes the local login config; nothing in the cloud is deleted.")
        a.addButton(withTitle: L("删除", "Delete"))
        a.addButton(withTitle: L("取消", "Cancel"))
        if a.runModal() == .alertFirstButtonReturn { engine.deleteRemote(r.name) }
    }

    private func openAdd() { presentAsModalWindow(AddRemoteVC(engine: engine)) }
    func presentAddRemote() { openAdd() }
}

@MainActor
final class AddRemoteVC: NSViewController {
    let engine: QueueEngine
    private var cancellables = Set<AnyCancellable>()

    private let nameField = NSTextField(string: "gdrive")
    private let ownCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let clientIDField = NSTextField(string: "")
    private let clientSecretField = NSTextField(string: "")
    private let connectBtn = CFButton(L("用 Google 登录（打开浏览器）", "Sign in with Google (opens browser)"), style: .primary)
    private let cancelBtn = CFButton(L("取消登录", "Cancel"), style: .secondary)
    private let spinner = NSProgressIndicator()
    private let statusLabel = makeLabel("", size: 12, color: .secondaryLabelColor, multiline: true)

    init(engine: QueueEngine) { self.engine = engine; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 640)) }

    override func viewDidLoad() {
        super.viewDidLoad()
        let (scroll, content) = makeVScroll()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        func add(_ v: NSView) { content.addArrangedSubview(v); pinWidth(v, to: content) }

        add(makeLabel(L("连接 Google Drive", "Connect Google Drive"), size: 18, weight: .bold))
        add(BannerView(kind: .info,
            title: L("最省事：直接点下面「用 Google 登录」——一键授权，和 Cyberduck 一样", "Easiest: just click “Sign in with Google” below — one click, like Cyberduck"),
            message: L("只有当你选择用「自己的 client_id」时，才需要在 Google 那边把自己加为测试用户/发布应用，且 client_secret 要用 GOCSPX- 开头那串（别填成 client_id）。",
                       "Only if you choose your own client_id do you need to add yourself as a test user / publish the app on Google's side, and use the client_secret starting with GOCSPX- (not the client_id).")))

        // ——一键连接——
        let connectCard = CardBox(title: L("一键连接（推荐，无需终端）", "One-click connect (recommended, no Terminal)"), systemImage: "person.badge.key")

        nameField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        connectCard.addRow(labeledRow(L("网盘名称", "Remote name"), nameField,
            L("给这个网盘起个名字，默认 gdrive。若与已有同名会先覆盖旧的。", "A name for this remote (default gdrive). Reuses/overwrites an existing one of the same name.")))
        connectCard.addDivider()

        ownCheck.title = L("使用我自己的 client_id（更快·更稳，避免 2026 停用）", "Use my own client_id (faster, avoids 2026 retirement)")
        ownCheck.state = .off   // 默认走最省事的一键登录（像 Cyberduck）
        ownCheck.onAction { [weak self] in self?.updateFieldEnabled() }
        connectCard.addRow(row(ownCheck))
        let ownNote = makeLabel(L("默认不勾选：直接用 Google 登录，最省事、和 Cyberduck 一样一键授权（用 rclone 内置 key）。若提示限速或停用，再勾选下面填自己的 client_id。",
                                  "Default (unchecked): just sign in with Google — one click like Cyberduck (uses rclone's built-in key). If it's throttled/retired, check this and enter your own client_id below."),
                                size: 11, color: .secondaryLabelColor, multiline: true)
        connectCard.addRow(ownNote); pinWidth(ownNote, to: connectCard.stack)
        connectCard.addDivider()

        clientIDField.placeholderString = "…apps.googleusercontent.com"
        connectCard.addRow(labeledRow("client_id", clientIDField,
            L("Google Cloud Console 里 OAuth 客户端的「客户端 ID」，以 .apps.googleusercontent.com 结尾。", "The OAuth client's Client ID, ending in .apps.googleusercontent.com")))
        clientSecretField.placeholderString = "GOCSPX-…"
        connectCard.addRow(labeledRow("client_secret", clientSecretField,
            L("同一个 OAuth 客户端的「客户端密钥」，以 GOCSPX- 开头（不是 client_id！）。", "The OAuth client's Client secret, starting with GOCSPX- (NOT the client_id!)")))
        connectCard.addDivider()

        connectBtn.onAction { [weak self] in self?.startConnect() }
        cancelBtn.isHidden = true
        cancelBtn.onAction { [weak self] in self?.engine.cancelConnect() }
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isHidden = true
        connectCard.addRow(row(hstack([connectBtn, cancelBtn, spinner, flexibleSpacer()])))
        connectCard.addRow(statusLabel); pinWidth(statusLabel, to: connectCard.stack)
        add(connectCard)

        // ——获取凭据的指引——
        let guide = CardBox(title: L("如何获取 client_id / 修复 Access blocked（约 5–8 分钟）", "Get a client_id / fix 'Access blocked' (~5–8 min)"), systemImage: "questionmark.circle")
        let gsteps = [
            L("打开 Google Cloud Console，新建或选择一个项目", "Open Google Cloud Console; create or pick a project"),
            L("「启用 API 和服务」搜索 Drive，启用「Google Drive API」", "Under “Enable APIs and Services”, search Drive and enable the Google Drive API"),
            L("配置「OAuth 同意屏幕」：Audience 选「外部 External」，填应用名和你的邮箱", "Configure the OAuth consent screen: Audience = External, app name + your email"),
            L("在「Audience」→「+ 添加用户」把你自己的邮箱加为测试用户；或直接点「PUBLISH APP 发布应用」", "Under Audience → “+ Add users” add your own email as a test user; or click PUBLISH APP"),
            L("「创建 OAuth 客户端」→ 类型「桌面应用 Desktop app」→ 记下 client_id 和 client_secret（GOCSPX-…）", "Create OAuth client → type “Desktop app” → note the client_id and client_secret (GOCSPX-…)"),
        ]
        for (i, t) in gsteps.enumerated() {
            let l = makeLabel("\(i + 1). \(t)", size: 12, multiline: true)
            guide.addRow(l); pinWidth(l, to: guide.stack)
        }
        let openConsole = CFButton(L("打开 Google Cloud Console", "Open Google Cloud Console"), style: .secondary, size: .small)
        openConsole.onAction { NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/credentials")!) }
        let openHelp = CFButton(L("官方图文教程", "Official guide"), style: .plain, size: .small)
        openHelp.onAction { NSWorkspace.shared.open(URL(string: "https://rclone.org/drive/#making-your-own-client-id")!) }
        let wizard = CFButton(L("打开设置向导（推荐）", "Open the setup wizard (recommended)"), style: .primary, size: .small)
        wizard.onAction { [weak self] in
            guard let self else { return }
            let root = self.presentingViewController?.view.window?.contentViewController as? RootSplitVC
            self.dismiss(self)
            DispatchQueue.main.async { root?.openClientSetup() }
        }
        guide.addRow(row(hstack([wizard, openConsole, openHelp, flexibleSpacer()])))
        add(guide)

        // ——其他云盘 / 终端兜底——
        let other = CardBox(title: L("其他云盘 / 高级", "Other clouds / advanced"), systemImage: "cloud")
        let l3 = makeLabel(L("要连 Dropbox、OneDrive、S3、B2 等，或想用终端向导：点下方按钮在终端运行 rclone config。",
                             "For Dropbox, OneDrive, S3, B2, etc., or to use the terminal wizard, run rclone config below."),
                           size: 12, color: .secondaryLabelColor, multiline: true)
        other.addRow(l3); pinWidth(l3, to: other.stack)
        let termBtn = CFButton(L("在终端运行 rclone config", "Run rclone config in Terminal"), style: .secondary, size: .small)
        termBtn.onAction { [weak self] in self?.runConfigInTerminal() }
        other.addRow(row(termBtn))
        add(other)

        let close = CFButton(L("关闭", "Close"), style: .secondary)
        close.keyEquivalent = "\u{1b}"
        close.onAction { [weak self] in self.map { $0.dismiss($0) } }
        add(hstack([flexibleSpacer(), close]))

        engine.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.syncConnectingUI() }.store(in: &cancellables)
        updateFieldEnabled()
        syncConnectingUI()
    }

    private func labeledRow(_ title: String, _ control: NSView, _ caption: String) -> NSView {
        let top = hstack([makeLabel(title, size: 13, weight: .medium), flexibleSpacer(), control])
        let cap = makeLabel(caption, size: 11, color: .secondaryLabelColor, multiline: true)
        let col = vstack([top, cap], spacing: 4)
        top.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        cap.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }
    private func row(_ v: NSView) -> NSView { v }

    private func updateFieldEnabled() {
        let own = ownCheck.state == .on
        clientIDField.isEnabled = own
        clientSecretField.isEnabled = own
        clientIDField.alphaValue = own ? 1 : 0.4
        clientSecretField.alphaValue = own ? 1 : 0.4
    }

    private func syncConnectingUI() {
        let busy = engine.connecting
        spinner.isHidden = !busy
        cancelBtn.isHidden = !busy
        connectBtn.isEnabled = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        if busy {
            statusLabel.stringValue = L("浏览器已打开，请在浏览器里登录并点「允许」授权。若看到「Access blocked」，说明还没把自己加为测试用户或没发布应用。",
                                        "A browser opened — sign in and click Allow. If you see 'Access blocked', you haven't added yourself as a test user or published the app.")
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    private func startConnect() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let own = ownCheck.state == .on
        let cid = clientIDField.stringValue.trimmingCharacters(in: .whitespaces)
        let secret = clientSecretField.stringValue.trimmingCharacters(in: .whitespaces)
        func fail(_ m: String) { let a = NSAlert(); a.messageText = m; a.runModal() }

        if name.isEmpty { fail(L("请填写网盘名称", "Please enter a remote name")); return }
        if own {
            if cid.isEmpty { fail(L("请填写 client_id", "Please enter the client_id")); return }
            if secret.isEmpty { fail(L("请填写 client_secret（GOCSPX- 开头）", "Please enter the client_secret (starts with GOCSPX-)")); return }
            if secret == cid {
                fail(L("client_secret 填错了：它不能和 client_id 一样。请到 Google Console 复制以 GOCSPX- 开头的「客户端密钥」。",
                       "Wrong client_secret: it must not equal the client_id. Copy the 'Client secret' (starts with GOCSPX-) from Google Console."))
                return
            }
        }
        engine.connectDrive(name: name, clientID: cid, clientSecret: secret, useOwnClientID: own) { [weak self] ok in
            guard let self else { return }
            let a = NSAlert()
            if ok {
                a.messageText = L("连接成功 🎉", "Connected 🎉")
                a.informativeText = L("已把「\(name)」设为默认备份目的地。可以关闭本窗口开始拖卡备份了。",
                                      "“\(name)” is now your default backup destination. You can close this window and start dropping cards.")
                a.runModal(); self.dismiss(self)
            } else {
                a.messageText = L("连接未完成", "Connection didn't complete")
                a.informativeText = L("多半是浏览器里出现「Access blocked」——请把自己加为测试用户或发布应用；也确认 client_secret 是 GOCSPX- 那串。然后再试一次。",
                                      "Usually this means 'Access blocked' in the browser — add yourself as a test user or publish the app, and check the client_secret is the GOCSPX- string. Then try again.")
                a.runModal()
            }
        }
    }

    private func runConfigInTerminal() {
        guard let path = engine.rclonePath else { return }
        let script = "tell application \"Terminal\"\ndo script \"\(path) config\"\nactivate\nend tell"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}
