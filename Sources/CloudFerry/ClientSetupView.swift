import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Google OAuth 客户端凭据（自建通道）

/// 用户自己的 Google OAuth 客户端（client_id + client_secret）。
/// 来源：Google Cloud 控制台「下载 JSON」得到的 client_secret_….json，或手动粘贴。
struct GoogleClientCredentials: Equatable {
    var clientID: String
    var clientSecret: String

    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
         .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`,; "))
    }

    static func looksLikeClientID(_ s: String) -> Bool {
        let t = clean(s)
        return t.hasSuffix(".apps.googleusercontent.com") && t.count > 40 && !t.contains(" ")
    }

    enum SecretCheck { case ok, unusual, empty, isClientID }
    static func checkSecret(_ s: String, clientID: String) -> SecretCheck {
        let t = clean(s)
        if t.isEmpty { return .empty }
        if t == clean(clientID) || looksLikeClientID(t) { return .isClientID }
        return t.hasPrefix("GOCSPX-") && t.count > 20 ? .ok : .unusual
    }

    enum ParseError: Error { case notJSON, webClient, missing }

    /// 解析 Google 下载的 JSON：{"installed": {...}} 是「桌面应用」（rclone 需要这个）；{"web": {...}} 是「网页应用」。
    static func parse(jsonData: Data) -> Result<GoogleClientCredentials, ParseError> {
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return .failure(.notJSON) }
        if let inst = obj["installed"] as? [String: Any] ?? (obj["client_id"] != nil ? obj : nil) {
            let id = clean(inst["client_id"] as? String ?? "")
            let secret = clean(inst["client_secret"] as? String ?? "")
            guard looksLikeClientID(id), !secret.isEmpty else { return .failure(.missing) }
            return .success(GoogleClientCredentials(clientID: id, clientSecret: secret))
        }
        if obj["web"] != nil { return .failure(.webClient) }
        return .failure(.missing)
    }

    /// 从任意文本（比如剪贴板）里找出 client_id / client_secret
    static func scan(text: String) -> (id: String?, secret: String?) {
        if let d = text.data(using: .utf8), case .success(let c) = parse(jsonData: d) { return (c.clientID, c.clientSecret) }
        func first(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range, in: text) else { return nil }
            return String(text[r])
        }
        return (first("[0-9]{6,}-[a-z0-9]{10,}\\.apps\\.googleusercontent\\.com"), first("GOCSPX-[A-Za-z0-9_\\-]{10,}"))
    }

    /// 只显示末尾几位，避免在界面/日志里露出完整 ID
    static func shortID(_ id: String) -> String {
        let head = id.components(separatedBy: ".apps.googleusercontent.com").first ?? id
        return head.count > 14 ? String(head.prefix(6)) + "…" + String(head.suffix(4)) : head
    }
}

// MARK: - 向导：换成你自己的 Google 通道

@MainActor
final class ClientSetupVC: NSViewController, NSTextFieldDelegate {
    let engine: QueueEngine
    private let preselect: String?
    private var cancellables = Set<AnyCancellable>()

    private let idField = NSTextField(string: "")
    private let secretField = NSSecureTextField(string: "")
    private let idCheck = makeLabel("", size: 11, color: .secondaryLabelColor)
    private let secretCheck = makeLabel("", size: 11, color: .secondaryLabelColor)
    private let importNote = makeLabel("", size: 11, color: .secondaryLabelColor, multiline: true)
    private let remotePopup = NSPopUpButton()
    private let currentLabel = makeLabel("", size: 12, color: .secondaryLabelColor, multiline: true)
    private let connectBtn = CFButton(L("连接并授权（打开浏览器）", "Connect & authorize (opens browser)"), style: .primary, size: .large, symbol: "arrow.up.forward.app")
    private let cancelBtn = CFButton(L("取消", "Cancel"), style: .secondary, size: .large)
    private let spinner = NSProgressIndicator()
    private let statusLabel = makeLabel("", size: 12, color: .secondaryLabelColor, multiline: true)
    private var targetNames: [String] = []

    private let prefill: GoogleClientCredentials?
    private let prefillSource: String?
    private let autoConnect: Bool

    init(engine: QueueEngine, preselect: String? = nil, prefill: GoogleClientCredentials? = nil,
         prefillSource: String? = nil, autoConnect: Bool = false) {
        self.engine = engine; self.preselect = preselect
        self.prefill = prefill; self.prefillSource = prefillSource; self.autoConnect = autoConnect
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 780)) }

    /// 步骤标题：圆形编号 + 标题
    private func stepHeader(_ n: Int, _ title: String) -> NSView {
        let num = makeLabel("\(n)", color: Theme.onAccent); num.font = .systemFont(ofSize: 12, weight: .bold)
        num.alignment = .center
        let badge = themedBox(fill: Theme.accent, radius: 11, border: 0)
        num.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(num)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 22), badge.heightAnchor.constraint(equalToConstant: 22),
            num.centerXAnchor.constraint(equalTo: badge.centerXAnchor), num.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])
        return hstack([badge, sectionTitle(title), flexibleSpacer()], spacing: 10)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("换成你自己的 Google 通道", "Use your own Google client")
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

        let t = makeLabel(L("换成你自己的 Google 通道", "Use your own Google client")); t.font = Typo.pageTitle
        add(t)
        let intro = makeLabel(L("rclone 的公用通道是全球用户共用的：会被限速，而且 rclone 官方说明它将在 2026 年内停止工作。换成你自己的通道后，上传更稳、不和别人抢配额，也不怕停用。网盘里的文件、备份文件夹、队列和历史记录都不受影响。",
                                "rclone's shared client is used by everyone: it's rate-limited, and rclone says it will stop working during 2026. With your own client, uploads are steadier, you don't share quota, and nothing breaks when it's retired. Your files, backup folders, queue and history stay as they are."),
                              color: .secondaryLabelColor, multiline: true)
        intro.font = Typo.body
        add(intro)
        content.setCustomSpacing(24, after: intro)

        // ① Google Cloud 准备
        add(stepHeader(1, L("在 Google Cloud 准备通道（只需一次，约 5 分钟）", "Prepare it in Google Cloud (once, ~5 min)")))
        let prep = CardBox(title: nil)
        let steps: [(String, String, String)] = [
            (L("启用 Google Drive API", "Enable the Google Drive API"),
             L("打开后点「启用 / Enable」。已启用会显示「管理」。", "Click Enable. If it says Manage, it's already on."),
             "https://console.cloud.google.com/apis/library/drive.googleapis.com"),
            (L("发布应用（不发布的话，授权 7 天后就会过期）", "Publish the app (otherwise sign-in expires after 7 days)"),
             L("「目标对象 Audience」→「发布应用 Publish app」→ 确认。状态应为「正式版 In production」。", "Audience → Publish app → Confirm. Status should read “In production”."),
             "https://console.cloud.google.com/auth/audience"),
            (L("新建 OAuth 客户端 → 类型选「桌面应用 Desktop app」", "Create an OAuth client → type “Desktop app”"),
             L("创建后弹窗里点「下载 JSON」（密钥只在这时显示一次）。已有客户端也可以在详情页「添加密钥 Add secret」。", "In the dialog that follows, click Download JSON (the secret is shown only once). For an existing client, use Add secret on its page."),
             "https://console.cloud.google.com/auth/clients"),
        ]
        for (i, s) in steps.enumerated() {
            let url = URL(string: s.2)!
            let b = CFButton(L("打开", "Open"), style: .secondary, size: .small, symbol: "arrow.up.right") { NSWorkspace.shared.open(url) }
            prep.addRow(captionedRow(title: s.0, caption: s.1, control: b))
            if i < steps.count - 1 { prep.addDivider() }
        }
        let guideBtn = CFButton(L("rclone 官方图文教程", "rclone's official guide"), style: .plain, size: .small) {
            NSWorkspace.shared.open(URL(string: "https://rclone.org/drive/#making-your-own-client-id")!)
        }
        prep.addDivider()
        prep.addRow(hstack([captionLabel(L("已经做过就直接看第 2 步。", "Already done? Skip to step 2.")), flexibleSpacer(), guideBtn]))
        add(prep)
        content.setCustomSpacing(26, after: prep)

        // ② 导入凭据
        add(stepHeader(2, L("导入凭据", "Import the credentials")))
        let creds = CardBox(title: nil)
        let drop = DropView()
        drop.translatesAutoresizingMaskIntoConstraints = false
        drop.heightAnchor.constraint(equalToConstant: 78).isActive = true
        let dropLabel = makeLabel(L("把 Google 下载的 client_secret_….json 拖到这里", "Drop the client_secret_….json you downloaded from Google here"),
                                  size: 13, weight: .medium, color: .secondaryLabelColor)
        let pickBtn = CFButton(L("选择文件…", "Choose file…"), style: .secondary, size: .small) { [weak self] in self?.pickFile() }
        let dropInner = vstack([dropLabel, pickBtn], spacing: 6, alignment: .centerX)
        dropInner.translatesAutoresizingMaskIntoConstraints = false
        drop.addSubview(dropInner)
        NSLayoutConstraint.activate([
            dropInner.centerXAnchor.constraint(equalTo: drop.centerXAnchor),
            dropInner.centerYAnchor.constraint(equalTo: drop.centerYAnchor),
        ])
        drop.onDrop = { [weak self] urls in self?.importFiles(urls) }
        creds.addRow(drop)
        creds.addRow(importNote)

        let orLabel = makeLabel(L("或者手动粘贴", "Or paste them"), color: .secondaryLabelColor); orLabel.font = Typo.rowTitle
        let pasteBtn = CFButton(L("从剪贴板粘贴", "Paste from clipboard"), style: .secondary, size: .small, symbol: "doc.on.clipboard") { [weak self] in self?.pasteFromClipboard() }
        creds.addRow(hstack([orLabel, flexibleSpacer(), pasteBtn]))

        idField.placeholderString = "1234567890-abc….apps.googleusercontent.com"
        secretField.placeholderString = "GOCSPX-…"
        for f in [idField, secretField] as [NSTextField] {
            f.delegate = self
            f.font = Theme.mono(12)
            f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        creds.addRow(fieldRow(L("客户端 ID", "Client ID"), idField, idCheck))
        creds.addRow(fieldRow(L("客户端密钥", "Client secret"), secretField, secretCheck))
        add(creds)
        content.setCustomSpacing(26, after: creds)

        // ③ 连接并授权
        add(stepHeader(3, L("连接并授权", "Connect and authorize")))
        let go = CardBox(title: nil)
        rebuildTargets()
        remotePopup.onAction { [weak self] in self?.updateCurrentLabel() }
        remotePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        go.addRow(hstack([makeLabel(L("要切换的网盘", "Remote to switch"), size: 13, weight: .medium), flexibleSpacer(), remotePopup]))
        go.addRow(currentLabel)
        go.addDivider()
        let warn = makeLabel(L("浏览器会打开 Google 登录页。因为这个通道只有你自己用，Google 会提示「Google 尚未验证此应用」——这是正常的：点「高级」→「转至 …（不安全）」→ 勾选允许访问 Google Drive →「继续」。",
                               "A browser opens Google's sign-in. Because only you use this client, Google shows “Google hasn't verified this app” — that's expected: click Advanced → Go to … (unsafe) → allow Google Drive access → Continue."),
                             size: 12, multiline: true)
        go.addRow(warn)
        let safe = makeLabel(L("放心：授权没完成或新通道测试不通过时，原来的连接会原样保留；测试通过才替换。",
                               "Safe: if sign-in doesn't finish or the new client fails its test, the current connection is kept as is. It's only replaced after a passing test."),
                             size: 11, color: .secondaryLabelColor, multiline: true)
        go.addRow(safe)

        connectBtn.keyEquivalent = "\r"
        connectBtn.onAction { [weak self] in self?.startConnect() }
        cancelBtn.isHidden = true
        cancelBtn.onAction { [weak self] in self?.engine.cancelConnect() }
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isHidden = true
        go.addRow(hstack([connectBtn, cancelBtn, spinner, flexibleSpacer()]))
        go.addRow(statusLabel)
        statusLabel.isHidden = true
        add(go)

        let close = CFButton(L("关闭", "Close"), style: .secondary) { [weak self] in self.map { $0.dismiss($0) } }
        close.keyEquivalent = "\u{1b}"
        add(hstack([flexibleSpacer(), close]))

        engine.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            DispatchQueue.main.async { self?.syncBusy() }
        }.store(in: &cancellables)
        updateCurrentLabel()
        if let c = prefill {
            idField.stringValue = c.clientID
            secretField.stringValue = c.clientSecret
            setImportNote(L("✅ 已从「\(prefillSource ?? "JSON")」导入。", "✅ Imported from “\(prefillSource ?? "JSON")”."), .systemGreen)
        }
        validate()
        syncBusy()
        // 通过「用 CloudFerry 打开凭据文件」进来的：自动开始连接（浏览器里仍需在 Google 页面确认授权）
        if autoConnect, prefill != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, !self.engine.connecting, self.validate() else { return }
                self.startConnect()
            }
        }
    }

    private func fieldRow(_ title: String, _ field: NSTextField, _ check: NSTextField) -> NSView {
        let l = makeLabel(title, size: 13, weight: .medium)
        l.widthAnchor.constraint(equalToConstant: 84).isActive = true
        let col = vstack([field, check], spacing: 3)
        field.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        col.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return hstack([l, col], alignment: .top)
    }

    // MARK: 目标网盘

    private func rebuildTargets() {
        let drives = engine.remotes.filter { $0.isDrive }.map { $0.name }
        targetNames = drives.isEmpty ? ["gdrive"] : drives
        remotePopup.removeAllItems()
        for n in targetNames {
            let exists = drives.contains(n)
            remotePopup.addItem(withTitle: exists ? n : n + L("（新建）", " (new)"))
        }
        let want = preselect ?? (drives.contains(engine.defaultDestRemote ?? "") ? engine.defaultDestRemote : nil)
            ?? engine.remotes.first(where: { $0.isDrive && !$0.usesOwnClient })?.name
        if let want, let i = targetNames.firstIndex(of: want) { remotePopup.selectItem(at: i) }
    }

    private var targetName: String { targetNames[safe: remotePopup.indexOfSelectedItem] ?? "gdrive" }

    private func updateCurrentLabel() {
        guard let r = engine.remote(named: targetName) else {
            currentLabel.stringValue = L("还没有这个网盘，会新建一个并设为默认备份目的地。", "This remote doesn't exist yet; it will be created and set as the default destination.")
            currentLabel.textColor = .secondaryLabelColor
            return
        }
        if r.usesOwnClient {
            currentLabel.stringValue = L("现在：已经在用你自己的通道（", "Now: already using your own client (") + GoogleClientCredentials.shortID(r.clientID ?? "")
                + L("）。重新授权或换成另一个客户端也可以在这里做。", "). You can re-authorize or switch to another client here.")
            currentLabel.textColor = .systemGreen
            if idField.stringValue.isEmpty, let id = r.clientID { idField.stringValue = id; validate() }
        } else {
            currentLabel.stringValue = L("现在：rclone 公用通道（2026 年内停用）→ 将换成你自己的通道。", "Now: rclone's shared client (retiring in 2026) → will switch to your own.")
            currentLabel.textColor = .systemOrange
        }
    }

    // MARK: 导入

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = L("选择 Google 下载的 client_secret_….json", "Choose the client_secret_….json downloaded from Google")
        guard let win = view.window else { return }
        panel.beginSheetModal(for: win) { [weak self] resp in
            if resp == .OK, let u = panel.url { self?.importFiles([u]) }
        }
    }

    private func importFiles(_ urls: [URL]) {
        guard let u = urls.first(where: { $0.pathExtension.lowercased() == "json" }) else {
            setImportNote(L("❌ 请拖入 .json 文件（Google 控制台里「下载 JSON」得到的）。", "❌ Please drop a .json file (from Download JSON in Google Console)."), .systemRed)
            return
        }
        let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size < 64_000, let data = try? Data(contentsOf: u) else {
            setImportNote(L("❌ 读不了这个文件。", "❌ Couldn't read this file."), .systemRed); return
        }
        switch GoogleClientCredentials.parse(jsonData: data) {
        case .success(let c):
            idField.stringValue = c.clientID
            secretField.stringValue = c.clientSecret
            setImportNote(L("✅ 已从「\(u.lastPathComponent)」导入。用完可以把这个文件删掉（凭据会保存在 rclone 配置里）。",
                            "✅ Imported from “\(u.lastPathComponent)”. You can delete the file afterwards (the credentials are saved in rclone's config)."), .systemGreen)
        case .failure(.webClient):
            setImportNote(L("❌ 这是「网页应用 Web application」类型的客户端。请新建一个「桌面应用 Desktop app」类型的客户端，再下载它的 JSON。",
                            "❌ This is a “Web application” client. Create a “Desktop app” client instead and download its JSON."), .systemRed)
        case .failure(.missing):
            setImportNote(L("❌ 这个 JSON 里没有完整的客户端 ID 和密钥。Google 新版控制台只在创建时显示一次密钥：请在客户端详情页点「添加密钥」，再下载 JSON。",
                            "❌ This JSON lacks a full client ID and secret. Google shows the secret only once: on the client's page click Add secret, then download the JSON."), .systemRed)
        case .failure(.notJSON):
            setImportNote(L("❌ 这不是 Google 的凭据 JSON。", "❌ This isn't a Google credentials JSON."), .systemRed)
        }
        validate()
    }

    private func pasteFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let (id, secret) = GoogleClientCredentials.scan(text: text)
        if let id { idField.stringValue = id }
        if let secret { secretField.stringValue = secret }
        if id == nil && secret == nil {
            setImportNote(L("剪贴板里没找到客户端 ID（…apps.googleusercontent.com）或密钥（GOCSPX-…）。", "No client ID (…apps.googleusercontent.com) or secret (GOCSPX-…) found on the clipboard."), .systemOrange)
        } else {
            setImportNote(L("已从剪贴板填入", "Filled from clipboard") + (id != nil ? L(" 客户端 ID", " client ID") : "") + (secret != nil ? L(" 密钥", " secret") : "")
                          + L("。Google 的复制按钮一次只复制一项，另一项再复制一次后点这里即可。", ". Google's copy buttons copy one value at a time — copy the other and click again."), .secondaryLabelColor)
        }
        validate()
    }

    private func setImportNote(_ s: String, _ c: NSColor) { importNote.stringValue = s; importNote.textColor = c }

    func controlTextDidChange(_ obj: Notification) { validate() }

    // MARK: 校验

    @discardableResult
    private func validate() -> Bool {
        let id = GoogleClientCredentials.clean(idField.stringValue)
        let secret = GoogleClientCredentials.clean(secretField.stringValue)
        var ok = true
        if id.isEmpty { idCheck.stringValue = L("以 .apps.googleusercontent.com 结尾", "Ends with .apps.googleusercontent.com"); idCheck.textColor = .secondaryLabelColor; ok = false }
        else if GoogleClientCredentials.looksLikeClientID(id) { idCheck.stringValue = "✓ " + GoogleClientCredentials.shortID(id); idCheck.textColor = .systemGreen }
        else { idCheck.stringValue = L("❌ 不像客户端 ID：应以 .apps.googleusercontent.com 结尾", "❌ Doesn't look like a client ID (should end with .apps.googleusercontent.com)"); idCheck.textColor = .systemRed; ok = false }

        switch GoogleClientCredentials.checkSecret(secret, clientID: id) {
        case .empty: secretCheck.stringValue = L("以 GOCSPX- 开头（不是客户端 ID）", "Starts with GOCSPX- (not the client ID)"); secretCheck.textColor = .secondaryLabelColor; ok = false
        case .isClientID: secretCheck.stringValue = L("❌ 这里填成了客户端 ID。密钥是另一串，以 GOCSPX- 开头。", "❌ That's the client ID. The secret is a different string starting with GOCSPX-."); secretCheck.textColor = .systemRed; ok = false
        case .unusual: secretCheck.stringValue = L("⚠️ 通常以 GOCSPX- 开头，请确认没复制错", "⚠️ Usually starts with GOCSPX- — double-check it"); secretCheck.textColor = .systemOrange
        case .ok: secretCheck.stringValue = "✓ GOCSPX-•••• (\(secret.count))"; secretCheck.textColor = .systemGreen
        }
        if !engine.connecting { connectBtn.isEnabled = ok }
        return ok
    }

    // MARK: 连接

    private func syncBusy() {
        let busy = engine.connecting
        spinner.isHidden = !busy
        cancelBtn.isHidden = !busy
        remotePopup.isEnabled = !busy
        if busy {
            spinner.startAnimation(nil)
            connectBtn.isEnabled = false
            if !engine.connectPhase.isEmpty { statusLabel.isHidden = false; statusLabel.stringValue = engine.connectPhase; statusLabel.textColor = .secondaryLabelColor }
        } else {
            spinner.stopAnimation(nil)
            validate()
        }
    }

    private func startConnect() {
        guard validate() else { return }
        let name = targetName
        let id = GoogleClientCredentials.clean(idField.stringValue)
        let secret = GoogleClientCredentials.clean(secretField.stringValue)
        statusLabel.isHidden = false
        statusLabel.stringValue = L("正在打开浏览器…", "Opening the browser…"); statusLabel.textColor = .secondaryLabelColor
        engine.connectDrive(name: name, clientID: id, clientSecret: secret, useOwnClientID: true) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.statusLabel.stringValue = L("✅ 切换成功：「\(name)」现在使用你自己的通道。", "✅ Done: “\(name)” now uses your own client.")
                    + (self.engine.lastConnectDetail.map { "\n" + $0 } ?? "")
                self.statusLabel.textColor = .systemGreen
                self.rebuildTargets(); self.updateCurrentLabel()
                fadeIn(self.statusLabel)
            } else {
                self.statusLabel.stringValue = "❌ " + (self.engine.lastConnectFailure ?? L("没有完成。", "Didn't complete."))
                    + L("\n常见原因：没点「发布应用」/ 浏览器里点了取消 / 密钥填错。改好后再点一次即可。",
                        "\nCommon causes: app not published / canceled in the browser / wrong secret. Fix it and click again.")
                self.statusLabel.textColor = .systemRed
            }
        }
    }
}
