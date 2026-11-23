import AppKit
import Combine

@MainActor
final class TransfersVC: NSViewController, Refreshable {
    let engine: QueueEngine
    private var content: NSStackView!
    private let subtitle = makeLabel("")
    private let pauseButton = CFButton("", style: .secondary, symbol: "pause.fill")
    private let bannerBox = NSStackView()
    private let promptBox = NSStackView()
    private let destPopup = NSPopUpButton()
    private let destPath = NSTextField(string: "")
    private let volumesBox = NSStackView()
    private let queueBox = QueueStackView()
    private var queueSection: NSStackView!
    private let queueDetail = makeLabel("", color: .secondaryLabelColor)
    private var cancellables = Set<AnyCancellable>()
    private var lastRemotesKey = ""

    // 实时监控面板（v1.3）
    private let telemetry = LiveTelemetryCard()

    // 小技巧
    private var tipsCard: TipsCard!

    // 拖放区
    private var dropView: DropView!
    private var dropHeight: NSLayoutConstraint!

    // 增量刷新签名 + 行复用
    private var jobRows: [UUID: JobRowView] = [:]
    private var lastQueueSig = "", lastBannerSig = "", lastVolumeSig = ""

    init(engine: QueueEngine) { self.engine = engine; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let (scroll, stack) = makeVScroll(maxWidth: 980)
        content = stack
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildHeader()
        for b in [bannerBox, promptBox, volumesBox] {
            b.orientation = .vertical; b.alignment = .leading; b.spacing = 10
        }
        add(bannerBox)
        add(promptBox)
        add(telemetry)

        queueBox.orientation = .vertical; queueBox.alignment = .leading; queueBox.spacing = 10
        queueBox.onReorder = { [weak self] id, before in self?.engine.move(id, before: before) }
        let clear = CFButton(L("清除已完成", "Clear finished"), style: .plain, size: .small) { [weak self] in self?.engine.clearFinished() }
        clear.toolTip = L("从队列里移除已完成/已取消的任务（「历史记录」里仍保留）", "Remove done/canceled tasks from the queue (they stay in History)")
        queueDetail.font = Typo.number(13)
        let qHeader = hstack([sectionTitle(L("队列", "Queue")), queueDetail, flexibleSpacer(), clear], spacing: 8, alignment: .centerY)
        queueSection = vstack([qHeader, queueBox], spacing: 12)
        qHeader.widthAnchor.constraint(equalTo: queueSection.widthAnchor).isActive = true
        queueBox.widthAnchor.constraint(equalTo: queueSection.widthAnchor).isActive = true
        add(queueSection)

        add(dropCard())
        add(volumesBox)
        tipsCard = TipsCard(tips: tips())
        tipsCard.onClose = { [weak self] in
            UserDefaults.standard.set(true, forKey: "cf.tipsHidden"); self?.tipsCard.isHidden = true
        }
        tipsCard.isHidden = UserDefaults.standard.bool(forKey: "cf.tipsHidden")
        add(tipsCard)
        content.setCustomSpacing(24, after: content.arrangedSubviews[0])
        NotificationCenter.default.addObserver(forName: .cfThemeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tipsCard.isHidden = UserDefaults.standard.bool(forKey: "cf.tipsHidden")
                self.tipsCard.setTips(self.tips())
            }
        }

