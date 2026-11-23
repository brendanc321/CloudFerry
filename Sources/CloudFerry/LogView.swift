import AppKit
import Combine

@MainActor
final class LogVC: NSViewController, Refreshable {
    let engine: QueueEngine
    private let eventView = NSTextView()
    private let rcloneView = NSTextView()
    private var timer: Timer?
    private var autoScroll = true
    private var errorsOnly = false
    private var cancellables = Set<AnyCancellable>()
    private let tf = DateFormatter()

    init(engine: QueueEngine) {
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
        tf.dateFormat = "HH:mm:ss"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let (scroll, content) = makeVScroll(maxWidth: 1100)
        func add(_ v: NSView) { content.addArrangedSubview(v); pinWidth(v, to: content) }

        // 标题 + 操作
        let errToggle = NSButton(checkboxWithTitle: L("仅错误", "Errors only"), target: nil, action: nil)
        errToggle.onAction { [weak self] in self?.errorsOnly = errToggle.state == .on; self?.refreshEvents(); self?.refreshRcloneTail() }
        let autoToggle = NSButton(checkboxWithTitle: L("自动滚动", "Auto-scroll"), target: nil, action: nil)
        autoToggle.state = .on
        autoToggle.onAction { [weak self] in self?.autoScroll = autoToggle.state == .on }
        let clearBtn = button(L("清空事件", "Clear")) { [weak self] in self?.engine.clearLog() }
        add(pageHeader(L("运行日志", "Logs"),
                       subtitleText: L("出问题时看这里：App 事件写入 events.log，rclone 原始输出写入 rcd.log。", "When something goes wrong, look here: app events go to events.log, raw rclone output to rcd.log."),
                       actions: [errToggle, autoToggle, clearBtn]))
        content.setCustomSpacing(24, after: content.arrangedSubviews.last!)

        // App 事件
        let eventCard = CardBox(title: L("应用事件", "App events"), systemImage: "list.bullet.rectangle")
        let (eventScroll, ev) = styledText(height: 220)
        configure(ev); eventView.isVerticallyResizable = true
        eventCard.addRow(eventScroll); pinWidth(eventScroll, to: eventCard.stack)
        replace(container: eventScroll, with: eventView, height: 220)
        let copyEvents = button(L("复制事件", "Copy")) { [weak self] in self?.copy(self?.eventView.string ?? "") }
        eventCard.addRow(hstack([flexibleSpacer(), copyEvents]))
        add(eventCard)

        // rclone 详细日志
        let rcloneCard = CardBox(title: L("rclone 详细日志（引擎原始输出）", "rclone detailed log (raw engine output)"), systemImage: "terminal")
        let (rcloneScroll, rv) = styledText(height: 260)
        rcloneCard.addRow(rcloneScroll); pinWidth(rcloneScroll, to: rcloneCard.stack)
        replace(container: rcloneScroll, with: rcloneView, height: 260)
        let debugToggle = NSButton(checkboxWithTitle: L("DEBUG 详细模式", "DEBUG verbose"), target: nil, action: nil)
        debugToggle.state = engine.debugLogging ? .on : .off
        debugToggle.onAction { [weak self] in self?.engine.setDebugLogging(debugToggle.state == .on) }
        let openFile = button(L("在访达中显示日志", "Show logs in Finder")) { [weak self] in
            guard let u = self?.engine.logFileURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([u, AppPaths.eventsLog])
        }
        let copyLog = button(L("复制", "Copy")) { [weak self] in self?.copy(self?.rcloneView.string ?? "") }
        rcloneCard.addRow(hstack([debugToggle, flexibleSpacer(), openFile, copyLog]))
        add(rcloneCard)

        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configure(eventView); configure(rcloneView)
        engine.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.refreshEvents() }.store(in: &cancellables)
        refreshEvents(); refreshRcloneTail()
    }

    func refreshOnShow() {
        refreshEvents(); refreshRcloneTail()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRcloneTail() }
        }
    }
    override func viewWillDisappear() { super.viewWillDisappear(); timer?.invalidate(); timer = nil }

    private func configure(_ tv: NSTextView) {
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 6, height: 6)
    }

    private func refreshEvents() {
        let entries = engine.log.filter { !errorsOnly || $0.level == .error || $0.level == .warn }
        let out = NSMutableAttributedString()
        for e in entries.suffix(800) {
            let time = NSAttributedString(string: tf.string(from: e.time) + " ",
                attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)])
            let tag = NSAttributedString(string: "[\(e.level.tag)] ",
                attributes: [.foregroundColor: e.level.color, .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)])
            let msg = NSAttributedString(string: e.message + "\n",
                attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)])
            out.append(time); out.append(tag); out.append(msg)
        }
        eventView.textStorage?.setAttributedString(out)
        if autoScroll { eventView.scrollToEndOfDocument(nil) }
    }

    private func refreshRcloneTail() {
        // 只读文件末尾 60KB（DEBUG 日志可能几十 MB，整个读进内存会卡）
        guard let fh = try? FileHandle(forReadingFrom: engine.logFileURL) else { rcloneView.string = L("（暂无日志）", "(no log yet)"); return }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > 60_000 ? size - 60_000 : 0
        try? fh.seek(toOffset: start)
        let tail = (try? fh.readToEnd()) ?? Data()
        var text = String(decoding: tail, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        if errorsOnly {
            text = text.split(separator: "\n").filter { $0.contains("ERROR") || $0.contains("error") }.joined(separator: "\n")
        }
        if rcloneView.string != text {
            rcloneView.string = text
            if autoScroll { rcloneView.scrollToEndOfDocument(nil) }
        }
    }

    private func styledText(height: CGFloat) -> (NSScrollView, NSTextView) {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.borderType = .lineBorder
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.heightAnchor.constraint(equalToConstant: height).isActive = true
        return (sv, NSTextView())
    }
    // 把我们持有的 textView 装进 scrollView
    private func replace(container: NSScrollView, with tv: NSTextView, height: CGFloat) {
        tv.minSize = NSSize(width: 0, height: height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        container.documentView = tv
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        CFButton(title, style: .secondary, size: .small, action: action)
    }
    private func copy(_ s: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
    }
}
