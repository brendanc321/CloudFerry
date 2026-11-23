import AppKit

@MainActor
final class SettingsVC: NSViewController, Refreshable {
    let engine: QueueEngine
    private var content: NSStackView!
    private var ramBar: GradientProgressBar!
    private var ramLabel = makeLabel("", size: 12, weight: .medium, mono: true)
    private var ramNote = makeLabel("", size: 11, color: .secondaryLabelColor, multiline: true)
    private var previewLabel = makeLabel("", size: 11, color: .labelColor, multiline: true)

    init(engine: QueueEngine) { self.engine = engine; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let (scroll, stack) = makeVScroll()
        content = stack
        view = scroll
    }
    override func viewDidLoad() { super.viewDidLoad(); rebuild() }
    func refreshOnShow() { rebuild() }

    private func s() -> TransferSettings { engine.settings }
    private func edit(_ change: @escaping (inout TransferSettings) -> Void) {
        var st = engine.settings; change(&st); engine.settings = st
        engine.scheduleSave(); updateRAM(); updatePreview()
    }

    private func rebuild() {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        add(pageHeader(L("上传设置", "Settings"),
                       subtitleText: L("改动自动保存，下一个任务开始生效。每一项下面都有说明。", "Changes save automatically and apply to the next task. Every option has a note.")))
        content.setCustomSpacing(24, after: content.arrangedSubviews.last!)
        add(appearanceCard())
        add(headerCard())
        add(connectionCard())
        add(behaviorCard())
        let adv = sectionHeader(L("高级参数", "Advanced"), detail: L("一般不用改，选好预设即可", "Usually fine as set by the preset"))
        add(adv)
        content.setCustomSpacing(28, after: content.arrangedSubviews[content.arrangedSubviews.count - 2])
        add(ramCard())
        add(concurrencyCard())
        add(driveCard())
        add(bandwidthCard())
        add(reliabilityCard())
        add(integrityCard())
        add(filterCard())
        add(memoryCard())
        add(previewCard())
        add(languageCard())
        updateRAM(); updatePreview()
    }
    private func add(_ v: NSView) { content.addArrangedSubview(v); pinWidth(v, to: content) }

    /// 界面语言（默认英文；中文切换放在设置页最底部）
    private func languageCard() -> NSView {
        let card = CardBox(title: L("语言", "Language"))
        let lang = NSSegmentedControl(labels: ["English", "简体中文"], trackingMode: .selectOne, target: nil, action: nil)
        lang.selectedSegment = Loc.current == .zh ? 1 : 0
        lang.selectedSegmentBezelColor = Theme.accent.withAlphaComponent(0.85)
        lang.onAction { Loc.set(lang.selectedSegment == 1 ? .zh : .en) }
        card.addRow(captionedRow(title: L("界面语言", "Interface language"),
                                 caption: L("立即生效，不用重启。", "Takes effect immediately, no restart needed."),
                                 control: lang))
        return card
    }

    private func appearanceCard() -> NSView {
        let card = CardBox(title: L("外观", "Appearance"))
        var swatches: [ThemeSwatch] = []
        for t in AppTheme.allCases {
            let sw = ThemeSwatch(t)
            sw.selected = AppTheme.current == t
            sw.onPick = { picked in
                AppTheme.current = picked
                for x in swatches { x.selected = x.theme == picked }
            }
            swatches.append(sw)
        }
        card.addRow(hstack(swatches + [flexibleSpacer()], spacing: 14, alignment: .top))
        card.addRow(captionLabel(L("「深色玻璃」会让窗口半透明、透出桌面的模糊色彩，同时压暗背景保证文字清楚。侧边栏左下角的按钮也能随时切换。",
                                   "“Dark glass” makes the window translucent, showing a blurred hint of your desktop, darkened so text stays crisp. You can also switch from the button at the bottom of the sidebar."),
                                 maxWidth: 640))
        let tipsToggle = rowToggle(L("在传输页显示小技巧", "Show tips on the Transfers page"),
                                   L("一句话的使用技巧，可以点「下一条」翻看，或点 × 关掉。", "One-line tips; click Next to browse or × to hide."),
                                   get: { !UserDefaults.standard.bool(forKey: "cf.tipsHidden") },
                                   set: { UserDefaults.standard.set(!$0, forKey: "cf.tipsHidden"); NotificationCenter.default.post(name: .cfThemeChanged, object: nil) })
        card.addDivider()
        card.addRow(tipsToggle)
        return card
    }