        engine.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.refresh() }.store(in: &cancellables)
        refresh()
    }

    func refreshOnShow() { syncDestFields(); refresh(); tipsCard?.setTips(tips()) }

    override func viewDidAppear() {
        super.viewDidAppear()
        // 不要一打开就把光标放进「备份到」输入框（会出现蓝色焦点框）
        if view.window?.firstResponder === destPath.currentEditor() || view.window?.firstResponder === destPath {
            view.window?.makeFirstResponder(nil)
        }
    }

    private func tips() -> [String] {
        var t = [
            L("插入储存卡会自动提示「一键备份」；也可以直接把卡拖到 Dock 上的 CloudFerry 图标。", "Plug in a card and CloudFerry offers a one-click backup — or drop the card onto the Dock icon."),
            L("看到「已校验 · 可放心格式化」之后，再去相机里格式化储存卡。", "Only format a card after it shows “Verified · safe to format”."),
            L("按 ⌘K 打开命令面板，所有功能都能搜到。", "Press ⌘K for the command palette — every action is searchable."),
            L("同一张卡当天再备份一次，只会补传新拍的文件，不会重复上传。", "Backing up the same card again that day only uploads the new shots."),
            L("Google 每天约 750 GB 上传上限。超过会自动暂停，第二天自动续传，不用守着。", "Google allows ~750 GB of uploads a day. CloudFerry pauses at the cap and resumes the next day by itself."),
            L("拖动队列里的卡片可以调整先后顺序；右键卡片可以在 Google Drive 网页里打开。", "Drag queue cards to reorder; right-click one to open it in Google Drive."),
            L("「历史记录」可以导出 CSV，方便整理项目素材清单。", "Export History as CSV to keep a footage log for each project."),
            L("整夜挂机时，App 会自动阻止 Mac 睡眠；断网会在 2、10、30 分钟后自动重试。", "Overnight, the app keeps the Mac awake and retries network drops after 2, 10 and 30 minutes."),
            L("在「浏览网盘」里，可以直接从访达拖文件进去上传。", "In Browse, drag files in from Finder to upload them right there."),
            L("侧边栏左下角可以切换外观：深色、浅色、深色玻璃。", "Switch the look — dark, light or dark glass — from the bottom of the sidebar."),
        ]
        if engine.remotes.contains(where: { $0.isDrive && !$0.usesOwnClient }) {
            t.insert(L("换成你自己的 Google 通道：上传更稳，也不受 rclone 公用通道 2026 年停用的影响（我的网盘 → 换成我自己的通道）。",
                       "Switch to your own Google client: steadier uploads, unaffected by the shared client's 2026 retirement (Remotes → Use my own client)."), at: 0)
        }
        return t
    }

    /// 今天还能传多少（Google 每日约 750 GB）
    private var remainingToday: Int64 { max(0, 750_000_000_000 - engine.todayUploaded) }

    /// 设备超过今天剩余额度时的提示
    private func capHint(_ vol: VolumeInfo) -> NSTextField? {
        guard vol.used > remainingToday else { return nil }
        let days = Int((Double(vol.used - remainingToday) / 750_000_000_000).rounded(.up)) + 1
        let l = makeLabel(L("超过今天剩余额度（约 ", "More than today's remaining quota (~") + Format.bytes(remainingToday)
                          + L("），会自动分 \(days) 天传完", "); will finish over \(days) days automatically"), color: .systemOrange)
        l.font = Typo.caption
        l.toolTip = L("Google Drive 每个账号每天约 750 GB 上传上限。到上限后队列自动暂停，第二天自动续传。",
                      "Google Drive allows ~750 GB of uploads per account per day. The queue pauses at the cap and resumes the next day.")
        return l
    }
    private func add(_ v: NSView) { content.addArrangedSubview(v); pinWidth(v, to: content) }

    private func buildHeader() {
        pauseButton.onAction { [weak self] in
            guard let self else { return }
            if engine.globalPaused { engine.resumeAll() } else { engine.pauseAll() }
        }
        let newBtn = CFButton(L("新建任务", "New task"), style: .primary, symbol: "plus") { [weak self] in self?.openNewSheet() }
        newBtn.toolTip = L("上传、下载、网盘互传（⌘N）", "Upload, download, or cloud-to-cloud (⌘N)")
        add(pageHeader(L("传输队列", "Transfers"), subtitle: subtitle, actions: [pauseButton, newBtn]))
    }

    // MARK: 拖放区（含「备份到」位置）

    private func dropCard() -> NSView {
        let drop = DropView(frame: .zero)
        drop.translatesAutoresizingMaskIntoConstraints = false
        dropHeight = drop.heightAnchor.constraint(equalToConstant: 150)
        dropHeight.isActive = true
        drop.onDrop = { [weak self] urls in self?.handleDrop(urls) }
        dropView = drop

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "square.and.arrow.down.on.square", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 20, weight: .medium)
        icon.contentTintColor = Theme.accent
        let t1 = makeLabel(L("把储存卡、SSD、文件夹或文件拖到这里", "Drop a card, SSD, folder or file here"))
        t1.font = .systemFont(ofSize: 15, weight: .semibold)
        let pick = CFButton(L("选择…", "Choose…"), style: .plain, size: .small) { [weak self] in self?.pickAndAdd() }
        let titleRow = hstack([icon, t1, pick], spacing: 10)

        destPopup.controlSize = .small
        destPopup.font = .systemFont(ofSize: 12)
        destPopup.widthAnchor.constraint(equalToConstant: 170).isActive = true
        destPopup.onAction { [weak self] in
            guard let self else { return }
            let i = destPopup.indexOfSelectedItem
            engine.defaultDestRemote = i <= 0 ? nil : engine.remotes[safe: i - 1]?.name
            engine.scheduleSave()
        }
        destPath.controlSize = .small
        destPath.font = Typo.number(12)
        destPath.placeholderString = L("文件夹，如 CloudFerry-Backup", "Folder, e.g. CloudFerry-Backup")
        destPath.widthAnchor.constraint(equalToConstant: 200).isActive = true
        destPath.cell?.sendsActionOnEndEditing = true
        destPath.onAction { [weak self] in
            self?.engine.defaultDestPath = self?.destPath.stringValue ?? ""
            self?.engine.scheduleSave()
        }
        let to = makeLabel(L("备份到", "Back up to"), color: .secondaryLabelColor); to.font = Typo.caption
        let slash = makeLabel("/", color: .tertiaryLabelColor)
        let info = CFButton("", style: .icon, symbol: "info.circle")
        info.toolTip = L("储存卡会放进「卡名_日期」文件夹（如 EOS_DIGITAL_2026-11-22），不同卡里同名的照片不会互相覆盖；同一张卡当天再拖一次只补传新文件。普通文件夹则建同名子文件夹。只记录路径，不会拷贝到本机。",
                         "A card goes into a “CardName_date” folder (e.g. EOS_DIGITAL_2026-11-22) so same-named photos from different cards never overwrite each other; dropping the same card again that day only adds new files. Regular folders get a same-named subfolder. Only paths are recorded; nothing is copied to your Mac.")
        let destRow = hstack([to, destPopup, slash, destPath, info], spacing: 6)
        let note = makeLabel(L("只记录路径，不拷贝到本机 · 可一次拖入多张卡排队 · 也可以拖到 Dock 图标上", "Paths only, nothing copied to your Mac · drop several cards to queue them · or drop onto the Dock icon"),
                             color: .tertiaryLabelColor)
        note.font = Typo.caption
        let col = vstack([titleRow, destRow, note], spacing: 10, alignment: .centerX)
        col.translatesAutoresizingMaskIntoConstraints = false
        drop.addSubview(col)
        NSLayoutConstraint.activate([
            col.centerXAnchor.constraint(equalTo: drop.centerXAnchor),
            col.centerYAnchor.constraint(equalTo: drop.centerYAnchor),
            col.widthAnchor.constraint(lessThanOrEqualTo: drop.widthAnchor, constant: -40),
        ])
        syncDestFields()
        return drop
    }

    // MARK: Refresh

    private func refresh() {
        if let job = engine.activeJob {
            subtitle.stringValue = L("正在传输 ", "Transferring ") + job.sourceLabel
                + (engine.queuedCount > 0 ? L(" · 另有 \(engine.queuedCount) 个排队", " · \(engine.queuedCount) more queued") : "")
        } else if engine.globalPaused {
            subtitle.stringValue = L("已全部暂停", "All paused")
        } else if engine.queuedCount > 0 {
            subtitle.stringValue = L("\(engine.queuedCount) 个任务排队中", "\(engine.queuedCount) task(s) queued")
        } else if let w = engine.jobs.compactMap({ $0.status == .waitingRetry ? $0.resumeAfter : nil }).min() {
            subtitle.stringValue = L("等待自动重试（", "Waiting to retry (") + Format.relative(w) + L("）", ")")
        } else {
            subtitle.stringValue = L("空闲 · 拖入储存卡即可开始备份", "Idle · drop a card to start a backup")
        }
        pauseButton.setTitle(engine.globalPaused ? L("全部继续", "Resume all") : L("全部暂停", "Pause all"))
        pauseButton.setSymbol(engine.globalPaused ? "play.fill" : "pause.fill")
        pauseButton.isHidden = engine.jobs.allSatisfy { $0.status.isFinal }
        updateMetrics()

        let key = engine.remotes.map { $0.name }.joined(separator: ",") + "|" + (engine.defaultDestRemote ?? "")
        if key != lastRemotesKey { lastRemotesKey = key; syncDestFields() }

        // 只在签名变化时重建（避免每秒重建整个界面 → 丝滑）
        let bsig = "\(engine.dailyCapUntil != nil)|\(engine.remotes.isEmpty)|\(engine.authProblem ?? "")|\(engine.ready)"
        if bsig != lastBannerSig { lastBannerSig = bsig; rebuildBanners() }

        let vsig = engine.externalVolumes.map { $0.id + ($0.uuid ?? "") }.joined(separator: ",") + "|" + (engine.newlyMounted?.id ?? "")
            + "|\(engine.history.count)|\(engine.jobs.filter { $0.status == .completed }.count)"
        if vsig != lastVolumeSig { lastVolumeSig = vsig; renderVolumes() }

        // 签名里必须包含“是否已知总大小”和“是否在校验”，否则进度条/校验中状态永远出不来（旧版 bug）
        let qsig = engine.jobs.map { j in
            "\(j.id.uuidString)\(j.status.rawValue)\(j.verified)\(j.hasSizeInfo)\(engine.verifyingJobs.contains(j.id))\(j.autoRetries ?? 0)\(j.verifyNote ?? "")|"
        }.joined() + "\(engine.globalPaused)"
        if qsig != lastQueueSig {
            lastQueueSig = qsig; rebuildQueue()
        } else {
            for job in engine.jobs where job.status == .running { jobRows[job.id]?.updateLiveStats(job) }
        }
    }

    private func updateMetrics() {
        // 没有任务、今天也没传过东西时整块隐藏，避免一进来就是一堆「—」
        let hasAnything = engine.activeJob != nil || engine.sessionBytes > 0 || engine.todayUploaded > 0 || !engine.recentDone.isEmpty
        telemetry.isHidden = !hasAnything
        if hasAnything { telemetry.update(engine) }
    }

    private func rebuildBanners() {
        bannerBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let msg = engine.authProblem {
            addBanner(BannerView(kind: .danger, title: msg,
                                 message: L("令牌过期或 rclone 公用通道被停用时会这样。还在用公用通道的话，「修复」会打开「换成你自己的通道」向导；已经是自己的通道就直接重新登录。",
                                            "This happens when the token expires or rclone's shared client is retired. If you're still on the shared client, Fix opens the “use your own client” wizard; otherwise it just signs in again."),
                                 actionTitle: L("修复", "Fix")) { [weak self] in
                (self?.view.window?.contentViewController as? RootSplitVC)?.reconnectBestWay()
            })
        }
        if let cap = engine.dailyCapUntil {
            addBanner(BannerView(kind: .warning,
                                 title: L("已达每日上传上限（Google 约 750GB/天）", "Daily upload limit reached (Google ~750GB/day)"),
                                 message: L("队列已暂停，将在 ", "Queue paused; auto-resumes ") + Format.relative(cap) + L(" 自动续传。也可以在任务上点 ⚡︎ 立即续传。", ". You can also click ⚡︎ on a task to resume now.")))
        }
        if engine.ready && engine.remotes.isEmpty {
            addBanner(BannerView(kind: .info,
                                 title: L("还没有连接网盘", "No remote connected"),
                                 message: L("先连接 Google Drive 或其他云盘，才能开始备份。", "Connect Google Drive or another cloud to start backing up."),
                                 actionTitle: L("去连接", "Connect")) { [weak self] in
                (self?.view.window?.contentViewController as? RootSplitVC)?.connectDrive()
            })
        }
        bannerBox.isHidden = bannerBox.arrangedSubviews.isEmpty
    }

    private func rebuildQueue() {
        queueBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        jobRows.removeAll()
        let empty = engine.jobs.isEmpty
        queueSection.isHidden = empty
        dropHeight.constant = empty ? 168 : 118
        guard !empty else { return }
        let active = engine.jobs.filter { !$0.status.isFinal }.count
        let done = engine.jobs.count - active
        queueDetail.stringValue = [active > 0 ? L("\(active) 个进行中/排队", "\(active) active") : nil,
                                   done > 0 ? L("\(done) 个已结束", "\(done) finished") : nil].compactMap { $0 }.joined(separator: " · ")
        for job in engine.jobs {
            let row = JobRowView(job: job, engine: engine)
            jobRows[job.id] = row
            queueBox.addArrangedSubview(row); pinWidth(row, to: queueBox)
        }
    }

    private func addBanner(_ b: NSView) { bannerBox.addArrangedSubview(b); pinWidth(b, to: bannerBox) }

    @discardableResult
    private func requireRemote() -> Bool {
        if let r = engine.defaultDestRemote, !r.isEmpty { return true }
        let a = NSAlert()
        a.messageText = L("请先选择网盘", "Choose a remote first")
        a.informativeText = L("请到「我的网盘」添加或选择一个网盘，作为备份目的地。", "Add or select a remote under Remotes as the backup destination.")
        a.runModal()
        return false
    }

    private func lastBackupPill(_ vol: VolumeInfo) -> Pill {
        guard let last = engine.lastBackup(of: vol) else { return Pill(L("还没备份过", "Never backed up"), tint: .secondaryLabelColor) }
        var s = L("上次备份 ", "Backed up ") + Format.relative(last.finishedAt ?? last.createdAt)
        if last.verified { s += L(" · 已校验", " · verified") }
        return Pill(s, tint: .systemGreen, symbol: last.verified ? "checkmark" : nil)
    }

    private func volumeSymbol(_ vol: VolumeInfo) -> String { vol.isRemovable ? "sdcard" : "externaldrive" }

    private func renderVolumes() {
        promptBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        volumesBox.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // 新插入设备的提示（放在页面顶部，醒目）
        if let vol = engine.newlyMounted {
            let card = CardBox(title: nil)
            card.strokeColor = Theme.accent.withAlphaComponent(0.5)
            let title = makeLabel(L("检测到新设备：", "New drive: ") + vol.name); title.font = .systemFont(ofSize: 14, weight: .semibold)
            let sub = makeLabel(L("已用 ", "Used ") + Format.bytes(vol.used) + L(" / 共 ", " of ") + Format.bytes(vol.total), color: .secondaryLabelColor)
            sub.font = Typo.caption
            let backup = CFButton(L("一键备份", "Back it up"), style: .primary) { [weak self] in
                guard let self else { return }
                if self.requireRemote() { engine.backupVolume(vol) }
            }
            let ignore = CFButton(L("忽略", "Dismiss"), style: .plain) { [weak self] in self?.engine.dismissNewlyMounted() }
            var info: [NSView] = [title, hstack([sub, lastBackupPill(vol)], spacing: 8)]
            if let h = capHint(vol) { info.append(h) }
            let row = hstack([iconTile(volumeSymbol(vol)), vstack(info, spacing: 4),
                              flexibleSpacer(), ignore, backup], spacing: 12)
            card.addRow(row)
            promptBox.addArrangedSubview(card); pinWidth(card, to: promptBox)
        }
        promptBox.isHidden = promptBox.arrangedSubviews.isEmpty

        // 外接设备清单（手动选择备份）
        guard !engine.externalVolumes.isEmpty else { volumesBox.isHidden = true; return }
        volumesBox.isHidden = false
        var trailing: [NSView] = []
        if engine.externalVolumes.count > 1 {
            trailing.append(CFButton(L("全部备份", "Back up all"), style: .plain, size: .small) { [weak self] in
                guard let self else { return }
                if self.requireRemote() { engine.backupAllExternal() }
            })
        }
        let header = sectionHeader(L("外接设备", "External drives"), detail: "\(engine.externalVolumes.count)", trailing: trailing)
        volumesBox.addArrangedSubview(header); pinWidth(header, to: volumesBox)
        volumesBox.setCustomSpacing(12, after: header)
        let card = CardBox(title: nil)
        for (i, vol) in engine.externalVolumes.enumerated() {
            if i > 0 { card.addDivider() }
            let name = makeLabel(vol.name); name.font = Typo.rowTitle
            let size = makeLabel(Format.bytes(vol.used) + L(" / ", " of ") + Format.bytes(vol.total), color: .secondaryLabelColor)
            size.font = Typo.number(11.5)
            let btn = CFButton(L("备份", "Back up"), style: .secondary, size: .small) { [weak self] in
                guard let self else { return }
                if self.requireRemote() { engine.backupVolume(vol) }
            }
            var info: [NSView] = [name, size]
            if let h = capHint(vol) { info.append(h) }
            let r = hstack([iconTile(volumeSymbol(vol), tint: .secondaryLabelColor, size: 30), vstack(info, spacing: 2),
                            flexibleSpacer(), lastBackupPill(vol), btn], spacing: 12)
            card.addRow(r)
        }
        volumesBox.addArrangedSubview(card); pinWidth(card, to: volumesBox)
    }

    private func syncDestFields() {
        destPopup.removeAllItems()
        destPopup.addItem(withTitle: L("（未选择网盘）", "(no remote)"))
        for r in engine.remotes { destPopup.addItem(withTitle: "\(r.name)  ·  \(r.typeLabel)") }
        if let sel = engine.defaultDestRemote,
           let idx = engine.remotes.firstIndex(where: { $0.name == sel }) {
            destPopup.selectItem(at: idx + 1)
        } else {
            destPopup.selectItem(at: 0)
        }
        if view.window?.firstResponder != destPath.currentEditor() { destPath.stringValue = engine.defaultDestPath }
    }

    // MARK: Actions

    private func handleDrop(_ urls: [URL]) {
        let items = urls.filter { $0.isFileURL }
        guard !items.isEmpty else { return }
        guard let remote = engine.defaultDestRemote, !remote.isEmpty else {
            let a = NSAlert()
            a.messageText = L("请先选择网盘", "Choose a remote first")
            a.informativeText = L("拖入的内容需要一个上传目的地。请到「我的网盘」添加或选择一个网盘。",
                                  "Dropped items need an upload destination. Add or select one under Remotes.")
            a.runModal()
            return
        }
        engine.addUploadJobs(sources: items, destRemote: remote, destPath: engine.defaultDestPath)
    }

    private func pickAndAdd() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("加入队列", "Add to queue")
        if panel.runModal() == .OK { handleDrop(panel.urls) }
    }

    private func openNewSheet() {
        let sheet = NewTransferSheetVC(engine: engine)
        presentAsSheet(sheet)
    }
    func presentNewSheet() { openNewSheet() }
}

