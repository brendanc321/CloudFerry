import AppKit

@MainActor
final class HelpVC: NSViewController {
    let engine: QueueEngine
    init(engine: QueueEngine) { self.engine = engine; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() { let (s, c) = makeVScroll(maxWidth: 780); content = c; content.spacing = 20; view = s }
    private var content: NSStackView!
    private func add(_ v: NSView) { content.addArrangedSubview(v); pinWidth(v, to: content) }

    override func viewDidLoad() {
        super.viewDidLoad()
        let logo = NSImageView(image: makeLogoImage(size: 56))
        logo.widthAnchor.constraint(equalToConstant: 56).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let name = makeLabel("CloudFerry"); name.font = Typo.pageTitle
        let ver = Pill("v" + AppInfo.version, tint: Theme.accent)
        let tagline = makeLabel(L("为摄影师打造的 rclone 图形界面 · 储存卡直传网盘，不占本机空间",
                                  "An rclone GUI for photographers · card → cloud, without using local space"), color: .secondaryLabelColor)
        tagline.font = Typo.body
        add(hstack([logo, vstack([hstack([name, ver], spacing: 10), tagline], spacing: 4), flexibleSpacer()], spacing: 16))
        content.setCustomSpacing(28, after: content.arrangedSubviews.last!)

        card(L("为什么不占电脑空间、也不卡？", "Why it uses no space and stays smooth"), "bolt.heart", [
            L("拖入文件夹/储存卡时，只记录路径，不会拷贝到本机，也不逐个扫描——所以上万个文件秒进队列、不卡。",
              "Dropping a folder/card records only the path — nothing is copied to your Mac and nothing is scanned one-by-one, so tens of thousands of files queue instantly without lag."),
            L("上传时由 rclone 直接从卡读取、在内存里分片、流式传到网盘，全程不在本机硬盘生成临时文件。",
              "During upload, rclone reads from the card, chunks in memory, and streams to the cloud — no temp files on your disk."),
            L("因此备份 256GB 甚至上 TB，本机可用空间是 0 也没关系。",
              "So you can back up 256GB or even TBs with zero free space on your Mac."),
        ])
        factCard(L("几个被网上说法误导的关键点", "A few widely-misunderstood points"), "checkmark.seal", [
            (L("单个大文件（如 200–500GB 视频）无法「多线程」上传到 Google Drive。", "A single huge file (e.g. a 200–500GB video) can't be uploaded 'multi-threaded' to Google Drive."),
             L("Drive 后端不支持单文件多线程，加大「并发数」对单个大文件没用；靠调大「上传分片」和保持网络稳定。",
               "The Drive backend has no single-file multi-threading — raising 'transfers' does nothing for one big file; use a larger chunk size and a stable network.")),
            (L("务必自建 Google client_id。", "Always create your own Google client_id."),
             L("rclone 共享的默认 client_id 会被全球用户共用限速，且 Google 已通知将在 2026 年内停用。自建免费、更快更稳。",
               "rclone's shared client_id is throttled across all users, and Google will retire it during 2026. Your own is free, faster, and more reliable.")),
            (L("Google Drive 每账号每天约 750GB 上传上限。", "Google Drive caps uploads at ~750GB per account per day."),
             L("达到后该账号约 24 小时内无法再上传。本 App 已内置保护：到达即安全停止，队列会等次日自动续传。",
               "After that the account can't upload for ~24h. The app guards this: it stops safely and the queue resumes the next day.")),
            (L("瓶颈通常是网络，不是读卡速度。", "The bottleneck is usually the network, not card read speed."),
             L("1Gbps 实际约 110–118MB/s，和 UHS-I 卡的读取速度（约 90–100MB/s）相当，低于 UHS-II / CFexpress，所以卡速一般不是上传快慢的关键。",
               "1Gbps is ~110–118MB/s in practice — about the same as a UHS-I card read (~90–100MB/s) and below UHS-II / CFexpress — so card speed rarely determines upload time.")),
            (L("把照片打包成压缩包上传，是有代价的取舍。", "Zipping photos before upload is a trade-off, not a clear win."),
             L("虽然减少了文件数，但大压缩包一旦中断会整包从头重传，且失去逐张浏览/增量同步能力。多数情况直接传原文件更省心。",
               "Fewer files, yes — but a big archive restarts from zero if interrupted, and you lose per-photo browsing and incremental sync. Usually uploading originals is simpler.")),
        ])
        card(L("整夜挂机备份多张卡", "Overnight backup of multiple cards"), "moon.stars", [
            L("插入多张卡后逐个拖入，它们会自动排队，一个传完传下一个（共用一条上行带宽，串行最快也最稳）。",
              "Insert several cards and drop them one by one; they queue and run one at a time (they share one uplink, so serial is both fastest and most stable)."),
            L("传输期间自动阻止 Mac 睡眠。注意：合盖仍可能睡眠——整夜挂机建议开盖，或接电源+外接显示器。",
              "The Mac is kept awake during transfers. Note: closing the lid can still sleep it — for overnight runs keep the lid open, or use power + an external display."),
            L("断点续传（文件级）：崩溃或重启后会跳过已传好的文件，从没传完的继续。",
              "Resume (file level): after a crash/restart, already-uploaded files are skipped and it continues from the unfinished ones."),
            L("断点续传（单个大文件）：同一次运行中遇到网络抖动会自动从中断处续传、不从头重来；但若整个 App 退出/重启/关机，正在传的那个超大文件会从头重传（rclone 对 Google Drive 不跨进程续传）——所以整夜传大视频务必保持开机、稳定网络。",
              "Resume (single big file): within one run, network blips resume from where they stopped, not from scratch; but if the app quits/restarts/the Mac shuts down, the in-flight huge file restarts from zero (rclone can't resume a Drive session across processes) — so keep the machine on with a stable network for overnight big videos."),
            L("每次上传完成会自动核对一遍（确认没有漏传；rclone 上传时本来就逐个做了 MD5 校验），显示「已校验·可放心格式化」后再格式化储存卡。想更严格，可在任务卡片上点盾牌图标做完整哈希校验。",
              "Each upload is automatically checked afterwards (nothing missing; rclone already MD5-checks every file while uploading). Format the card once it shows 'Verified · safe to format'. For the strictest check, click the shield icon for a full hash verify."),
            L("网络断开等临时错误会在 2、10、30 分钟后自动重试；后台服务意外退出会自动重启并续传。",
              "Temporary errors such as a dropped network are retried after 2, 10 and 30 minutes; if the engine crashes it restarts and continues automatically."),
        ])
        card(L("不同储存卡不会互相覆盖", "Different cards never overwrite each other"), "sdcard", [
            L("相机照片都叫 IMG_0001、C0001 这类名字，很多卡的卷名也一样（EOS_DIGITAL、Untitled）。如果都备份到同一个文件夹，后一张卡会把前一张卡的同名照片覆盖掉。",
              "Camera files are all named like IMG_0001 / C0001 and many cards share a volume name (EOS_DIGITAL, Untitled). Backing them all into one folder would let a later card overwrite an earlier card's same-named photos."),
            L("所以储存卡默认备份到「卡名_日期」文件夹，例如 EOS_DIGITAL_2026-11-22；同一天第二张同名卡会变成 EOS_DIGITAL_2026-11-22_2。同一张卡（按卡的唯一编号识别）当天再拖一次，只补传新拍的。",
              "So cards go into a “CardName_date” folder by default, e.g. EOS_DIGITAL_2026-11-22; a second same-named card that day becomes EOS_DIGITAL_2026-11-22_2. Dropping the same card (recognized by its unique ID) again that day only uploads new shots."),
            L("「历史记录」里会永久记录每张卡什么时候备份到了哪里、有没有校验；插卡时也会提示「上次备份于…」。",
              "History permanently records when each card was backed up, where, and whether it was verified; plugging in a card shows “Backed up … ago”."),
        ])
        card(L("安全", "Safety"), "lock.shield", [
            L("备份用的是 copy（只增不删），不会删除网盘里的东西，也不会改动你储存卡里的原始文件。",
              "Backup uses copy (add-only): it never deletes anything in the cloud and never modifies the originals on your card."),
            L("后台服务只监听本机 127.0.0.1，并使用随机密码，外部无法访问。",
              "The engine listens only on 127.0.0.1 with a random password — nothing external can reach it."),
            L("你的网盘登录信息由 rclone 自己保管（存于 rclone 配置文件），本 App 不接触你的密码。",
              "Your cloud login is kept by rclone itself (in its config file); the app never touches your password."),
        ])
        add(captionLabel(L("基于开源项目 rclone。CloudFerry 是它的图形界面。", "Built on the open-source rclone. CloudFerry is a GUI front-end for it."), color: .tertiaryLabelColor))
    }

    /// 段落：带行距的正文（中文长句更易读）
    private func para(_ text: String, color: NSColor = .labelColor, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let l = makeLabel("", multiline: true)
        let ps = NSMutableParagraphStyle(); ps.lineSpacing = 3
        l.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: ps])
        return l
    }
    private func bulletRow(_ text: String) -> NSView {
        let dot = themedBox(fill: Theme.accent, radius: 2.5, border: 0)
        dot.widthAnchor.constraint(equalToConstant: 5).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 5).isActive = true
        let wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(dot)
        NSLayoutConstraint.activate([wrap.widthAnchor.constraint(equalToConstant: 5), dot.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                                     dot.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 7)])
        let l = para(text)
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let h = hstack([wrap, l], spacing: 12, alignment: .top)
        wrap.heightAnchor.constraint(equalTo: h.heightAnchor).isActive = true
        return h
    }
    private func card(_ title: String, _ icon: String, _ bullets: [String]) {
        add(sectionTitle(title))
        content.setCustomSpacing(10, after: content.arrangedSubviews.last!)
        let c = CardBox(title: nil)
        c.stack.spacing = 14
        for b in bullets { c.addRow(bulletRow(b)) }
        add(c)
    }
    private func factCard(_ title: String, _ icon: String, _ facts: [(String, String)]) {
        add(sectionTitle(title))
        content.setCustomSpacing(10, after: content.arrangedSubviews.last!)
        let c = CardBox(title: nil)
        for (i, (t, b)) in facts.enumerated() {
            if i > 0 { c.addDivider() }
            let col = vstack([para(t, weight: .semibold), para(b, color: .secondaryLabelColor, size: 12.5)], spacing: 4)
            c.addRow(col)
            for v in col.arrangedSubviews { v.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true }
        }
        add(c)
    }
}