    private func headerCard() -> NSView {
        let card = CardBox(title: nil)
        let pop = NSPopUpButton()
        pop.addItems(withTitles: Preset.all.map { $0.name })
        if let idx = Preset.all.firstIndex(where: { $0.id == engine.selectedPresetID }) { pop.selectItem(at: idx) }
        pop.widthAnchor.constraint(equalToConstant: 240).isActive = true
        pop.onAction { [weak self] in
            guard let self else { return }
            let p = Preset.all[pop.indexOfSelectedItem]; engine.applyPreset(p); rebuild()
        }
        add(to: card, captionedRow(title: L("参数预设", "Preset"),
                                   caption: L("按用途一键配好所有参数：照片卡（海量小文件）、单个大视频、通宵挂机多张卡……选好后下面的参数会跟着变。",
                                              "One click sets everything for the job: photo cards (many small files), one huge video, overnight multi-card… The options below follow it."),
                                   control: pop))
        return card
    }

    private func connectionCard() -> NSView {
        let card = CardBox(title: L("Google Drive 连接", "Google Drive connection"))
        let drives = engine.remotes.filter { $0.isDrive }
        let status = captionLabel("", maxWidth: 640)
        status.isHidden = true

        if drives.isEmpty {
            add(to: card, captionedRow(title: L("还没有连接 Google Drive", "Google Drive isn't connected"),
                                       caption: L("在浏览器里登录一次就行，不需要终端。", "Sign in once in your browser — no Terminal needed."),
                                       control: CFButton(L("连接…", "Connect…"), style: .primary, size: .small) { [weak self] in
                                           (self?.view.window?.contentViewController as? RootSplitVC)?.connectDrive() }))
            return card
        }
        for (i, r) in drives.enumerated() {
            if i > 0 { card.addDivider() }
            let own = r.usesOwnClient
            let pill = Pill(own ? L("你自己的通道", "Your own client") : L("rclone 公用通道", "rclone shared client"),
                            tint: own ? .systemGreen : .systemOrange, symbol: own ? "checkmark" : "exclamationmark.triangle.fill")
            let switchBtn = CFButton(own ? L("重新授权…", "Re-authorize…") : L("换成我自己的通道…", "Use my own client…"),
                                     style: own ? .secondary : .primary, size: .small) { [weak self] in
                (self?.view.window?.contentViewController as? RootSplitVC)?.openClientSetup(r.name)
            }
            let test = CFButton(L("测试", "Test"), style: .secondary, size: .small) { [weak self] in
                guard let self else { return }
                status.isHidden = false
                status.stringValue = L("测试「\(r.name)」中…", "Testing “\(r.name)”…"); status.textColor = .secondaryLabelColor
                Task {
                    let (ok, msg) = await self.engine.testRemote(r.name)
                    status.stringValue = (ok ? "✓ " : "✕ ") + r.name + " · " + msg
                    status.textColor = ok ? .systemGreen : .systemRed
                }
            }
            let caption = own ? L("用你自己 Google 账号名下的通道上传：不和别人抢配额，不受 rclone 公用通道停用影响。",
                                  "Uploads use a client under your own Google account: no shared quota, unaffected by the shared client's retirement.")
                              : L("全球 rclone 用户共用这个通道，会被限速，且将在 2026 年内停止工作。换成自己的约 5 分钟，文件和文件夹都不变。",
                                  "Shared by every rclone user, rate-limited, and stopping during 2026. Switching takes ~5 minutes; files and folders stay as they are.")
            let title = makeLabel(r.name); title.font = Typo.rowTitle
            let textCol = vstack([hstack([title, pill], spacing: 8), captionLabel(caption, maxWidth: 500)], spacing: 4)
            textCol.setContentHuggingPriority(.defaultLow, for: .horizontal)
            textCol.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            add(to: card, hstack([textCol, flexibleSpacer(), test, switchBtn], spacing: 8, alignment: .centerY))
        }
        add(to: card, status)
        return card
    }