// MARK: - 队列容器：支持拖拽排序

final class QueueStackView: NSStackView {
    static let jobType = NSPasteboard.PasteboardType("com.cloudferry.job")
    var onReorder: ((UUID, UUID?) -> Void)?
    private let indicator: NSView = {
        let v = NSView(); v.wantsLayer = true; v.isHidden = true
        return v
    }()
    private var dropBefore: UUID?? = nil

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([Self.jobType])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var rows: [JobRowView] { arrangedSubviews.compactMap { $0 as? JobRowView } }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.string(forType: Self.jobType) != nil else { return [] }
        let p = convert(sender.draggingLocation, from: nil)
        // 找到鼠标所在位置之后的第一行 → 插入到它前面
        var before: UUID? = nil
        var lineY: CGFloat = rows.last.map { isFlipped ? $0.frame.maxY + 5 : $0.frame.minY - 5 } ?? 0
        for r in rows {
            let mid = r.frame.midY
            let isAbove = isFlipped ? p.y < mid : p.y > mid
            if isAbove { before = r.jobID; lineY = isFlipped ? r.frame.minY - 5 : r.frame.maxY + 5; break }
        }
        dropBefore = .some(before)
        if indicator.superview == nil { addSubview(indicator) }
        indicator.layer?.backgroundColor = Theme.accent.cgColor
        indicator.layer?.cornerRadius = 1.5
        indicator.frame = CGRect(x: 0, y: lineY - 1.5, width: bounds.width, height: 3)
        indicator.isHidden = false
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { indicator.isHidden = true }
    override func draggingEnded(_ sender: NSDraggingInfo) { indicator.isHidden = true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        indicator.isHidden = true
        guard let s = sender.draggingPasteboard.string(forType: Self.jobType), let id = UUID(uuidString: s),
              let before = dropBefore else { return false }
        if before == id { return false }
        onReorder?(id, before)
        return true
    }
}