    private func behaviorCard() -> NSView {
        let card = CardBox(title: L("自动化与行为", "Automation & behavior"), systemImage: "gearshape.2")
        add(to: card, rowToggle(L("自动识别外接设备并提示备份", "Auto-detect external drives and offer backup"),
            L("插入储存卡/SSD 时自动检测并在「传输队列」里提示一键备份。关闭后仍可在列表里手动备份。",
              "When a card/SSD is plugged in, detect it and offer one-click backup on the Transfers screen. When off, you can still back up manually from the list."),
            get: { self.engine.autoDetectVolumes }, set: { self.engine.autoDetectVolumes = $0 }))
        card.addDivider()
        add(to: card, rowToggle(L("储存卡备份到「卡名_日期」文件夹（推荐）", "Back up cards into “CardName_date” folders (recommended)"),
            L("相机每张卡的照片都叫 IMG_0001 这类名字、卡名也常常一样（如 EOS_DIGITAL、Untitled）。开启后每张卡备份到独立的「卡名_日期」文件夹，不同卡的同名照片绝不会互相覆盖；同一张卡同一天再备份只补传新文件。只对外接储存卡/硬盘生效，电脑里的普通文件夹仍按原名。",
              "Camera files are all named like IMG_0001 and cards often share a name (EOS_DIGITAL, Untitled). When on, each card goes into its own “CardName_date” folder, so same-named photos from different cards never overwrite each other; backing up the same card again that day only adds new files. Applies to external cards/drives only — regular folders keep their name."),
            get: { self.engine.datedCardFolders }, set: { self.engine.datedCardFolders = $0 }))
        card.addDivider()
        add(to: card, rowToggle(L("上传完成后自动核对", "Auto-check after each upload"),
            L("传完立即核对一遍网盘里的文件清单和大小（几秒到几分钟，不重新读卡）。rclone 上传时已对每个文件做过 MD5 校验，再加上这一步确认没有漏传，就会显示「已校验·可放心格式化」。想要最严格的逐个哈希比对，可在任务卡片上点盾牌图标做「完整校验」。",
              "Right after an upload, check the cloud file list and sizes (seconds to minutes, no re-reading the card). rclone already MD5-checks every file while uploading; this confirms nothing is missing, then shows “Verified · safe to format”. For the strictest per-file hash check, click the shield icon on a task for a full verify."),
            get: { self.engine.autoVerify }, set: { self.engine.autoVerify = $0 }))
        card.addDivider()
        add(to: card, rowToggle(L("出错后自动重试", "Auto-retry after errors"),
            L("遇到网络断开等临时问题时，分别在 2 分钟、10 分钟、30 分钟后自动重试，整夜挂机不怕 Wi-Fi 抖动。已传完的文件不会重传。（每日上限、网盘满、授权失效、卡被拔出这类问题不会盲目重试）",
              "On temporary problems like a network drop, retry automatically after 2, 10 and 30 minutes so overnight runs survive Wi-Fi blips. Finished files aren't re-sent. (Daily cap, full storage, auth failures and unplugged cards are not blindly retried.)"),
            get: { self.engine.autoRetryEnabled }, set: { self.engine.autoRetryEnabled = $0 }))
        card.addDivider()
        add(to: card, rowToggle(L("传输期间阻止 Mac 睡眠", "Keep Mac awake during transfers"),
            L("传输时阻止系统空闲睡眠，避免整夜挂机被中断；屏幕可以照常熄灭。（笔记本合盖仍会睡眠，需要开盖或接电源+外接显示器）",
              "Prevent idle system sleep during transfers so overnight runs aren't interrupted; the display can still turn off. (On a laptop, closing the lid still sleeps — keep it open, or use power + an external display.)"),
            get: { self.engine.keepAwakeEnabled }, set: { self.engine.keepAwakeEnabled = $0 }))
        card.addDivider()
        add(to: card, rowToggle(L("完成 / 失败发送系统通知", "Show system notifications on finish/failure"),
            L("任务完成、失败或达到每日上限时，发送 macOS 通知；点通知会回到 CloudFerry。",
              "Send a macOS notification when a task completes, fails, or hits the daily cap; clicking it brings CloudFerry forward."),
            get: { self.engine.notificationsEnabled }, set: { self.engine.notificationsEnabled = $0 }))
        card.addDivider()
        let loginStatus = makeLabel("", size: 11, color: .systemRed, multiline: true)
        add(to: card, rowToggle(L("开机自动启动", "Launch at login"),
            L("Mac 重启后自动打开 CloudFerry（在菜单栏待命），没传完的队列会自动续传。",
              "Open CloudFerry automatically after the Mac restarts (waits in the menu bar); unfinished transfers resume automatically."),
            get: { self.engine.launchAtLogin },
            set: { on in
                if let err = self.engine.setLaunchAtLogin(on) {
                    loginStatus.stringValue = L("设置失败：", "Couldn't change: ") + err
                        + L("（请确认 CloudFerry 在「应用程序」文件夹里）", " (make sure CloudFerry is in the Applications folder)")
                } else { loginStatus.stringValue = "" }
            }))
        add(to: card, loginStatus)
        return card
    }

    private func ramCard() -> NSView {
        let card = CardBox(title: L("预估内存占用", "Estimated memory use"), systemImage: "memorychip")
        ramBar = GradientProgressBar()
        ramBar.barHeight = 6
        ramBar.translatesAutoresizingMaskIntoConstraints = false
        ramBar.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let row = hstack([ramBar, ramLabel, flexibleSpacer()])
        card.addRow(row); pinWidth(row, to: card.stack)
        card.addRow(ramNote); pinWidth(ramNote, to: card.stack)
        return card
    }

    private func concurrencyCard() -> NSView {
        let card = CardBox(title: L("并发（提速的核心）", "Parallelism (the key to speed)"), systemImage: "square.stack.3d.up")
        add(to: card, rowStepper(L("并发文件数 --transfers", "Parallel files --transfers"),
            L("同时上传的文件数量。小文件多时调大能明显提速；Google Drive 一般 8–12 最稳，超过 12 建议已自建 client_id，否则易触发 403 限速反而更慢。",
              "How many files upload at once. Higher helps with many small files; 8–12 is safest for Google Drive. Above 12, use your own client_id or you'll hit 403 rate limits and go slower."),
            min: 1, max: 32, get: { self.s().transfers }, set: { v in self.edit { $0.transfers = v } }))
        card.addDivider()
        add(to: card, rowStepper(L("并发校验数 --checkers", "Parallel checkers --checkers"),
            L("同时比对本地与网盘已有文件的数量，加快跳过已备份的文件。通常略高于并发文件数。",
              "How many files are compared against the cloud at once, to skip already-backed-up files. Usually a bit above transfers."),
            min: 1, max: 64, get: { self.s().checkers }, set: { v in self.edit { $0.checkers = v } }))
        card.addDivider()
        add(to: card, rowTextField(L("上传顺序 --order-by", "Upload order --order-by"),
            L("控制先传哪些文件，如 size,mixed（大小混合）。留空为默认顺序。",
              "Controls which files go first, e.g. size,mixed. Leave blank for default order."),
            placeholder: "size,mixed", width: 160, get: { self.s().orderBy }, set: { v in self.edit { $0.orderBy = v } }))
        return card
    }