// MARK: - Job row

@MainActor
final class JobRowView: ThemedBox, NSDraggingSource {
    private let engine: QueueEngine
    let jobID: UUID
    private let job: TransferJob
    private var liveBar: GradientProgressBar?
    private var liveStat: NSTextField?
    private var liveFile: NSTextField?
    private var mouseDownPoint: NSPoint?

    private var livePct: NSTextField?

    func updateLiveStats(_ job: TransferJob) {
        liveBar?.progress = job.progress
        livePct?.stringValue = "\(Int(job.progress * 100))%"
        liveStat?.stringValue = Self.statString(job)
        liveFile?.stringValue = Self.fileString(job)
    }
    static func statString(_ job: TransferJob) -> String {
        var s = ["\(Format.bytes(job.bytes)) / \(Format.bytes(job.totalBytes))", Format.speed(job.speed), Format.eta(job.etaSeconds)]
        if job.totalTransfers > 0 { s.append(L("\(job.transfersDone)/\(job.totalTransfers) 个文件", "\(job.transfersDone)/\(job.totalTransfers) files")) }
        if job.errorsCount > 0 { s.append(L("\(job.errorsCount) 个错误（会自动重试）", "\(job.errorsCount) errors (auto-retrying)")) }
        return s.joined(separator: "  ·  ")
    }
    static func fileString(_ job: TransferJob) -> String {
        guard let first = job.transferringNames.first else { return "" }
        let more = job.transferringNames.count > 1 ? L("  等 \(job.transferringNames.count) 个", "  +\(job.transferringNames.count - 1) more") : ""
        return L("正在传 ", "Now ") + first + more
    }