    private func driveCard() -> NSView {
        let card = CardBox(title: L("Google Drive 专项", "Google Drive specifics"), systemImage: "externaldrive.badge.icloud")
        let chunkOpts = TransferSettings.chunkSizeOptions
        add(to: card, rowPopup(L("上传分片 --drive-chunk-size", "Upload chunk --drive-chunk-size"),
            L("每个分片大小（必须是 2 的幂）。越大吞吐略高但越吃内存。RAW/照片 64Mi 足够；单个大视频用 128–256Mi。",
              "Chunk size per upload (must be a power of 2). Larger = a bit more throughput but more RAM. 64Mi is fine for photos; use 128–256Mi for a single big video."),
            items: chunkOpts.map { "\($0)Mi" }, width: 110,
            get: { chunkOpts.firstIndex(of: self.s().driveChunkSizeMiB) ?? 3 },
            set: { i in self.edit { $0.driveChunkSizeMiB = chunkOpts[i] } }))
        card.addDivider()
        let cutOpts = TransferSettings.uploadCutoffOptions
        add(to: card, rowPopup(L("单请求阈值 --drive-upload-cutoff", "Single-request cutoff --drive-upload-cutoff"),
            L("小于此大小的文件一次性上传（更少 API 往返、更快）；大于则分片。常见 RAW 用 64Mi 合适。",
              "Files below this upload in one request (fewer API round-trips); larger ones are chunked. 64Mi suits typical RAW files."),
            items: cutOpts.map { "\($0)Mi" }, width: 110,
            get: { cutOpts.firstIndex(of: self.s().driveUploadCutoffMiB) ?? 0 },
            set: { i in self.edit { $0.driveUploadCutoffMiB = cutOpts[i] } }))
        card.addDivider()
        add(to: card, rowStepper(L("请求最小间隔 --drive-pacer-min-sleep", "Min request interval --drive-pacer-min-sleep"),
            L("两次 API 请求之间最少等待（毫秒）。默认 10。太小易触发限速；遇到很多 403 可调大到 100。",
              "Minimum wait between API requests (ms). Default 10. Too low invites rate limits; raise toward 100 if you see many 403s."),
            min: 1, max: 1000, suffix: "ms", get: { self.s().pacerMinSleepMs }, set: { v in self.edit { $0.pacerMinSleepMs = v } }))
        card.addDivider()
        add(to: card, rowToggle(L("每日上限保护 --drive-stop-on-upload-limit", "Daily-cap guard --drive-stop-on-upload-limit"),
            L("达到 Google 每账号每天约 750GB 的上传上限时安全停止，队列会等次日自动续传。强烈建议开启。",
              "Stops safely when Google's ~750GB/account/day upload limit is hit; the queue resumes next day. Strongly recommended."),
            get: { self.s().stopOnUploadLimit }, set: { v in self.edit { $0.stopOnUploadLimit = v } }))
        card.addDivider()
        add(to: card, rowToggle(L("跨账号服务器端复制 --drive-server-side-across-configs", "Server-side across accounts --drive-server-side-across-configs"),
            L("两个 Google Drive 之间直接在云端复制，不经过本机。仅网盘互传时用，一般关闭。",
              "Copies directly in the cloud between two Google Drives, not via your Mac. Only for cloud-to-cloud; usually off."),
            get: { self.s().serverSideAcrossConfigs }, set: { v in self.edit { $0.serverSideAcrossConfigs = v } }))
        return card
    }

    private func bandwidthCard() -> NSView {
        let card = CardBox(title: L("带宽与每日上限", "Bandwidth & daily cap"), systemImage: "speedometer")
        add(to: card, rowDoubleField(L("每秒请求上限 --tpslimit", "Requests/sec --tpslimit"),
            L("每秒最多发多少个 API 请求。Google Drive 约 10 较稳。0 = 不限制（靠内置退避）。",
              "Max API requests per second. ~10 is stable for Google Drive. 0 = unlimited (relies on the built-in pacer)."),
            get: { self.s().tpsLimit }, set: { v in self.edit { $0.tpsLimit = v } }))
        card.addDivider()
        add(to: card, rowTextField(L("限速 --bwlimit", "Bandwidth limit --bwlimit"),
            L("单位是 MiB/s（注意 1Gbps ≈ 125MiB/s，别写成 1000）。支持时间表实现夜间不限速、白天限速，如 08:00,20M 23:00,off。留空 = 不限速。",
              "Unit is MiB/s (1Gbps ≈ 125MiB/s — don't write 1000). Supports schedules like 08:00,20M 23:00,off for daytime limits. Blank = unlimited."),
            placeholder: L("如 20M 或 08:00,20M 23:00,off", "e.g. 20M or 08:00,20M 23:00,off"), width: 260, get: { self.s().bwLimit }, set: { v in self.edit { $0.bwLimit = v } }))
        card.addDivider()
        add(to: card, rowTextField(L("本次最多传输 --max-transfer", "Max this run --max-transfer"),
            L("本任务累计传输达到此量就停。配合每日上限用，如 740G（贴近 750GB/天）。留空 = 不限。",
              "Stops this task after transferring this much. Pair with the daily cap, e.g. 740G. Blank = no limit."),
            placeholder: L("如 740G", "e.g. 740G"), width: 120, get: { self.s().maxTransfer }, set: { v in self.edit { $0.maxTransfer = v } }))
        card.addDivider()
        let modes = CutoffMode.allCases
        add(to: card, rowPopup(L("达上限处理方式 --cutoff-mode", "On cutoff --cutoff-mode"),
            L("达到上面「本次最多传输」时怎么处理：谨慎 = 传完当前文件再停（推荐）；硬性 = 立即切断；柔性 = 不再开新文件。",
              "What happens at the max-transfer limit: Cautious = finish the current file then stop (recommended); Hard = cut off immediately; Soft = start no new files."),
            items: modes.map { $0.label }, width: 150,
            get: { modes.firstIndex(of: self.s().cutoffMode) ?? 0 },
            set: { i in self.edit { $0.cutoffMode = modes[i] } }))
        return card
    }

    private func reliabilityCard() -> NSView {
        let card = CardBox(title: L("可靠性（整夜挂机）", "Reliability (overnight)"), systemImage: "moon.zzz")
        add(to: card, rowStepper(L("整体重试 --retries", "Overall retries --retries"),
            L("整个任务失败后重试的次数。整夜无人值守建议 10–20，网络抖动能自动恢复。",
              "Times to retry the whole task after a failure. 10–20 for unattended overnight runs so network blips recover."),
            min: 0, max: 50, get: { self.s().retries }, set: { v in self.edit { $0.retries = v } }))
        card.addDivider()
        add(to: card, rowStepper(L("低层重试 --low-level-retries", "Low-level retries --low-level-retries"),
            L("单个文件遇到网络小错误的重试次数。建议 20–30。", "Retries for small per-file network errors. 20–30 recommended."),
            min: 1, max: 100, get: { self.s().lowLevelRetries }, set: { v in self.edit { $0.lowLevelRetries = v } }))
        return card
    }