    init(job: TransferJob, engine: QueueEngine) {
        self.engine = engine
        self.jobID = job.id
        self.job = job
        super.init(frame: .zero)
        fillColor = Theme.card
        glassCapable = true
        strokeColor = nil
        chamfer = 10
        boxRadius = Theme.Radius.card
        translatesAutoresizingMaskIntoConstraints = false

        let symbol = job.isSingleFile == true ? "film" : (job.volumeName != nil ? "sdcard" : job.direction.symbol)
        let icon = iconTile(symbol, tint: job.status == .running ? Theme.accent : .secondaryLabelColor)

        let src = makeLabel(job.sourceLabel)
        src.font = .systemFont(ofSize: 14, weight: .semibold)
        src.lineBreakMode = .byTruncatingMiddle; src.maximumNumberOfLines = 1
        src.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let dst = makeLabel("→ " + job.destFs, color: .secondaryLabelColor)
        dst.font = Typo.caption
        dst.lineBreakMode = .byTruncatingMiddle; dst.maximumNumberOfLines = 1
        dst.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titleCol = vstack([src, dst], spacing: 3)
        titleCol.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleCol.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let topRow = hstack([icon, titleCol, flexibleSpacer(), statusPill(job, engine)], spacing: 12, alignment: .centerY)
        var rows: [NSView] = [topRow]

        // 第二部分：进度 / 结果说明（左）+ 操作按钮（右）
        var info: NSView? = nil
        func caption(_ t: String, _ c: NSColor = .secondaryLabelColor, lines: Int = 1) -> NSTextField {
            let l = makeLabel(t, color: c, multiline: lines > 1)
            l.font = Typo.caption
            l.maximumNumberOfLines = lines
            l.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return l
        }
        switch job.status {
        case .running:
            let bar = GradientProgressBar()
            bar.barHeight = 6
            if job.hasSizeInfo {
                bar.progress = job.progress
                liveBar = bar
                rows.append(bar)
                let pct = makeLabel("\(Int(job.progress * 100))%", color: Theme.accent)
                pct.font = Typo.number(13, .semibold)
                livePct = pct
                let stat = makeLabel(Self.statString(job), color: .secondaryLabelColor)
                stat.font = Typo.number(12)
                stat.lineBreakMode = .byTruncatingTail; stat.maximumNumberOfLines = 1
                stat.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                liveStat = stat
                let file = caption(Self.fileString(job), .tertiaryLabelColor)
                file.lineBreakMode = .byTruncatingMiddle
                liveFile = file
                info = vstack([hstack([pct, stat], spacing: 10), file], spacing: 4)
            } else {
                rows.append(bar)
                DispatchQueue.main.async { bar.setIndeterminate(true) }
                info = caption(L("正在比对网盘里已有的文件…（已备份过的会自动跳过）", "Comparing with files already in the cloud… (already-backed-up files are skipped)"))
            }
        case .completed:
            var parts: [String] = []
            if job.transfersDone == 0 && job.doneBytes == 0 {
                parts = [L("没有需要传的新文件（网盘里已经都有了）", "Nothing new to transfer (already in the cloud)")]
            } else {
                parts.append(job.direction.doneVerb + " " + Format.bytes(job.doneBytes))
                if job.transfersDone > 0 { parts.append(L("\(job.transfersDone) 个文件", "\(job.transfersDone) files")) }
                if let secs = job.activeSeconds, secs >= 1 { parts.append(L("用时 ", "took ") + Format.duration(secs)) }
                if let avg = job.averageSpeed { parts.append(L("平均 ", "avg ") + Format.speed(avg)) }
            }
            var v: [NSView] = [caption(parts.joined(separator: "  ·  "))]
            if let note = job.verifyNote, !job.verified { v.append(caption(L("校验结果：", "Verify: ") + note, .systemRed, lines: 3)) }
            info = vstack(v, spacing: 4)
        case .failed:
            if let err = job.error {
                let l = caption(String(err.prefix(600)), .systemRed, lines: 4)
                l.isSelectable = true
                info = l
            }
        case .waitingDailyCap:
            info = caption(L("已达每日上限，将于 ", "Daily cap hit; resumes ") + Format.relative(job.resumeAfter) + L(" 自动续传", ""), .systemOrange)
        case .waitingRetry:
            let n = job.autoRetries ?? 1
            var v: [NSView] = [caption(L("临时出错（多为网络波动），将于 ", "Temporary error (usually network); auto-retry ") + Format.relative(job.resumeAfter)
                                       + L(" 自动重试（第 \(n)/\(QueueEngine.retryDelays.count) 次）。已传完的文件不会重传。", " (\(n)/\(QueueEngine.retryDelays.count)). Finished files won't be re-sent."), .systemOrange, lines: 2)]
            if let err = job.error { v.append(caption(String(err.prefix(300)), .tertiaryLabelColor, lines: 2)) }
            info = vstack(v, spacing: 4)
        case .paused:
            info = caption(L("已暂停 · 继续时已传完的文件会自动跳过", "Paused · finished files are skipped when you resume"))
        case .queued:
            let pos = (engine.jobs.filter { $0.status == .queued }.firstIndex { $0.id == job.id } ?? 0) + 1
            info = caption(L("排在第 \(pos) 个 · 拖动卡片可调整顺序", "#\(pos) in line · drag to reorder"))
        case .canceled:
            info = caption(L("已取消", "Canceled"))
        }
        let infoView = info ?? NSView()
        infoView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        infoView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let ctl = hstack(controls(job, engine), spacing: 2)
        let bottomRow = hstack([infoView, flexibleSpacer(), ctl], spacing: 12, alignment: .centerY)
        rows.append(bottomRow)

        let col = vstack(rows, spacing: 12)
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            col.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        for r in col.arrangedSubviews {
            r.leadingAnchor.constraint(equalTo: col.leadingAnchor).isActive = true
            r.trailingAnchor.constraint(equalTo: col.trailingAnchor).isActive = true
        }
        toolTip = canDrag ? L("拖动可调整顺序；右键查看更多操作", "Drag to reorder; right-click for more") : L("右键查看更多操作", "Right-click for more")
    }
    required init?(coder: NSCoder) { fatalError() }