    private func integrityCard() -> NSView {
        let card = CardBox(title: L("完整性与行为", "Integrity & behavior"), systemImage: "checkmark.shield")
        func t(_ title: String, _ cap: String, _ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void, divider: Bool = true) {
            add(to: card, rowToggle(title, cap, get: get, set: set)); if divider { card.addDivider() }
        }
        t(L("先扫描再传 --check-first", "Scan first --check-first"),
          L("先扫描全部文件再开始上传，进度条和剩余时间更准。海量小文件建议开启。",
            "Scan everything before starting, so progress and ETA are accurate. Recommended for many small files."),
          { self.s().checkFirst }, { v in self.edit { $0.checkFirst = v } })
        t(L("哈希校验 --checksum", "Checksum --checksum"),
          L("用 MD5 逐一校验，最严格但会完整读取文件。大视频不建议开（很慢）。",
            "Verify every file by MD5 — strictest, but reads each file fully. Not recommended for big videos (slow)."),
          { self.s().checksum }, { v in self.edit { $0.checksum = v } })
        t(L("跳过已存在 --ignore-existing", "Skip existing --ignore-existing"),
          L("网盘已有同名文件就直接跳过（不比对内容）。断点续传时能加快，但坏文件不会被修复。",
            "Skip files that already exist in the cloud (no content check). Speeds up resume, but a corrupt file won't be fixed."),
          { self.s().ignoreExisting }, { v in self.edit { $0.ignoreExisting = v } })
        t(L("只更新更旧的 --update", "Only newer --update"),
          L("只在网盘文件更旧时才覆盖，避免用旧文件覆盖新文件。", "Only overwrite when the cloud copy is older, so newer files aren't clobbered."),
          { self.s().updateOlder }, { v in self.edit { $0.updateOlder = v } })
        t(L("识别改名/移动 --track-renames", "Track renames --track-renames"),
          L("文件改名或移动位置时不重复上传，直接在云端改。会占用一些内存。",
            "When files are renamed/moved, rename them in the cloud instead of re-uploading. Uses some memory."),
          { self.s().trackRenames }, { v in self.edit { $0.trackRenames = v } })
        t(L("源只读保护 --immutable", "Source read-only --immutable"),
          L("把储存卡当成只读，若传输中发现源被改动会报错停止，保护原始素材。",
            "Treat the card as read-only; stop with an error if the source changes mid-transfer, protecting originals."),
          { self.s().immutable }, { v in self.edit { $0.immutable = v } })
        t(L("仅按大小比对 --size-only", "Size-only compare --size-only"),
          L("只用文件大小判断是否已备份（最快），但不校验内容。追求速度可开。",
            "Decide 'already backed up' by size only (fastest), without checking content. Turn on for pure speed."),
          { self.s().sizeOnly }, { v in self.edit { $0.sizeOnly = v } }, divider: false)
        return card
    }

    private func filterCard() -> NSView {
        let card = CardBox(title: L("过滤（跳过不需要的文件）", "Filters (skip unwanted files)"), systemImage: "line.3.horizontal.decrease.circle")
        add(to: card, rowToggle(L("忽略系统垃圾文件", "Ignore system junk"),
            L("自动跳过 .DS_Store、._ 隐藏文件、缩略图等 macOS/系统垃圾，避免污染备份。",
              "Automatically skip .DS_Store, ._ hidden files, thumbnails and other macOS/system junk so they don't pollute the backup."),
            get: { self.s().excludeSystemJunk }, set: { v in self.edit { $0.excludeSystemJunk = v } }))
        card.addDivider()
        add(to: card, rowTextField(L("只传更早的文件 --min-age", "Only older files --min-age"),
            L("只上传修改时间早于此的文件，避免抓到正在写入的文件。如 1m（1 分钟）。留空 = 不限。",
              "Only upload files older than this, so files still being written aren't grabbed. e.g. 1m. Blank = no limit."),
            placeholder: L("如 1m", "e.g. 1m"), width: 120, get: { self.s().minAge }, set: { v in self.edit { $0.minAge = v } }))
        return card
    }

    private func memoryCard() -> NSView {
        let card = CardBox(title: L("内存与多线程", "Memory & multi-thread"), systemImage: "cpu")
        let bufOpts = [0, 8, 16, 32, 64]
        add(to: card, rowPopup(L("读取缓冲 --buffer-size", "Read buffer --buffer-size"),
            L("每个传输在内存里的读取缓冲。越大略快越吃内存（会计入内存预估）。",
              "In-memory read buffer per transfer. Larger = slightly faster but more RAM (counts toward the estimate above)."),
            items: bufOpts.map { "\($0)Mi" }, width: 110,
            get: { bufOpts.firstIndex(of: self.s().bufferSizeMiB) ?? 2 },
            set: { i in self.edit { $0.bufferSizeMiB = bufOpts[i] } }))
        card.addDivider()
        add(to: card, rowStepper(L("单文件多线程 --multi-thread-streams", "Single-file streams --multi-thread-streams"),
            L("注意：Google Drive「上传」不支持单文件多线程，此项仅对下载或部分网盘（S3/B2 等）有效。大视频上传靠调大分片，而非此项。",
              "Note: Google Drive uploads do NOT support single-file multi-threading; this only helps downloads or some backends (S3/B2). For big-video uploads, raise the chunk size instead."),
            min: 0, max: 16, get: { self.s().multiThreadStreams }, set: { v in self.edit { $0.multiThreadStreams = v } }))
        return card
    }

    private func previewCard() -> NSView {
        let card = CardBox(title: L("等效 rclone 命令（透明 · 可学习）", "Equivalent rclone command (transparent & learnable)"), systemImage: "terminal")
        previewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        previewLabel.textColor = Theme.accent
        previewLabel.isSelectable = true
        let box = themedBox(fill: Theme.terminalBG, stroke: Theme.hairline, radius: Theme.Radius.small)
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(previewLabel)
        NSLayoutConstraint.activate([
            previewLabel.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            previewLabel.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            previewLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            previewLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
        ])
        card.addRow(box); pinWidth(box, to: card.stack)
        let copyBtn = NSButton(title: L("复制", "Copy"), target: nil, action: nil)
        copyBtn.bezelStyle = .rounded; copyBtn.controlSize = .small
        copyBtn.onAction { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(engine.previewCommand(engine.settings), forType: .string)
        }
        let note = makeLabel(L("这是当前设置对应的命令行，方便你核对或自己在终端运行。", "The command line for your current settings — handy to verify or run in Terminal yourself."), size: 11, color: .secondaryLabelColor)
        let row = hstack([note, flexibleSpacer(), copyBtn])
        card.addRow(row); pinWidth(row, to: card.stack)
        return card
    }

    private func add(to card: CardBox, _ v: NSView) { card.addRow(v); pinWidth(v, to: card.stack) }

    private func updateRAM() {
        guard ramBar != nil else { return }
        let est = engine.settings.estimatedRAMBytes
        let total = engine.totalRAMBytes
        let frac = total > 0 ? Double(est) / Double(total) : 0
        let over = frac > 0.30
        ramBar.progress = Swift.min(frac, 1)
        ramLabel.stringValue = L("约 ", "~") + Format.bytes(est) + L(" / 共 ", " / ") + Format.bytes(total) + "（\(Int(frac * 100))%）"
        ramNote.stringValue = over
            ? L("⚠️ 占用偏高（>30%）。并发数 × (分片 + 缓冲) 会成倍吃内存，建议调小分片或并发。",
                "⚠️ High (>30%). transfers × (chunk + buffer) multiplies memory — reduce chunk size or transfers.")
            : L("内存占用健康。公式：并发数 × (分片大小 + 缓冲) + 约 300MB 基础。",
                "Memory looks healthy. Formula: transfers × (chunk + buffer) + ~300MB base.")
        ramNote.textColor = over ? .systemOrange : .secondaryLabelColor
    }

    private func updatePreview() {
        previewLabel.stringValue = engine.previewCommand(engine.settings)
    }
}