    private var canDrag: Bool { !job.status.isFinal && job.status != .running }

    private func statusPill(_ job: TransferJob, _ engine: QueueEngine) -> NSView {
        switch job.status {
        case .running: return Pill(job.status.label, tint: Theme.accent, symbol: "arrow.up")
        case .completed:
            if job.verified {
                return Pill(job.direction == .upload ? L("已校验 · 可放心格式化", "Verified · safe to format") : L("已校验", "Verified"),
                            tint: .systemGreen, symbol: "checkmark.shield.fill")
            }
            if engine.verifyingJobs.contains(job.id) { return Pill(L("校验中…", "Verifying…"), tint: Theme.accent, symbol: "hourglass") }
            return Pill(job.status.label, tint: .systemGreen, symbol: "checkmark")
        case .failed: return Pill(job.status.label, tint: .systemRed, symbol: "exclamationmark")
        case .waitingDailyCap, .waitingRetry: return Pill(job.status.label, tint: .systemOrange, symbol: "clock")
        case .paused: return Pill(job.status.label, tint: .secondaryLabelColor, symbol: "pause.fill")
        default: return Pill(job.status.label, tint: .secondaryLabelColor)
        }
    }

    private func controls(_ job: TransferJob, _ engine: QueueEngine) -> [NSView] {
        func btn(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> NSButton {
            let b = CFButton("", style: .icon, symbol: symbol, action: action)
            b.toolTip = tip
            return b
        }
        let id = job.id
        var v: [NSView] = []
        switch job.status {
        case .queued:
            v = [btn("pause.fill", L("暂停这个任务", "Pause this task")) { engine.pause(id) },
                 btn("arrow.up.to.line", L("移到最前（下一个传）", "Move to top (next up)")) { engine.moveToTop(id) },
                 btn("xmark", L("取消", "Cancel")) { engine.cancel(id) }]
        case .running:
            v = [btn("pause.fill", L("暂停（正在传的那个大文件下次从头传）", "Pause (the file in flight restarts next time)")) { engine.pause(id) },
                 btn("stop.fill", L("停止并取消", "Stop & cancel")) { engine.cancel(id) }]
        case .paused:
            v = [btn("play.fill", L("继续", "Resume")) { engine.resume(id) },
                 btn("trash", L("移除", "Remove")) { engine.remove(id) }]
        case .failed:
            v = [btn("arrow.clockwise", L("重试", "Retry")) { engine.retry(id) },
                 btn("trash", L("移除", "Remove")) { engine.remove(id) }]
        case .waitingDailyCap:
            v = [btn("bolt.fill", L("立即续传", "Resume now")) { engine.resumeDailyCapNow(id) },
                 btn("trash", L("移除", "Remove")) { engine.remove(id) }]
        case .waitingRetry:
            v = [btn("arrow.clockwise", L("立即重试", "Retry now")) { engine.retry(id) },
                 btn("pause.fill", L("暂停", "Pause")) { engine.pause(id) }]
        case .completed:
            if !job.verified && !engine.verifyingJobs.contains(id) {
                v.append(btn("checkmark.shield", L("校验（完整哈希比对，确认无缺漏后可格式化卡）", "Verify (full hash compare — confirm before formatting)")) { engine.verify(id, full: true) })
            }
            if job.destIsLocal {
                v.append(btn("folder", L("在访达中显示", "Show in Finder")) { JobRowView.reveal(job.destFs) })
            } else if engine.isDriveFs(job.destFs) {
                v.append(btn("safari", L("在 Google Drive 网页中打开", "Open in Google Drive")) { engine.openInDriveWeb(fs: job.destFs) })
            }
            v.append(btn("trash", L("从队列移除（历史记录里仍保留）", "Remove from queue (kept in History)")) { engine.remove(id) })
        case .canceled:
            v = [btn("arrow.clockwise", L("重新加入队列", "Re-queue")) { engine.retry(id) },
                 btn("trash", L("移除", "Remove")) { engine.remove(id) }]
        }
        let more = btn("ellipsis.circle", L("更多操作", "More")) { }
        more.onAction { [weak self, weak more] in
            guard let self, let more else { return }
            let m = self.buildMenu()
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
        }
        v.append(more)
        return v
    }

    // MARK: 右键菜单

    override func menu(for event: NSEvent) -> NSMenu? { buildMenu() }

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        let id = job.id, e = engine, j = job
        func add(_ title: String, _ symbol: String? = nil, _ action: @escaping () -> Void) {
            let it = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
            let a = MenuAction(action); it.target = a; it.representedObject = a
            if let symbol { it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            m.addItem(it)
        }
        let pending = !j.status.isFinal && j.status != .running
        switch j.status {
        case .running, .queued, .waitingRetry, .waitingDailyCap: add(L("暂停", "Pause"), "pause") { e.pause(id) }
        case .paused: add(L("继续", "Resume"), "play") { e.resume(id) }
        default: break
        }
        if pending {
            add(L("移到最前", "Move to top"), "arrow.up.to.line") { e.moveToTop(id) }
            add(L("上移", "Move up"), "arrow.up") { e.move(id, by: -1) }
            add(L("下移", "Move down"), "arrow.down") { e.move(id, by: 1) }
            add(L("移到最后", "Move to bottom"), "arrow.down.to.line") { e.moveToBottom(id) }
        }
        if j.status == .failed || j.status == .waitingRetry || j.status == .canceled {
            add(L("立即重试", "Retry now"), "arrow.clockwise") { e.retry(id) }
        }
        if j.status == .completed {
            m.addItem(.separator())
            add(L("快速核对（文件清单 + 大小）", "Quick check (file list + sizes)"), "checklist") { e.verify(id, full: false) }
            add(L("完整校验（逐个哈希，较慢）", "Full verify (hash every file, slower)"), "checkmark.shield") { e.verify(id, full: true) }
            add(L("再传一次（只补传新文件）", "Run again (only new files)"), "arrow.triangle.2.circlepath") { e.rerun(j) }
        }
        m.addItem(.separator())
        if e.isDriveFs(j.destFs) {
            add(L("在 Google Drive 网页中打开目的地", "Open destination in Google Drive"), "safari") { e.openInDriveWeb(fs: j.destFs) }
        }
        if e.isDriveFs(j.sourceFs) {
            add(L("在 Google Drive 网页中打开来源", "Open source in Google Drive"), "safari") { e.openInDriveWeb(fs: j.sourceFs) }
        }
        if j.sourceIsLocal { add(L("在访达中显示来源", "Show source in Finder"), "folder") { JobRowView.reveal(j.sourceFs) } }
        if j.destIsLocal { add(L("在访达中显示目的地", "Show destination in Finder"), "folder") { JobRowView.reveal(j.destFs) } }
        add(L("拷贝目的地路径", "Copy destination path"), "doc.on.doc") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(j.destFs, forType: .string)
        }
        m.addItem(.separator())
        if j.status == .running || pending { add(L("取消任务", "Cancel task"), "xmark") { e.cancel(id) } }
        add(L("从队列移除", "Remove from queue"), "trash") { e.remove(id) }
        return m
    }

    static func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()]) }
    }

    // MARK: 拖拽排序（源）

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = canDrag ? convert(event.locationInWindow, from: nil) : nil
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 6 else { return }
        mouseDownPoint = nil
        let item = NSPasteboardItem()
        item.setString(jobID.uuidString, forType: QueueStackView.jobType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep); image.addRepresentation(rep)
        }
        dragItem.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { alphaValue = 0.45 }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { alphaValue = 1 }
}

/// 菜单项闭包桥接
final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}
