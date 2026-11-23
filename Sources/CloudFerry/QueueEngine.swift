import Foundation
import Combine
import AppKit
import UserNotifications
import ServiceManagement

struct PersistState: Codable {
    var settings: TransferSettings
    var jobs: [TransferJob]
    var selectedPresetID: String
    var defaultDestRemote: String?
    var defaultDestPath: String
    // v1.1（可选字段，兼容旧版）
    var dailyCapUntil: Date? = nil
    var dailyUploads: [String: Int64]? = nil
}

struct LogEntry: Identifiable {
    enum Level: String { case info, warn, error, success
        var color: NSColor {
            switch self { case .info: return .secondaryLabelColor; case .warn: return .systemOrange
            case .error: return .systemRed; case .success: return .systemGreen }
        }
        var tag: String {
            switch self {
            case .info: return L("信息", "INFO")
            case .warn: return L("警告", "WARN")
            case .error: return L("错误", "ERROR")
            case .success: return L("成功", "OK")
            }
        }
    }
    let id = UUID()
    let time: Date
    let level: Level
    let message: String
}

enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.3.1"
    }
}

@MainActor
final class QueueEngine: ObservableObject {
    // 引擎状态
    @Published var status: String = L("未启动", "Not started")
    @Published var ready: Bool = false
    @Published var rclonePath: String? = nil
    @Published var rcloneVersion: String = ""
    @Published var lastError: String? = nil
    /// 网盘授权失效（令牌过期 / 共享 key 被停用）时的提示，传输页会显示横幅
    @Published var authProblem: String? = nil

    // 日志
    @Published var log: [LogEntry] = []
    @Published var debugLogging: Bool = false

    // App 行为偏好（存 UserDefaults，可在设置里开关）
    @Published var autoDetectVolumes: Bool = QueueEngine.pref("cf.autoDetect", true) {
        didSet { UserDefaults.standard.set(autoDetectVolumes, forKey: "cf.autoDetect"); if !autoDetectVolumes { newlyMounted = nil } }
    }
    @Published var keepAwakeEnabled: Bool = QueueEngine.pref("cf.keepAwake", true) {
        didSet { UserDefaults.standard.set(keepAwakeEnabled, forKey: "cf.keepAwake"); updateKeepAwake() }
    }
    @Published var notificationsEnabled: Bool = QueueEngine.pref("cf.notify", true) {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "cf.notify") }
    }
    /// 储存卡备份到「卡名_日期」文件夹（防止不同卡里的同名照片 IMG_0001 互相覆盖）
    @Published var datedCardFolders: Bool = QueueEngine.pref("cf.datedCardFolders", true) {
        didSet { UserDefaults.standard.set(datedCardFolders, forKey: "cf.datedCardFolders") }
    }
    /// 上传完成后自动核对一遍（只比对文件清单和大小，很快）
    @Published var autoVerify: Bool = QueueEngine.pref("cf.autoVerify", true) {
        didSet { UserDefaults.standard.set(autoVerify, forKey: "cf.autoVerify") }
    }
    /// 网络等临时错误自动重试（2 分钟、10 分钟、30 分钟后各一次）
    @Published var autoRetryEnabled: Bool = QueueEngine.pref("cf.autoRetry", true) {
        didSet { UserDefaults.standard.set(autoRetryEnabled, forKey: "cf.autoRetry") }
    }
    private static func pref(_ key: String, _ def: Bool) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? def
    }

    private(set) var configPath: String? = nil
    var logFileURL: URL { AppPaths.supportDir.appendingPathComponent("rcd.log") }

    // 数据
    @Published var jobs: [TransferJob] = []
    @Published var history: [TransferJob] = []
    @Published var remotes: [Remote] = []
    @Published var quotas: [String: RemoteQuota] = [:]

    // 配置（应用于新任务）
    @Published var settings: TransferSettings = Preset.default.settings
    @Published var selectedPresetID: String = Preset.default.id
    @Published var globalPaused: Bool = false

    // 遥测（会话累计 + 速度历史，供 sparkline）
    @Published var speedHistory: [Double] = []
    @Published var sessionBytes: Int64 = 0
    @Published var peakSpeed: Double = 0
    /// 实时文件遥测（当前任务）：正在传的文件、刚传完的文件、本轮已运行秒数
    @Published var liveFiles: [LiveFile] = []
    @Published var recentDone: [DoneFile] = []
    @Published var liveElapsed: Double = 0
    private var pollCount = 0
    /// 每天上传到 Google Drive 的字节数（yyyy-MM-dd → bytes），用于显示「今日已用 / 750GB」
    @Published var dailyUploads: [String: Int64] = [:]
    private func recordSample(_ speed: Double) {
        speedHistory.append(speed)
        if speedHistory.count > 300 { speedHistory.removeFirst(speedHistory.count - 300) }
        if speed > peakSpeed { peakSpeed = speed }
    }

    // 默认目的地（新任务预填）
    @Published var defaultDestRemote: String? = nil
    @Published var defaultDestPath: String = "CloudFerry-Backup"

    // 触发 Google 每日上限后，队列暂停到此时间（账号级，避免多卡反复撞墙被封）
    @Published var dailyCapUntil: Date? = nil

    private var daemon: RcloneDaemon?
    var client: RCClient? { daemon?.client }
    private var runLoopTask: Task<Void, Never>?
    private var sleepAssertion: NSObjectProtocol?
    private var saveThrottle: Task<Void, Never>?
    private var historySaveThrottle: Task<Void, Never>?
    private var runStartedAt: [UUID: Date] = [:]
    private var restarting = false
    private var nextRestartAttempt: Date? = nil
    private var stateLoaded = false
    private var eventsHandle: FileHandle?

    var totalRAMBytes: Int64 { Int64(ProcessInfo.processInfo.physicalMemory) }

    // MARK: - 计算属性

    var activeJob: TransferJob? { jobs.first { $0.status == .running } }
    var queuedCount: Int { jobs.filter { $0.status == .queued }.count }
    var pendingBytes: Int64 { jobs.filter { !$0.status.isTerminal }.reduce(0) { $0 + max($1.totalBytes - $1.bytes, 0) } }
    var todayUploaded: Int64 { dailyUploads[Self.dayKey(Date())] ?? 0 }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static func dayKey(_ d: Date) -> String { dayFormatter.string(from: d) }

    // MARK: - 启动

    /// 读取上次保存的队列/设置（可被重复调用，只执行一次）
    func loadIfNeeded() {
        guard !stateLoaded else { return }
        stateLoaded = true
        load()
        loadHistory()
    }

    func bootstrap() async {
        openEventsLog()
        loadIfNeeded()
        addLog(.info, "CloudFerry \(AppInfo.version) " + L("启动，正在查找 rclone…", "starting, locating rclone…"))
        status = L("正在查找 rclone…", "Locating rclone…")
        guard let path = RcloneLocator.find() else {
            status = L("未找到 rclone", "rclone not found")
            lastError = RcloneError.notFound.localizedDescription
            addLog(.error, L("未找到 rclone 可执行文件", "rclone executable not found"))
            return
        }
        rclonePath = path
        addLog(.info, L("使用 rclone：", "Using rclone: ") + path)
        let cfg = RcloneLocator.configFilePath(rclonePath: path)
        configPath = cfg
        addLog(.info, L("配置文件：", "Config file: ") + cfg)
        let orphans = RcloneDaemon.killOrphans()
        if orphans > 0 {
            addLog(.warn, L("已清理 \(orphans) 个上次遗留的后台进程（防止和新任务重复上传）",
                            "Cleaned up \(orphans) leftover engine process(es) from a previous run (prevents duplicate uploads)"))
        }
        status = L("正在启动后台服务…", "Starting engine…")
        let d = RcloneDaemon(rclonePath: path, configPath: cfg)
        do {
            try await d.start()
            self.daemon = d
            self.ready = true
            self.status = L("就绪", "Ready")
            self.lastError = nil
            addLog(.success, L("后台服务已就绪", "Engine ready") + " (127.0.0.1:\(d.port))")
            if let v = try? await d.client?.call("core/version"), let ver = v["version"] as? String {
                rcloneVersion = ver.replacingOccurrences(of: "v", with: "")
            }
            setupNotifications()
            await refreshRemotes()
            if ProcessInfo.processInfo.environment["CLOUDFERRY_DEMO"] != nil {
                injectDemoData()   // 只用于界面截图：假数据，不启动传输循环
            } else {
                startRunLoop()
            }
            startVolumeWatch()
            if ProcessInfo.processInfo.environment["CLOUDFERRY_SELFTEST"] != nil {
                await runSelfTest()
            }
        } catch {
            self.status = L("启动失败", "Start failed")
            self.lastError = error.localizedDescription
            addLog(.error, L("后台服务启动失败：", "Engine failed to start: ") + error.localizedDescription)
        }
    }

    /// 用两个假的 drive 配置项（假令牌）测试：新凭据换进原网盘 / 测试不通过时自动还原 / 临时项被清理 / 有备份。
    private func runSwapSelfTest(err: (String) -> Void) async {
        guard let client else { err("SWAP_FAIL no client\n"); return }
        func tok(_ s: String) -> String { "{\"access_token\":\"\(s)\",\"token_type\":\"Bearer\",\"refresh_token\":\"\(s)R\",\"expiry\":\"2026-01-01T00:00:00Z\"}" }
        let name = "swaptest", temp = "swaptest" + Self.pendingSuffix
        // 原网盘：公用通道（无 client_id）
        runRcloneConfig(["config", "create", name, "drive", "scope=drive", "token=\(tok("OLD"))", "config_refresh_token=false", "--non-interactive"])
        // 临时项：模拟浏览器授权完成（由另一个进程写入，检验后台服务能读到）
        runRcloneConfig(["config", "create", temp, "drive", "scope=drive", "client_id=123456789-selftest.apps.googleusercontent.com",
                         "client_secret=GOCSPX-selftest-secret", "token=\(tok("NEW"))", "config_refresh_token=false", "--non-interactive"])
        await refreshRemotes()
        let hidden = !remotes.contains { $0.name == temp }
        // 1) 测试不通过 → 必须还原
        let r1 = await swapRemoteCredentials(from: temp, into: name, verify: { _ in (false, "fake fail") })
        let afterFail = (try? await client.call("config/get", ["name": name])) ?? [:]
        let restored = !r1 && (afterFail["token"] as? String) == tok("OLD") && ((afterFail["client_id"] as? String) ?? "").isEmpty
        // 2) 测试通过 → 换成新凭据，临时项删除
        runRcloneConfig(["config", "create", temp, "drive", "scope=drive", "client_id=123456789-selftest.apps.googleusercontent.com",
                         "client_secret=GOCSPX-selftest-secret", "token=\(tok("NEW"))", "config_refresh_token=false", "--non-interactive"])
        let r2 = await swapRemoteCredentials(from: temp, into: name, verify: { _ in (true, "fake ok") })
        let after = (try? await client.call("config/get", ["name": name])) ?? [:]
        let tempGone = ((try? await client.call("config/get", ["name": temp])) ?? [:])["type"] == nil
        await refreshRemotes()
        let own = remote(named: name)?.usesOwnClient == true
        let swapped = r2 && (after["token"] as? String) == tok("NEW") && (after["client_secret"] as? String) == "GOCSPX-selftest-secret"
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: AppPaths.supportDir.appendingPathComponent("rclone-config-backups").path))?.count ?? 0
        // 3) 正在传输时拒绝切换
        let fakeJob = TransferJob(sourceFs: "/tmp/x", sourceLabel: "__selftest_busy__", destFs: "\(name):x", destLabel: "x", direction: .upload, presetName: "test", settings: settings)
        jobs.append(fakeJob)
        if let i = jobs.firstIndex(where: { $0.id == fakeJob.id }) { jobs[i].status = .running }
        let blocked = activeJob(using: name) != nil
        jobs.removeAll { $0.id == fakeJob.id }
        runRcloneConfig(["config", "delete", name])
        let line = "restoredOnFail=\(restored) swapped=\(swapped) tempRemoved=\(tempGone) tempHidden=\(hidden) badge=\(own) backups=\(backups) busyBlocked=\(blocked)"
        err((restored && swapped && tempGone && hidden && own && backups > 0 && blocked ? "SWAP_OK " : "SWAP_FAIL ") + line + "\n")
    }

    /// 界面截图用的演示数据（CLOUDFERRY_DEMO=1）。不会写入磁盘，也不会启动任何传输。
    private func injectDemoData() {
        stateLoaded = false   // 阻止 save() 落盘
        let now = Date()
        func job(_ src: String, _ label: String, _ dst: String, _ st: JobStatus, total: Int64, done: Int64,
                 files: Int, filesDone: Int, speed: Double = 0, ago: Double = 0, vol: String? = nil, verified: Bool = false,
                 err: String? = nil, note: String? = nil) -> TransferJob {
            var j = TransferJob(sourceFs: src, sourceLabel: label, destFs: dst, destLabel: dst,
                                direction: .upload, presetName: "balanced", settings: settings)
            j.status = st; j.totalBytes = total; j.bytes = done; j.totalTransfers = files; j.transfersDone = filesDone
            j.speed = speed; j.etaSeconds = speed > 0 ? Int(Double(total - done) / speed) : nil
            j.volumeName = vol; j.verified = verified; j.error = err; j.verifyNote = note
            j.startedAt = now.addingTimeInterval(-ago - 3600); j.finishedAt = st.isFinal ? now.addingTimeInterval(-ago) : nil
            j.activeSeconds = st.isFinal ? 3400 : nil
            return j
        }
        let r = defaultDestRemote ?? "gdrive"
        jobs = [
            job("/Volumes/EOS_DIGITAL", "EOS_DIGITAL", "\(r):CloudFerry-Backup/EOS_DIGITAL_2026-11-22", .running,
                total: 238_400_000_000, done: 97_300_000_000, files: 4128, filesDone: 1702, speed: 104_000_000, vol: "EOS_DIGITAL"),
            job("/Volumes/A002", "A002", "\(r):CloudFerry-Backup/A002_2026-11-22", .queued, total: 0, done: 0, files: 0, filesDone: 0, vol: "A002"),
            job("/Users/demo/Movies/Interview_Final.mov", "Interview_Final.mov", "\(r):CloudFerry-Backup", .paused,
                total: 412_000_000_000, done: 61_000_000_000, files: 1, filesDone: 0),
            job("/Volumes/SD_CARD", "SD_CARD", "\(r):CloudFerry-Backup/SD_CARD_2026-11-21", .completed,
                total: 61_200_000_000, done: 61_200_000_000, files: 1312, filesDone: 1312, ago: 5400, vol: "SD_CARD", verified: true,
                note: "✓ 1312 " + L("个文件全部一致", "files match") + " · " + L("快速核对", "quick check")),
        ]
        var h: [TransferJob] = []
        let names = ["SD_CARD", "EOS_DIGITAL", "A001", "Untitled", "DJI_MINI", "EOS_DIGITAL", "A003"]
        for (i, n) in names.enumerated() {
            let t: Int64 = Int64(20 + i * 37) * 1_000_000_000
            let failed = i == 3
            let files = 300 + i * 211
            let dst = "\(r):CloudFerry-Backup/\(n)_2026-11-\(21 - i)"
            let ago: Double = Double(i) * 86_400 + 5400
            let e: String? = failed ? L("储存卡被拔出", "Card was unplugged") : nil
            h.append(job("/Volumes/\(n)", n, dst, failed ? .failed : .completed,
                         total: t, done: failed ? t / 3 : t, files: files, filesDone: failed ? 120 : files,
                         ago: ago, vol: n, verified: !failed, err: e))
        }
        history = h
        quotas[r] = RemoteQuota(total: 5_000_000_000_000, used: 2_140_000_000_000, free: 2_860_000_000_000, trashed: 0)
        var sp: [Double] = []
        for i in 0..<180 {
            let wave: Double = 25_000_000 * sin(Double(i) / 7)
            let jitter: Double = Double((i * 7919) % 13) * 1_000_000
            sp.append(85_000_000 + wave + jitter)
        }
        speedHistory = sp
        liveFiles = [
            LiveFile(name: "DCIM/100CANON/IMG_4821.CR3", size: 48_200_000, bytes: 31_100_000, percent: 64, speed: 21_400_000, speedAvg: 19_800_000, eta: 1),
            LiveFile(name: "DCIM/100CANON/IMG_4822.CR3", size: 47_900_000, bytes: 9_300_000, percent: 19, speed: 18_900_000, speedAvg: 18_100_000, eta: 2),
            LiveFile(name: "PRIVATE/M4ROOT/CLIP/C0042.MP4", size: 18_640_000_000, bytes: 7_210_000_000, percent: 38, speed: 38_600_000, speedAvg: 36_900_000, eta: 296),
            LiveFile(name: "PRIVATE/M4ROOT/CLIP/C0043.MP4", size: 9_120_000_000, bytes: 410_000_000, percent: 4, speed: 25_100_000, speedAvg: 24_000_000, eta: 347),
        ]
        var done: [DoneFile] = []
        for i in 0..<12 {
            let size: Int64 = Int64(45_000_000 + i * 1_300_000)
            let err: String = i == 7 ? "googleapi: Error 403: Rate Limit Exceeded" : ""
            let at: Date = now.addingTimeInterval(-Double(i) * 3.5)
            let secs: Double = 2.1 + Double(i % 3) * 0.4
            done.append(DoneFile(name: "DCIM/100CANON/IMG_48\(20 - i).CR3", size: size, error: err, completedAt: at, seconds: secs))
        }
        recentDone = done
        liveElapsed = 2_741
        sessionBytes = 97_300_000_000
        dailyUploads[Self.dayKey(now)] = 312_000_000_000
    }

    // MARK: - 日志

    private static let fileTimeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    /// 应用事件同时写入 events.log（超过 20MB 自动轮换，保留上一份）——事后能查“昨晚为什么失败”
    private func openEventsLog() {
        let fm = FileManager.default
        let url = AppPaths.eventsLog
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > 20_000_000 {
            let old = url.deletingLastPathComponent().appendingPathComponent("events.1.log")
            try? fm.removeItem(at: old); try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        eventsHandle = try? FileHandle(forWritingTo: url)
        eventsHandle?.seekToEndOfFile()
        eventsHandle?.write(Data("\n===== CloudFerry \(AppInfo.version) · \(Self.fileTimeFmt.string(from: Date())) =====\n".utf8))
    }

    func addLog(_ level: LogEntry.Level, _ message: String) {
        let now = Date()
        log.append(LogEntry(time: now, level: level, message: message))
        if log.count > 3000 { log.removeFirst(log.count - 3000) }
        if let h = eventsHandle {
            h.write(Data("\(Self.fileTimeFmt.string(from: now)) [\(level.rawValue.uppercased())] \(message)\n".utf8))
        }
    }
    func clearLog() { log.removeAll() }

    func setDebugLogging(_ on: Bool) {
        debugLogging = on
        Task { [weak self] in
            _ = try? await self?.daemon?.client?.call("options/set", ["main": ["LogLevel": on ? "DEBUG" : "INFO"]])
            self?.addLog(.info, L("rclone 日志级别切换为 ", "rclone log level set to ") + (on ? "DEBUG" : "INFO"))
        }
    }

    /// 语言切换后刷新动态状态串
    func relocalizeStatus() {
        if ready, lastError == nil { status = L("就绪", "Ready") }
    }

    // MARK: - 自检（只用临时假文件：本地→本地，绝不碰储存卡或网盘）

    private func runSelfTest() async {
        func err(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }
        func finishTest(_ code: Int32) -> Never { shutdown(); exit(code) }
        let fm = FileManager.default
        let base = AppPaths.supportDir.appendingPathComponent("selftest")
        let src = base.appendingPathComponent("card")
        let soloDir = base.appendingPathComponent("solo")
        let dst = base.appendingPathComponent("dst")
        try? fm.removeItem(at: base)
        try? fm.createDirectory(at: src.appendingPathComponent("DCIM"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: src.appendingPathComponent(".Spotlight-V100"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: soloDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        let chunk = Data(count: 100_000)
        for i in 0..<12 {
            fm.createFile(atPath: src.appendingPathComponent("DCIM/IMG_\(i).CR3").path, contents: chunk)
        }
        // 储存卡根目录常见的系统垃圾：必须被过滤，也不能让校验误报
        for junk in [".DS_Store", "._IMG_0.CR3", ".Spotlight-V100/store.db", "DCIM/.DS_Store"] {
            fm.createFile(atPath: src.appendingPathComponent(junk).path, contents: Data("junk".utf8))
        }
        fm.createFile(atPath: soloDir.appendingPathComponent("clip.mov").path, contents: Data(count: 300_000))

        let folderDst = dst.appendingPathComponent("card")
        addJob(sourceFs: src.path, sourceLabel: "__selftest__", destFs: folderDst.path, destLabel: "dst", direction: .local)
        let folderID = jobs.last?.id
        addJob(sourceFs: soloDir.appendingPathComponent("clip.mov").path, sourceLabel: "__selftest_file__",
               destFs: dst.appendingPathComponent("single").path, destLabel: "dst", direction: .local)
        let fileID = jobs.last?.id

        var done = false
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let st = [folderID, fileID].map { id in jobs.first(where: { $0.id == id })?.status }
            if st.contains(where: { $0 == .failed || $0 == .waitingRetry }) {
                let e = jobs.filter { $0.id == folderID || $0.id == fileID }.compactMap { $0.error }.joined(separator: " | ")
                err("SELFTEST_FAIL transfer error=\(e)\n"); finishTest(1)
            }
            if st.allSatisfy({ $0 == .completed }) { done = true; break }
        }
        guard done else { err("SELFTEST_TIMEOUT transfer\n"); finishTest(2) }

        let copied = (fm.enumerator(atPath: folderDst.path)?.allObjects as? [String] ?? []).filter {
            var d: ObjCBool = false
            return fm.fileExists(atPath: folderDst.appendingPathComponent($0).path, isDirectory: &d) && !d.boolValue
        }
        let junkLeaked = copied.filter { $0.contains(".DS_Store") || $0.contains(".Spotlight") || ($0 as NSString).lastPathComponent.hasPrefix("._") }
        let soloOK = fm.fileExists(atPath: dst.appendingPathComponent("single/clip.mov").path)
        guard copied.count == 12, junkLeaked.isEmpty, soloOK else {
            err("SELFTEST_FAIL files=\(copied.count) junk=\(junkLeaked) solo=\(soloOK)\n"); finishTest(1)
        }

        // 校验（完整哈希）：两个任务都必须通过（自动校验可能已在跑，等它结束）
        for id in [folderID, fileID].compactMap({ $0 }) {
            for _ in 0..<60 where verifyingJobs.contains(id) { try? await Task.sleep(nanoseconds: 250_000_000) }
            verify(id, full: true)
            for _ in 0..<120 where verifyingJobs.contains(id) { try? await Task.sleep(nanoseconds: 250_000_000) }
        }
        let verified = [folderID, fileID].map { id in jobs.first(where: { $0.id == id })?.verified ?? false }
        guard verified.allSatisfy({ $0 }) else {
            let notes = jobs.compactMap { $0.verifyNote }.joined(separator: " | ")
            err("SELFTEST_FAIL verify=\(verified) notes=\(notes)\n"); finishTest(1)
        }
        let hist = history.filter { $0.id == folderID || $0.id == fileID }.count
        let total = jobs.filter { $0.id == folderID || $0.id == fileID }.reduce(Int64(0)) { $0 + $1.bytes }
        err("SELFTEST_OK bytes=\(total) files=\(copied.count) junkFiltered=4 singleFile=ok verified=2 history=\(hist)\n")
        try? fm.removeItem(at: base)

        let env = ProcessInfo.processInfo.environment
        // 可选：「换成自己的通道」凭据替换测试——只在指向临时配置文件时运行（绝不碰用户真实的 rclone.conf），不联网
        if env["CLOUDFERRY_SELFTEST_SWAP"] != nil, let cfg = env["RCLONE_CONFIG"], cfg == configPath,
           !cfg.hasPrefix(NSHomeDirectory() + "/.config") {
            await runSwapSelfTest(err: err)
        }

        // 可选：浏览页后台测试（移动 / 重命名 / 在线读取 / 取到本机）——只对临时配置里的 alias 假网盘
        if let r = env["CLOUDFERRY_SELFTEST_BROWSE"], let cfg = env["RCLONE_CONFIG"], cfg == configPath,
           !cfg.hasPrefix(NSHomeDirectory() + "/.config"), remote(named: r)?.type == "alias" {
            await runBrowseSelfTest(remote: r, err: err)
        }

        // 可选：假储存卡（磁盘映像）+ 假网盘（本地 alias 远端）测试「卡名_日期」命名、增量复用、自动核对
        if let cards = env["CLOUDFERRY_SELFTEST_CARDS"], let remote = env["CLOUDFERRY_SELFTEST_REMOTE"] {
            let urls = cards.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
            let before = Set(jobs.map { $0.id })
            addUploadJobs(sources: urls, destRemote: remote, destPath: "CloudFerry-Backup")
            if let first = urls.first { addUploadJobs(sources: [first], destRemote: remote, destPath: "CloudFerry-Backup") }
            let cardJobs = jobs.filter { !before.contains($0.id) }.map { $0.id }
            for _ in 0..<160 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let js = jobs.filter { cardJobs.contains($0.id) }
                if js.allSatisfy({ $0.status == .completed || $0.status == .failed }) && verifyingJobs.isEmpty
                    && js.allSatisfy({ $0.verified || $0.status == .failed }) { break }
            }
            for j in jobs where cardJobs.contains(j.id) {
                err("CARD job=\(j.sourceLabel) dest=\(j.destFs) status=\(j.status.rawValue) files=\(j.transfersDone) verified=\(j.verified) note=\(j.verifyNote ?? "-") err=\(j.error ?? "-")\n")
            }
            for v in externalVolumes { err("CARD volume=\(v.name) uuid=\(v.uuid ?? "-") last=\(lastBackup(of: v)?.destFs ?? "none")\n") }
        }
        finishTest(0)
    }

    func shutdown() {
        runLoopTask?.cancel()
        if let a = sleepAssertion { ProcessInfo.processInfo.endActivity(a); sleepAssertion = nil }
        for j in jobs where j.status == .running { accumulateActiveTime(j.id) }
        daemon?.stop()
        save(immediate: true)
        saveHistory()
        NSApp?.dockTile.badgeLabel = nil
    }

    // MARK: - 网盘

    func refreshRemotes() async {
        guard let client else { return }
        do {
            let dump = try await client.call("config/dump")
            var list: [Remote] = []
            for (name, val) in dump {
                // 切换通道时的临时授权项（xxx__cfnew）不显示
                if name.hasSuffix(Self.pendingSuffix) { continue }
                if let d = val as? [String: Any], let type = d["type"] as? String {
                    list.append(Remote(name: name, type: type, clientID: d["client_id"] as? String))
                }
            }
            self.remotes = list.sorted { $0.name < $1.name }
            if defaultDestRemote == nil || !remotes.contains(where: { $0.name == defaultDestRemote }) {
                defaultDestRemote = remotes.first(where: { $0.isDrive })?.name ?? remotes.first?.name
            }
            addLog(.info, L("发现 \(list.count) 个网盘：", "Found \(list.count) remote(s): ") + list.map { $0.name }.joined(separator: ", "))
        } catch {
            self.lastError = L("读取网盘列表失败：", "Failed to read remotes: ") + error.localizedDescription
            addLog(.error, L("读取网盘列表失败：", "Failed to read remotes: ") + error.localizedDescription)
        }
    }

    func refreshQuota(for remote: Remote) async {
        guard let client else { return }
        if let about = try? await client.call("operations/about", ["fs": remote.fsPrefix], timeout: 60) {
            quotas[remote.name] = RemoteQuota(
                total: i64(about["total"]), used: i64(about["used"]),
                free: i64(about["free"]), trashed: i64(about["trashed"]))
        }
    }

    func remote(named name: String) -> Remote? { remotes.first { $0.name == name } }
    private func remoteName(of fs: String) -> String? {
        guard !fs.hasPrefix("/"), let c = fs.firstIndex(of: ":") else { return nil }
        // 去掉连接参数：gdrive,shared_with_me=true: → gdrive
        return String(fs[..<c].split(separator: ",", maxSplits: 1).first ?? "")
    }
    func isDriveFs(_ fs: String) -> Bool { remoteName(of: fs).flatMap { remote(named: $0) }?.isDrive ?? false }

    // MARK: - 添加任务

    /// 从拖入的 URL 创建上传任务（仅保存路径，不拷贝、不遍历，故不卡）
    func addUploadJobs(sources: [URL], destRemote: String, destPath: String) {
        let base = destPath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var added = 0
        var renamed: [String] = []
        for url in sources {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                addLog(.warn, L("跳过不存在的路径：", "Skipped missing path: ") + url.path)
                continue
            }
            let single = !isDir.boolValue
            let vol = SourceVolume.of(url)
            let onCard = (vol?.isExternal ?? false)
            var label = url.lastPathComponent
            var rel: String
            if datedCardFolders, onCard, let v = vol {
                // 储存卡：备份到「卡名_日期」文件夹，保留卡内目录结构（同一张卡同一天再次备份 = 增量，不重复传）
                let folder = cardFolderName(volume: v, remote: destRemote, base: base)
                let relInVol = Self.relativePath(of: url, under: v.rootURL)
                rel = Self.join(folder, single ? (relInVol as NSString).deletingLastPathComponent : relInVol)
                if relInVol.isEmpty { label = v.name }
                renamed.append(folder)
            } else {
                // 单个文件直接放进目标文件夹；文件夹则建同名子文件夹
                rel = single ? "" : url.lastPathComponent
            }
            let destDir = Self.join(base, rel)
            var job = TransferJob(
                sourceFs: url.path, sourceLabel: label,
                destFs: "\(destRemote):" + destDir, destLabel: "\(destRemote): \(destDir)",
                direction: .upload, presetName: selectedPresetName, settings: settings)
            job.isSingleFile = single
            if onCard { job.volumeName = vol?.name; job.volumeUUID = vol?.uuid }
            jobs.append(job)
            added += 1
        }
        if added > 0 {
            addLog(.info, L("已加入 \(added) 个上传任务到队列", "Queued \(added) upload task(s)"))
            if !renamed.isEmpty {
                addLog(.info, L("储存卡备份到：", "Card backup folder: ") + Array(Set(renamed)).sorted().joined(separator: ", ")
                       + L("（按卡名+日期命名，防止不同卡的同名照片互相覆盖）", " (named by card + date so same-named photos from different cards never overwrite each other)"))
            }
        }
        scheduleSave()
    }

    func addJob(sourceFs: String, sourceLabel: String, destFs: String, destLabel: String,
                direction: TransferDirection, isSingleFile: Bool? = nil) {
        var job = TransferJob(sourceFs: sourceFs, sourceLabel: sourceLabel,
                              destFs: destFs, destLabel: destLabel,
                              direction: direction, presetName: selectedPresetName, settings: settings)
        job.isSingleFile = isSingleFile
        jobs.append(job)
        addLog(.info, L("已加入任务：", "Queued: ") + "\(sourceLabel) → \(destFs)")
        scheduleSave()
    }

    /// 从历史记录再传一次（同样的来源和目的地；已传过的文件会被自动跳过）
    func rerun(_ old: TransferJob) {
        var j = TransferJob(sourceFs: old.sourceFs, sourceLabel: old.sourceLabel, destFs: old.destFs,
                            destLabel: old.destLabel, direction: old.direction,
                            presetName: selectedPresetName, settings: settings)
        j.isSingleFile = old.isSingleFile; j.volumeName = old.volumeName; j.volumeUUID = old.volumeUUID
        jobs.append(j)
        addLog(.info, L("已重新加入队列：", "Re-queued: ") + old.sourceLabel)
        scheduleSave()
    }

    var selectedPresetName: String { Preset.all.first { $0.id == selectedPresetID }?.name ?? L("自定义", "Custom") }

    // 储存卡文件夹命名
    private func cardFolderName(volume v: SourceVolume, remote: String, base: String) -> String {
        let stem = Self.sanitize(v.name) + "_" + Self.dayKey(Date())
        let all = jobs + history
        var n = 1
        while n < 100 {
            let candidate = n == 1 ? stem : "\(stem)_\(n)"
            let prefix = "\(remote):" + Self.join(base, candidate)
            let users = all.filter { $0.direction == .upload && ($0.destFs == prefix || $0.destFs.hasPrefix(prefix + "/")) }
            if users.isEmpty { return candidate }
            // 同一张卡（UUID 相同）→ 复用同一个文件夹（增量备份，已传的会自动跳过）
            if let uuid = v.uuid, users.allSatisfy({ $0.volumeUUID == uuid }) { return candidate }
            n += 1
        }
        return stem + "_" + UUID().uuidString.prefix(4)
    }
    static func sanitize(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Card" : t
    }
    static func join(_ parts: String...) -> String {
        parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }.filter { !$0.isEmpty }.joined(separator: "/")
    }
    static func relativePath(of url: URL, under root: URL) -> String {
        let p = url.standardizedFileURL.path, r = root.standardizedFileURL.path
        if p == r { return "" }
        let rr = r.hasSuffix("/") ? r : r + "/"
        return p.hasPrefix(rr) ? String(p.dropFirst(rr.count)) : url.lastPathComponent
    }
    /// "/a/b/c.mov" → ("/a/b", "c.mov")；"gdrive:x/y.mov" → ("gdrive:x", "y.mov")；"gdrive:y.mov" → ("gdrive:", "y.mov")
    static func splitParent(_ fs: String) -> (String, String) {
        if fs.hasPrefix("/") {
            let u = URL(fileURLWithPath: fs)
            return (u.deletingLastPathComponent().path, u.lastPathComponent)
        }
        guard let c = fs.firstIndex(of: ":") else { return (fs, "") }
        let head = String(fs[...c])
        let path = String(fs[fs.index(after: c)...])
        guard let slash = path.lastIndex(of: "/") else { return (head, path) }
        return (head + String(path[..<slash]), String(path[path.index(after: slash)...]))
    }

    /// 这张卡（按 UUID，没有则按卷名）最近一次成功上传的记录
    func lastBackup(of vol: VolumeInfo) -> TransferJob? {
        let all = (history + jobs).filter { $0.direction == .upload && $0.status == .completed }
        let matches = all.filter { j in
            if let u = vol.uuid, let ju = j.volumeUUID { return u == ju }
            return j.volumeName == vol.name && j.volumeUUID == nil
        }
        return matches.max { ($0.finishedAt ?? $0.createdAt) < ($1.finishedAt ?? $1.createdAt) }
    }

    // MARK: - 任务控制

    func pauseAll() {
        globalPaused = true
        if let job = activeJob { pause(job.id) }
    }
    func resumeAll() {
        globalPaused = false
        for i in jobs.indices where jobs[i].status == .paused { jobs[i].status = .queued }
        scheduleSave()
    }
    /// 单个任务暂停（正在传的大文件下次会从头传这一个文件；已传完的文件会跳过）
    func pause(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let s = jobs[i].status
        guard s == .running || s == .queued || s == .waitingRetry || s == .waitingDailyCap else { return }
        if s == .running { stopRcloneJob(jobs[i]); accumulateActiveTime(id) }
        jobs[i].status = .paused
        jobs[i].resumeAfter = nil
        addLog(.info, L("已暂停：", "Paused: ") + jobs[i].sourceLabel)
        updateKeepAwake(); scheduleSave()
    }
    func resume(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].status == .paused else { return }
        jobs[i].status = .queued
        if globalPaused && !jobs.contains(where: { $0.status == .paused }) { globalPaused = false }
        scheduleSave()
    }
    func retry(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].status = .queued; jobs[i].error = nil; jobs[i].resumeAfter = nil; jobs[i].autoRetries = nil
        scheduleSave()
    }
    func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[i].status == .running { stopRcloneJob(jobs[i]); accumulateActiveTime(id) }
        jobs[i].status = .canceled
        jobs[i].finishedAt = Date()
        recordHistory(jobs[i])
        updateKeepAwake(); scheduleSave()
    }
    func remove(_ id: UUID) {
        if let job = jobs.first(where: { $0.id == id }), job.status == .running { stopRcloneJob(job); accumulateActiveTime(id) }
        jobs.removeAll { $0.id == id }
        updateKeepAwake(); scheduleSave()
    }
    func clearFinished() {
        jobs.removeAll { $0.status.isTerminal }
        scheduleSave()
    }
    func moveToTop(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let job = jobs.remove(at: i)
        let firstPending = jobs.firstIndex { !$0.status.isFinal && $0.status != .running } ?? jobs.count
        jobs.insert(job, at: firstPending)
        scheduleSave()
    }
    func moveToBottom(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let job = jobs.remove(at: i)
        jobs.append(job)
        scheduleSave()
    }
    /// 上移 / 下移一位（只在未完成的任务之间调整顺序）
    func move(_ id: UUID, by delta: Int) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        var j = i + delta
        while j >= 0 && j < jobs.count && (jobs[j].status.isFinal || jobs[j].status == .running) { j += delta }
        guard j >= 0, j < jobs.count, j != i else { return }
        let job = jobs.remove(at: i)
        jobs.insert(job, at: j)
        scheduleSave()
    }
    /// 拖拽排序：把任务移动到另一个任务的位置
    func move(_ id: UUID, before target: UUID?) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let job = jobs.remove(at: i)
        if let target, let t = jobs.firstIndex(where: { $0.id == target }) { jobs.insert(job, at: t) }
        else { jobs.append(job) }
        scheduleSave()
    }

    private func stopRcloneJob(_ job: TransferJob) {
        guard let client, let jid = job.jobid else { return }
        Task { try? await client.call("job/stop", ["jobid": jid]) }
    }

    private func accumulateActiveTime(_ id: UUID) {
        guard let start = runStartedAt.removeValue(forKey: id),
              let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].activeSeconds = (jobs[i].activeSeconds ?? 0) + Date().timeIntervalSince(start)
    }

    // MARK: - 运行循环

    private func startRunLoop() {
        runLoopTask?.cancel()
        runLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func tick() async {
        guard ready else { return }
        // 后台服务意外退出 → 自动重启并把正在传的任务放回队列（整夜挂机不会卡死）
        if let d = daemon, !d.isRunning, !restarting {
            if let t = nextRestartAttempt, Date() < t { return }
            await restartEngine()
            return
        }
        checkTimedResumes()
        if globalPaused { return }
        if activeJob != nil {
            await pollActiveJob()
            return
        }
        // 每日上限期间不启动新任务（账号级闸门）
        if let cap = dailyCapUntil, Date() < cap { return }
        if let next = jobs.first(where: { $0.status == .queued }) {
            await startJob(next.id)
        }
    }

    private func restartEngine() async {
        guard let rclonePath, let configPath else { return }
        restarting = true
        defer { restarting = false }
        addLog(.error, L("后台服务意外退出，正在自动重启…", "Engine exited unexpectedly; restarting…"))
        for i in jobs.indices where jobs[i].status == .running {
            accumulateActiveTime(jobs[i].id)
            jobs[i].status = .queued; jobs[i].jobid = nil
        }
        daemon?.stop()
        let d = RcloneDaemon(rclonePath: rclonePath, configPath: configPath)
        do {
            try await d.start()
            daemon = d
            nextRestartAttempt = nil
            status = L("就绪", "Ready"); lastError = nil
            addLog(.success, L("后台服务已重启，队列继续", "Engine restarted; queue continues"))
        } catch {
            nextRestartAttempt = Date().addingTimeInterval(30)
            status = L("重启失败，30 秒后再试", "Restart failed; retrying in 30s")
            lastError = error.localizedDescription
            addLog(.error, L("后台服务重启失败：", "Engine restart failed: ") + error.localizedDescription)
        }
        updateKeepAwake()
    }

    private func startJob(_ id: UUID) async {
        guard let i = jobs.firstIndex(where: { $0.id == id }), let client else { return }
        var job = jobs[i]

        // 本地来源是否还在（储存卡可能已拔出）
        if job.sourceIsLocal {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: job.sourceFs, isDirectory: &isDir) else {
                job.status = .failed
                job.finishedAt = Date()
                job.error = L("找不到来源：", "Source not found: ") + job.sourceFs
                    + L("（储存卡/硬盘可能已拔出。插回后点「重试」）", " (card/drive may be unplugged — reconnect it and click Retry)")
                commit(job); recordHistory(job)
                addLog(.error, "✗ " + (job.error ?? ""))
                notify(L("找不到来源", "Source not found"), job.sourceLabel)
                scheduleSave()
                return
            }
            job.isSingleFile = !isDir.boolValue
        } else if job.isSingleFile == nil {
            job.isSingleFile = await remoteIsFile(job.sourceFs)
        }

        // 每次开始前清零该任务的统计组，避免暂停/重试后进度累加错乱
        _ = try? await client.call("core/stats-reset", ["group": job.group])
        job.bytes = 0; job.totalBytes = 0; job.speed = 0; job.etaSeconds = nil
        job.transfersDone = 0; job.totalTransfers = 0; job.checks = 0; job.errorsCount = 0
        job.transferringNames = []
        liveFiles = []; recentDone = []; liveElapsed = 0

        let endpoint: String
        var body: [String: Any] = ["_async": true, "_group": job.group, "_config": buildConfig(job.settings)]
        if job.isSingleFile == true {
            // 单个文件：用 copyfile 放进目标文件夹（sync/copy 不接受文件作为来源）
            let (srcParent, name) = Self.splitParent(job.sourceFs)
            endpoint = "operations/copyfile"
            body["srcFs"] = fsWithBackendParams(srcParent, settings: job.settings)
            body["srcRemote"] = name
            body["dstFs"] = fsWithBackendParams(job.destFs, settings: job.settings)
            body["dstRemote"] = name
        } else {
            endpoint = "sync/copy"
            body["srcFs"] = fsWithBackendParams(job.sourceFs, settings: job.settings)
            body["dstFs"] = fsWithBackendParams(job.destFs, settings: job.settings)
            body["createEmptySrcDirs"] = true
            if let f = buildFilter(job.settings) { body["_filter"] = f }
        }
        do {
            let resp = try await client.call(endpoint, body)
            if let n = resp["jobid"] as? NSNumber { job.jobid = n.intValue }
            job.status = .running
            job.error = nil
            if job.startedAt == nil { job.startedAt = Date() }
            runStartedAt[job.id] = Date()
            commit(job)
            updateKeepAwake()
            addLog(.info, "▶ " + L("开始传输：", "Started: ") + "\(job.sourceLabel) → \(job.destFs)")
        } catch {
            commit(job)
            var j = job
            finish(&j, success: false, error: error.localizedDescription)
            commit(j)
        }
    }

    /// 远端路径是不是单个文件（operations/stat；不确定时返回 nil 按文件夹处理）
    private func remoteIsFile(_ fs: String) async -> Bool? {
        guard let client, let c = fs.firstIndex(of: ":") else { return nil }
        let path = String(fs[fs.index(after: c)...])
        if path.isEmpty { return false }
        guard let r = try? await client.call("operations/stat", ["fs": String(fs[...c]), "remote": path], timeout: 60) else { return nil }
        if let item = r["item"] as? [String: Any] { return !(item["IsDir"] as? Bool ?? true) }
        return nil
    }

    private func pollActiveJob() async {
        guard let i = jobs.firstIndex(where: { $0.status == .running }), let client else { return }
        var job = jobs[i]
        if let stats = try? await client.call("core/stats", ["group": job.group]) {
            let newBytes = i64(stats["bytes"])
            if job.direction != .download, newBytes > job.bytes, isDriveFs(job.destFs) {
                addDaily(newBytes - job.bytes)
            }
            job.bytes = newBytes
            job.totalBytes = i64(stats["totalBytes"])
            job.speed = dbl(stats["speed"])
            if let e = stats["eta"] as? NSNumber { job.etaSeconds = e.intValue } else { job.etaSeconds = nil }
            job.transfersDone = Int(i64(stats["transfers"]))
            job.totalTransfers = Int(i64(stats["totalTransfers"]))
            job.checks = Int(i64(stats["checks"]))
            job.errorsCount = Int(i64(stats["errors"]))
            if let arr = stats["transferring"] as? [[String: Any]] {
                job.transferringNames = Array(arr.compactMap { $0["name"] as? String }.prefix(6))
                liveFiles = arr.map { f in
                    LiveFile(name: f["name"] as? String ?? "", size: i64(f["size"]), bytes: i64(f["bytes"]),
                             percent: Int(i64(f["percentage"])), speed: dbl(f["speed"]), speedAvg: dbl(f["speedAvg"]),
                             eta: (f["eta"] as? NSNumber)?.intValue)
                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            } else {
                liveFiles = []
            }
            liveElapsed = dbl(stats["elapsedTime"])
            recordSample(job.speed)
        }
        // 每 3 秒取一次「刚传完的文件」（rclone 只保留最近约 100 条）
        pollCount += 1
        if pollCount % 3 == 1, let t = try? await client.call("core/transferred", ["group": job.group]),
           let arr = t["transferred"] as? [[String: Any]] {
            recentDone = arr.filter { !($0["checked"] as? Bool ?? false) }.suffix(50).reversed().map { f in
                let start = Format.parseModTime(f["started_at"] as? String)
                let end = Format.parseModTime(f["completed_at"] as? String)
                let secs: Double? = (start != nil && end != nil) ? max(0, end!.timeIntervalSince(start!)) : nil
                return DoneFile(name: f["name"] as? String ?? "", size: i64(f["size"]),
                                error: f["error"] as? String ?? "", completedAt: end, seconds: secs)
            }
        }
        // 状态可能在等待网络请求期间被用户改了（暂停/取消），以最新状态为准
        guard let cur = jobs.first(where: { $0.id == job.id }), cur.status == .running else { return }
        if let jid = job.jobid {
            do {
                let st = try await client.call("job/status", ["jobid": jid])
                if st["finished"] as? Bool ?? false {
                    let ok = st["success"] as? Bool ?? false
                    let err = (st["error"] as? String) ?? ""
                    accumulateActiveTime(job.id)
                    job.activeSeconds = jobs.first(where: { $0.id == job.id })?.activeSeconds
                    finish(&job, success: ok, error: err)
                }
            } catch {
                // 后台服务重启过、找不到这个任务 → 放回队列重新开始（已传完的文件会跳过）
                if error.localizedDescription.lowercased().contains("job not found") {
                    accumulateActiveTime(job.id)
                    job.activeSeconds = jobs.first(where: { $0.id == job.id })?.activeSeconds
                    job.status = .queued; job.jobid = nil
                    addLog(.warn, L("任务在后台丢失，已放回队列：", "Task lost by the engine; re-queued: ") + job.sourceLabel)
                }
            }
        } else {
            job.status = .queued
        }
        commit(job)
    }

    private func finish(_ job: inout TransferJob, success: Bool, error: String) {
        job.finishedAt = Date()
        liveFiles = []
        if success {
            job.status = .completed
            job.error = nil
            job.autoRetries = nil
            sessionBytes += job.doneBytes
            var extra = "\(Format.bytes(job.doneBytes)) · \(job.transfersDone) " + L("个文件", "files")
            if let s = job.averageSpeed { extra += " · " + L("平均 ", "avg ") + Format.speed(s) }
            addLog(.success, "✔ " + job.direction.doneVerb + L("：", ": ") + "\(job.sourceLabel) (\(extra))")
            notify(job.direction.doneVerb + " · " + job.sourceLabel, extra)
            recordHistory(job)
            if autoVerify && job.direction == .upload {
                let id = job.id
                DispatchQueue.main.async { [weak self] in self?.verify(id, full: false, automatic: true) }
            }
        } else {
            let cls = classifyError(error)
            job.error = error
            switch cls {
            case .dailyCap:
                job.status = .waitingDailyCap
                let resume = Date().addingTimeInterval(24 * 3600)
                job.resumeAfter = resume
                dailyCapUntil = resume    // 账号级闸门：暂停整个队列到次日
                job.error = L("已达 Google 每日上传上限（约 750GB/天）或本任务设定的传输上限", "Hit Google's daily upload limit (~750GB/day) or this task's max-transfer limit") + "\n" + error
                addLog(.warn, L("已达每日上限，队列暂停，约 24 小时后自动续传", "Daily limit hit; queue paused, auto-resumes in ~24h"))
                notify(L("已达每日上传上限", "Daily upload limit reached"), "\(job.sourceLabel): " + L("队列将在约 24 小时后自动续传", "queue auto-resumes in ~24h"))
            case .storageFull:
                job.status = .failed
                job.error = L("网盘空间已满：", "Cloud storage full: ") + error
                addLog(.error, L("网盘空间已满：", "Cloud storage full: ") + job.sourceLabel)
                notify(L("网盘空间已满", "Cloud storage full"), job.sourceLabel)
                recordHistory(job)
            case .auth:
                job.status = .failed
                job.error = L("网盘授权失效（令牌过期，或 rclone 共享 key 被 Google 停用）。请到「我的网盘」重新连接；若反复失败，请改用自己的 client_id。\n",
                              "Cloud authorization failed (token expired, or rclone's shared key was retired by Google). Reconnect under Remotes; if it keeps failing, use your own client_id.\n") + error
                authProblem = L("Google Drive 授权失效，需要重新连接", "Google Drive authorization failed — reconnect needed")
                addLog(.error, L("授权失效：", "Authorization failed: ") + error)
                notify(L("网盘授权失效", "Cloud authorization failed"), L("请在 CloudFerry 里重新连接网盘", "Reconnect the remote in CloudFerry"))
                recordHistory(job)
            case .sourceMissing:
                job.status = .failed
                job.error = L("找不到来源（储存卡/硬盘可能已拔出，或网盘里的文件夹已被删除）。插回后点「重试」。\n",
                              "Source not found (card/drive unplugged, or the cloud folder was deleted). Reconnect and click Retry.\n") + error
                addLog(.error, "✗ " + L("找不到来源：", "Source not found: ") + job.sourceLabel)
                notify(L("找不到来源", "Source not found"), job.sourceLabel)
                recordHistory(job)
            case .other:
                let n = job.autoRetries ?? 0
                if autoRetryEnabled && n < Self.retryDelays.count {
                    let delay = Self.retryDelays[n]
                    job.autoRetries = n + 1
                    job.status = .waitingRetry
                    job.resumeAfter = Date().addingTimeInterval(delay)
                    addLog(.warn, L("传输出错，将在 \(Int(delay / 60)) 分钟后自动重试（第 \(n + 1)/\(Self.retryDelays.count) 次）：",
                                    "Transfer error; auto-retry in \(Int(delay / 60)) min (\(n + 1)/\(Self.retryDelays.count)): ") + "\(job.sourceLabel): \(error)")
                } else {
                    job.status = .failed
                    addLog(.error, "✗ " + L("失败：", "Failed: ") + "\(job.sourceLabel): \(error)")
                    notify(L("传输失败", "Transfer failed"), "\(job.sourceLabel): \(error)")
                    recordHistory(job)
                }
            }
        }
        updateKeepAwake()
        scheduleSave()
    }

    static let retryDelays: [TimeInterval] = [120, 600, 1800]

    enum ErrorClass { case dailyCap, storageFull, auth, sourceMissing, other }
    private func classifyError(_ e: String) -> ErrorClass {
        let s = e.lowercased()
        if s.contains("storagequotaexceeded") || s.contains("storage quota") || s.contains("no space left")
            || (s.contains("space") && s.contains("full")) { return .storageFull }
        // 每日上传上限：rclone 用 --drive-stop-on-upload-limit 时报 "User rate limit exceeded."（小写+句号）；
        // 以及本任务的 --max-transfer 上限。注意：普通的 "Rate Limit Exceeded" 只是临时限速，不能当成每日上限停 24 小时。
        if e.contains("User rate limit exceeded.") || s.contains("max transfer limit reached")
            || s.contains("upload limit") || s.contains("dailylimitexceeded")
            || (s.contains("quotaexceeded") && !s.contains("ratelimit")) { return .dailyCap }
        if s.contains("invalid_grant") || s.contains("invalid_client") || s.contains("unauthorized_client")
            || s.contains("deleted_client") || s.contains("couldn't fetch token") || s.contains("token expired")
            || s.contains("access_denied") || s.contains("couldn't find root directory id") { return .auth }
        if s.contains("directory not found") || s.contains("no such file or directory")
            || s.contains("object not found") || s.contains("is a file not a directory") { return .sourceMissing }
        return .other
    }

    private func checkTimedResumes() {
        let now = Date()
        if let cap = dailyCapUntil, now >= cap { dailyCapUntil = nil }
        var changed = false
        for i in jobs.indices where jobs[i].status == .waitingDailyCap || jobs[i].status == .waitingRetry {
            if let t = jobs[i].resumeAfter, now >= t {
                jobs[i].status = .queued; jobs[i].resumeAfter = nil; changed = true
            }
        }
        if changed { scheduleSave() }
    }

    /// 手动立即续传（不等 24 小时 / 不等自动重试）
    func resumeDailyCapNow(_ id: UUID) { dailyCapUntil = nil; retry(id) }

    private func addDaily(_ b: Int64) {
        let k = Self.dayKey(Date())
        dailyUploads[k, default: 0] += b
        if dailyUploads.count > 30 {
            for key in dailyUploads.keys.sorted().dropLast(30) { dailyUploads.removeValue(forKey: key) }
        }
    }

    // MARK: - 历史记录（持久化，清除队列也不会丢）

    private func loadHistory() {
        guard let data = try? Data(contentsOf: AppPaths.historyFile) else { return }
        let dec = JSONDecoder()
        if let h = try? dec.decode([TransferJob].self, from: data) { history = h }
    }
    private func recordHistory(_ job: TransferJob) {
        if job.sourceLabel.hasPrefix("__selftest") && ProcessInfo.processInfo.environment["CLOUDFERRY_SELFTEST"] == nil { return }
        if let i = history.firstIndex(where: { $0.id == job.id }) { history[i] = job }
        else { history.insert(job, at: 0) }
        if history.count > 5000 { history.removeLast(history.count - 5000) }
        scheduleHistorySave()
    }
    func removeHistory(_ ids: Set<UUID>) { history.removeAll { ids.contains($0.id) }; scheduleHistorySave() }
    func clearHistory() { history.removeAll(); scheduleHistorySave() }
    private func scheduleHistorySave() {
        historySaveThrottle?.cancel()
        historySaveThrottle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self?.saveHistory()
        }
    }
    func saveHistory() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(history) { try? data.write(to: AppPaths.historyFile, options: .atomic) }
    }

    // MARK: - 外接设备识别

    @Published var externalVolumes: [VolumeInfo] = []
    @Published var newlyMounted: VolumeInfo? = nil

    private func startVolumeWatch() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scanVolumes()
                guard self.autoDetectVolumes else { return }
                if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
                   let vol = self.externalVolumes.first(where: { $0.url == url }) {
                    self.newlyMounted = vol
                    self.addLog(.info, L("检测到外接设备：", "Detected drive: ") + vol.name)
                    var text = vol.name + L("，可在 CloudFerry 一键备份", " — back it up in CloudFerry")
                    if let last = self.lastBackup(of: vol) {
                        text = vol.name + L("（\(Format.relative(last.finishedAt))备份过）", " (backed up \(Format.relative(last.finishedAt)))")
                    }
                    self.notify(L("检测到外接设备", "External drive detected"), text)
                }
            }
        }
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scanVolumes()
                if let n = self.newlyMounted, !self.externalVolumes.contains(n) { self.newlyMounted = nil }
            }
        }
        scanVolumes()
    }

    /// 只读取卷的元数据（名称、容量、UUID），不读取卡里的文件
    func scanVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
                                      .volumeIsInternalKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeUUIDStringKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        var result: [VolumeInfo] = []
        for u in urls {
            guard u.path != "/", let rv = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            let removable = (rv.volumeIsRemovable ?? false) || (rv.volumeIsEjectable ?? false)
            let isExternal = removable || !(rv.volumeIsInternal ?? true)
            guard isExternal else { continue }
            result.append(VolumeInfo(url: u, name: rv.volumeName ?? u.lastPathComponent,
                                     isRemovable: removable,
                                     total: Int64(rv.volumeTotalCapacity ?? 0),
                                     free: Int64(rv.volumeAvailableCapacity ?? 0),
                                     uuid: rv.volumeUUIDString))
        }
        externalVolumes = result.sorted { $0.name < $1.name }
    }

    func dismissNewlyMounted() { newlyMounted = nil }

    /// 备份一个外接卷（整盘）到默认网盘
    func backupVolume(_ vol: VolumeInfo) {
        guard let remote = defaultDestRemote, !remote.isEmpty else { return }
        addUploadJobs(sources: [vol.url], destRemote: remote, destPath: defaultDestPath)
        if newlyMounted == vol { newlyMounted = nil }
    }

    func backupAllExternal() {
        guard let remote = defaultDestRemote, !remote.isEmpty else { return }
        let urls = externalVolumes.map { $0.url }
        guard !urls.isEmpty else { return }
        addUploadJobs(sources: urls, destRemote: remote, destPath: defaultDestPath)
        newlyMounted = nil
    }

    // MARK: - 保持唤醒 / 通知 / 开机启动

    private func updateKeepAwake() {
        let active = keepAwakeEnabled && jobs.contains { $0.status == .running }
        if active, sleepAssertion == nil {
            // 原生电源断言：传输期间阻止系统/显示器空闲睡眠（比 caffeinate 更干净）
            sleepAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                reason: "CloudFerry is transferring files")
        } else if !active, let a = sleepAssertion {
            ProcessInfo.processInfo.endActivity(a)
            sleepAssertion = nil
        }
    }

    private var useSystemNotifications = false
    private func setupNotifications() {
        // 只有作为正式 .app 运行时才能用系统通知中心（点通知可回到 App）；否则退回 osascript
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil,
              ProcessInfo.processInfo.environment["CLOUDFERRY_SELFTEST"] == nil else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = NotificationRouter.shared
        c.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.useSystemNotifications = granted }
        }
    }

    func notify(_ title: String, _ text: String) {
        guard notificationsEnabled, ProcessInfo.processInfo.environment["CLOUDFERRY_SELFTEST"] == nil else { return }
        if useSystemNotifications {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = text
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(text))\" with title \"\(esc(title))\""]
        try? p.run()
    }
    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    /// 开机自动启动（重启后队列会自动续传）。返回错误说明，成功返回 nil
    func setLaunchAtLogin(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            addLog(.info, on ? L("已开启开机自动启动", "Launch at login enabled") : L("已关闭开机自动启动", "Launch at login disabled"))
            objectWillChange.send()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - 构造 rclone 参数

    func buildConfig(_ s: TransferSettings) -> [String: Any] {
        var c: [String: Any] = [:]
        c["Transfers"] = s.transfers
        c["Checkers"] = s.checkers
        c["MaxBacklog"] = s.maxBacklog
        if !s.orderBy.isEmpty { c["OrderBy"] = s.orderBy }
        c["TPSLimit"] = s.tpsLimit
        c["TPSLimitBurst"] = s.tpsLimitBurst
        if !s.bwLimit.isEmpty { c["BwLimit"] = s.bwLimit }
        if !s.maxTransfer.isEmpty {
            c["MaxTransfer"] = s.maxTransfer
            c["CutoffMode"] = s.cutoffMode.rawValue
        }
        c["Retries"] = s.retries
        c["RetriesInterval"] = 15_000_000_000   // 两次整体重试间隔 15 秒（网络短暂断开能扛过去），单位纳秒
        c["LowLevelRetries"] = s.lowLevelRetries
        c["CheckFirst"] = s.checkFirst
        if s.checksum { c["CheckSum"] = true }
        if s.ignoreExisting { c["IgnoreExisting"] = true }
        if s.updateOlder { c["UpdateOlder"] = true }
        if s.immutable { c["Immutable"] = true }
        if s.trackRenames { c["TrackRenames"] = true }
        if s.sizeOnly { c["SizeOnly"] = true }
        c["BufferSize"] = "\(s.bufferSizeMiB)Mi"
        if s.multiThreadStreams != 4 { c["MultiThreadStreams"] = s.multiThreadStreams }
        return c
    }

    /// 系统垃圾文件规则。注意：不能写成 "**/.DS_Store"——那样匹配不到储存卡根目录的垃圾文件（已实测）
    static let junkRules = [".DS_Store", "._*", ".Spotlight-V100/**", ".Trashes/**", ".fseventsd/**",
                            ".TemporaryItems/**", ".DocumentRevisions-V100/**", ".apdisk",
                            "Thumbs.db", "desktop.ini", "$RECYCLE.BIN/**", "System Volume Information/**"]

    func excludeRules(_ s: TransferSettings) -> [String] {
        var excludes: [String] = []
        if s.excludeSystemJunk { excludes += Self.junkRules }
        excludes += s.customExcludes.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return excludes
    }

    func buildFilter(_ s: TransferSettings) -> [String: Any]? {
        let excludes = excludeRules(s)
        var f: [String: Any] = [:]
        if !excludes.isEmpty { f["ExcludeRule"] = excludes }
        if !s.minAge.isEmpty { f["MinAge"] = s.minAge }
        return f.isEmpty ? nil : f
    }

    /// 若 Fs 是 Google Drive 远端，则用连接字符串注入后端参数（chunk_size 等）
    func fsWithBackendParams(_ base: String, settings s: TransferSettings) -> String {
        guard let colon = base.firstIndex(of: ":"), !base.hasPrefix("/") else { return base }  // 本地路径
        let name = String(base[..<colon])
        guard let remote = remotes.first(where: { $0.name == name }), remote.isDrive else { return base }
        var params: [String] = []
        params.append("chunk_size=\(s.driveChunkSizeMiB)Mi")
        params.append("upload_cutoff=\(s.driveUploadCutoffMiB)Mi")
        params.append("pacer_min_sleep=\(s.pacerMinSleepMs)ms")
        params.append("pacer_burst=\(s.pacerBurst)")
        if s.stopOnUploadLimit { params.append("stop_on_upload_limit=true") }
        if s.serverSideAcrossConfigs { params.append("server_side_across_configs=true") }
        let rest = String(base[base.index(after: colon)...])
        return "\(name),\(params.joined(separator: ",")):\(rest)"
    }

    /// 生成“等效 rclone 命令”预览（透明 + 教学）
    func previewCommand(_ s: TransferSettings, src: String = L("<来源>", "<source>"), dst: String = L("<网盘目的地>", "<cloud destination>")) -> String {
        var args = ["rclone", "copy", "\"\(src)\"", "\"\(dst)\""]
        args += ["--transfers", "\(s.transfers)", "--checkers", "\(s.checkers)"]
        args += ["--drive-chunk-size", "\(s.driveChunkSizeMiB)Mi"]
        if s.driveUploadCutoffMiB != 8 { args += ["--drive-upload-cutoff", "\(s.driveUploadCutoffMiB)Mi"] }
        args += ["--tpslimit", trimNum(s.tpsLimit)]
        if s.tpsLimitBurst != 20 { args += ["--tpslimit-burst", "\(s.tpsLimitBurst)"] }
        if !s.bwLimit.isEmpty { args += ["--bwlimit", "\"\(s.bwLimit)\""] }
        if !s.maxTransfer.isEmpty { args += ["--max-transfer", s.maxTransfer, "--cutoff-mode", s.cutoffMode.rawValue.lowercased()] }
        if s.stopOnUploadLimit { args += ["--drive-stop-on-upload-limit"] }
        if s.checkFirst { args += ["--check-first"] }
        if s.checksum { args += ["--checksum"] }
        if s.ignoreExisting { args += ["--ignore-existing"] }
        if s.trackRenames { args += ["--track-renames"] }
        if s.immutable { args += ["--immutable"] }
        if !s.orderBy.isEmpty { args += ["--order-by", "\"\(s.orderBy)\""] }
        args += ["--retries", "\(s.retries)", "--retries-sleep", "15s", "--low-level-retries", "\(s.lowLevelRetries)"]
        args += ["--buffer-size", "\(s.bufferSizeMiB)Mi"]
        if s.excludeSystemJunk { args += ["--exclude", "\".DS_Store\"", "--exclude", "\"._*\"", "--exclude", "\".Spotlight-V100/**\"", "…"] }
        if !s.minAge.isEmpty { args += ["--min-age", s.minAge] }
        args += ["-P"]
        return args.joined(separator: " ")
    }
    private func trimNum(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(d)
    }

    // MARK: - 持久化

    private func commit(_ job: TransferJob) {
        guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[i] = job
    }

    func applyPreset(_ preset: Preset) {
        settings = preset.settings
        selectedPresetID = preset.id
        scheduleSave()
    }

    // MARK: - 测速

    func runSpeedTest(_ tester: SpeedTester, remoteName: String, includeDownload: Bool) async {
        guard let client else {
            tester.error = L("引擎未就绪，无法测速", "Engine not ready"); tester.phase = .failed; return
        }
        let base = settings
        let isDrive = remote(named: remoteName)?.isDrive ?? false
        await tester.run(client: client, remoteName: remoteName, isDrive: isDrive,
                         baseSettings: base, baseConfig: buildConfig(base), ramBytes: totalRAMBytes,
                         includeDownload: includeDownload,
                         fsFor: { [weak self] fs in self?.fsWithBackendParams(fs, settings: base) ?? fs })
    }

    func applyRecommended(_ s: TransferSettings) {
        settings = s
        scheduleSave()
        addLog(.success, L("已应用测速推荐参数", "Applied recommended settings"))
    }

    // MARK: - App 内连接网盘（无需终端）

    @Published var connecting = false
    @Published var connectLog = ""
    /// 连接/切换通道的进度说明（给界面显示）
    @Published var connectPhase = ""
    /// 最近一次连接失败的原因（给界面显示）
    var lastConnectFailure: String? = nil
    /// 最近一次连接成功后的测试结果（容量等）
    var lastConnectDetail: String? = nil
    private var connectProcess: Process?
    static let pendingSuffix = "__cfnew"

    /// 某个网盘是否正被正在运行的任务使用
    func activeJob(using remoteName: String) -> TransferJob? {
        jobs.first { j in
            j.status == .running && [j.sourceFs, j.destFs].contains { self.remoteName(of: $0) == remoteName }
        }
    }

    /// 在 App 内驱动 rclone 完成 Google Drive OAuth：浏览器会自动弹出让用户授权。
    /// 安全做法：若同名网盘已存在，先授权到一个临时名字（xxx__cfnew），测试通过后才把新凭据换进原网盘；
    /// 授权失败 / 取消 / 测试不通过 → 原来的连接一点不动。原网盘名字不变，所以队列、历史、默认目的地都不受影响。
    func connectDrive(name: String, clientID: String, clientSecret: String, useOwnClientID: Bool,
                      completion: @escaping (Bool) -> Void) {
        guard let rclonePath, let configPath else { completion(false); return }
        guard !connecting else { return }
        lastConnectFailure = nil
        lastConnectDetail = nil
        let exists = remotes.contains(where: { $0.name == name })
        if exists, let busy = activeJob(using: name) {
            lastConnectFailure = L("「\(name)」正在传输（\(busy.sourceLabel)）。请等它传完，或先暂停，再切换。",
                                   "“\(name)” is transferring (\(busy.sourceLabel)). Wait for it to finish or pause it, then switch.")
            addLog(.warn, lastConnectFailure!)
            completion(false); return
        }
        let target = exists ? name + Self.pendingSuffix : name
        connecting = true
        connectLog = ""
        connectPhase = L("浏览器已打开，请在浏览器里登录 Google 并点「允许」…", "Browser opened — sign in to Google and click Allow…")

        // 清掉上次没完成的临时项（只删本地配置，不动云端数据）
        if exists { runRcloneConfig(["config", "delete", target]) }

        addLog(.info, L("开始连接 Google Drive（", "Connecting Google Drive (") + (useOwnClientID ? L("你自己的通道", "your own client") : L("rclone 公用通道", "rclone shared client")) + L("），浏览器将自动打开进行授权…", "); a browser will open for authorization…"))
        var args = ["config", "create", target, "drive", "scope=drive", "--config", configPath]
        if useOwnClientID {
            args.append("client_id=\(clientID)")
            args.append("client_secret=\(clientSecret)")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: rclonePath)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self.connectLog += s
                for line in s.split(separator: "\n") {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    // 不把密钥/令牌写进日志
                    if t.isEmpty || t.contains("client_secret") || t.contains("access_token") || t.contains("GOCSPX-") { continue }
                    self.addLog(.info, "rclone: " + t)
                }
            }
        }
        p.terminationHandler = { proc in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                self.connectProcess = nil
                let exitedOK = proc.terminationStatus == 0
                Task { @MainActor in
                    var ok = false
                    var created = false
                    if exitedOK, let cfg = try? await self.client?.call("config/get", ["name": target]), cfg["token"] != nil {
                        created = true
                    }
                    if created {
                        if exists {
                            self.connectPhase = L("授权完成，正在测试新通道…", "Authorized — testing the new connection…")
                            ok = await self.swapRemoteCredentials(from: target, into: name)
                        } else {
                            ok = true
                            self.lastConnectDetail = await self.testRemote(target).1
                        }
                    } else {
                        if exists { self.runRcloneConfig(["config", "delete", target]) }
                        if self.lastConnectFailure == nil {
                            self.lastConnectFailure = L("浏览器里的授权没有完成（被取消、关掉了页面，或 Google 拒绝了）。",
                                                        "Authorization in the browser didn't complete (canceled, page closed, or Google refused).")
                        }
                    }
                    await self.refreshRemotes()
                    self.connecting = false
                    self.connectPhase = ""
                    if ok {
                        self.defaultDestRemote = name
                        self.authProblem = nil
                        self.scheduleSave()
                        self.addLog(.success, L("已连接网盘：", "Connected: ") + name + (useOwnClientID ? L("（你自己的通道）", " (your own client)") : ""))
                    } else {
                        self.addLog(.error, L("连接未完成：", "Connection did not complete: ") + (self.lastConnectFailure ?? "")
                                    + (exists ? L(" 原来的连接没有改动。", " The existing connection was left unchanged.") : ""))
                    }
                    completion(ok)
                }
            }
        }
        do { try p.run(); connectProcess = p }
        catch {
            connecting = false
            connectPhase = ""
            lastConnectFailure = L("无法启动 rclone：", "Failed to launch rclone: ") + error.localizedDescription
            addLog(.error, lastConnectFailure!)
            completion(false)
        }
    }

    func cancelConnect() {
        lastConnectFailure = L("已取消。", "Canceled.")
        connectProcess?.terminate()
        connectProcess = nil
        addLog(.warn, L("已取消连接", "Connection canceled"))
    }

    /// 同步运行一个 rclone config 子命令（只改本地配置文件）
    @discardableResult
    private func runRcloneConfig(_ args: [String]) -> Bool {
        guard let rclonePath, let configPath else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: rclonePath)
        p.arguments = args + ["--config", configPath]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }

    /// 修改前先备份 rclone 配置文件（只留最近 10 份，权限 600）
    @discardableResult
    func backupRcloneConfig() -> URL? {
        guard let configPath else { return nil }
        let fm = FileManager.default
        let dir = AppPaths.supportDir.appendingPathComponent("rclone-config-backups", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let dst = dir.appendingPathComponent("rclone-\(f.string(from: Date())).conf")
        try? fm.removeItem(at: dst)
        guard (try? fm.copyItem(at: URL(fileURLWithPath: configPath), to: dst)) != nil else { return nil }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
        let all = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("rclone-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(10) { try? fm.removeItem(at: old) }
        return dst
    }

    /// 把临时网盘（刚授权好的）的 client_id / secret / 令牌换进正式网盘。
    /// 正式网盘的名字和其他设置（共享盘、根目录等）都不变。换完要测试通过；不通过就自动还原成原来的凭据。
    /// `verify` 只在自检里替换（自检不连真实网盘）。
    func swapRemoteCredentials(from temp: String, into name: String,
                               verify: ((String) async -> (Bool, String))? = nil) async -> Bool {
        guard let client else { return false }
        guard let newCfg = try? await client.call("config/get", ["name": temp]),
              let oldCfg = try? await client.call("config/get", ["name": name]),
              newCfg["token"] != nil else {
            lastConnectFailure = L("读不到刚授权好的配置。", "Couldn't read the newly authorized config.")
            return false
        }
        backupRcloneConfig()
        let keys = ["client_id", "client_secret", "token"]
        func params(_ cfg: [String: Any]) -> [String: Any] {
            var p: [String: Any] = ["config_refresh_token": "false"]
            for k in keys { p[k] = (cfg[k] as? String) ?? "" }
            return p
        }
        func apply(_ cfg: [String: Any]) async -> Bool {
            _ = try? await client.call("fscache/clear")
            _ = try? await client.call("config/update", ["name": name, "parameters": params(cfg),
                                                          "opt": ["nonInteractive": true, "noObscure": true]])
            _ = try? await client.call("fscache/clear")
            guard let now = try? await client.call("config/get", ["name": name]) else { return false }
            return keys.allSatisfy { ((now[$0] as? String) ?? "") == ((cfg[$0] as? String) ?? "") }
        }
        guard await apply(newCfg) else {
            _ = await apply(oldCfg)
            lastConnectFailure = L("写入新凭据失败，已还原。", "Failed to write the new credentials; restored.")
            return false
        }
        let (ok, msg): (Bool, String)
        if let verify { (ok, msg) = await verify(name) } else { (ok, msg) = await testRemote(name) }
        if !ok {
            _ = await apply(oldCfg)
            _ = try? await client.call("config/delete", ["name": temp])
            lastConnectFailure = L("新通道测试没通过，已还原成原来的连接。", "The new connection failed its test; restored the previous one.") + "\n" + msg
            return false
        }
        _ = try? await client.call("config/delete", ["name": temp])
        addLog(.success, L("已切换「\(name)」的登录凭据 · ", "Switched credentials for “\(name)” · ") + msg)
        lastConnectDetail = msg
        return true
    }

    // MARK: - 浏览网盘（文件管理器）

    /// 列目录；失败返回 nil（区分“空文件夹”和“读取失败”）
    func listPath(remote: String, path: String) async -> [RemoteEntry]? {
        guard let client else { return nil }
        let resp: [String: Any]
        do {
            resp = try await client.call("operations/list",
                ["fs": "\(remote):", "remote": path, "opt": [:]], timeout: 180)
        } catch {
            lastListError = error.localizedDescription
            return nil
        }
        guard let arr = resp["list"] as? [[String: Any]] else { return [] }
        let entries = arr.map { e in
            RemoteEntry(name: e["Name"] as? String ?? "",
                        path: e["Path"] as? String ?? "",
                        size: (e["Size"] as? NSNumber)?.int64Value ?? 0,
                        isDir: e["IsDir"] as? Bool ?? false,
                        modTime: Format.parseModTime(e["ModTime"] as? String),
                        fileID: e["ID"] as? String,
                        mimeType: e["MimeType"] as? String)
        }
        return entries.sorted {
            if $0.isDir != $1.isDir { return $0.isDir && !$1.isDir }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var lastListError: String? = nil

    /// 递归计算某个网盘路径的总大小（用于"计算大小/简介"）
    func sizePath(remote: String, path: String) async -> (bytes: Int64, count: Int)? {
        guard let client else { return nil }
        let fs = path.isEmpty ? "\(remote):" : "\(remote):\(path)"
        guard let resp = try? await client.call("operations/size", ["fs": fs], timeout: 1800) else { return nil }
        let bytes = (resp["bytes"] as? NSNumber)?.int64Value ?? 0
        let count = (resp["count"] as? NSNumber)?.intValue ?? 0
        return (bytes, count)
    }

    /// Google Drive 网页链接（只读取文件 ID，不会创建分享链接）
    func driveWebURL(remote: String, path: String, isDir: Bool) async -> URL? {
        let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if clean.isEmpty { return URL(string: "https://drive.google.com/drive/my-drive") }
        guard let client,
              let r = try? await client.call("operations/stat", ["fs": "\(remote):", "remote": clean], timeout: 60),
              let item = r["item"] as? [String: Any], let id = item["ID"] as? String, !id.isEmpty else { return nil }
        let dir = item["IsDir"] as? Bool ?? isDir
        return URL(string: dir ? "https://drive.google.com/drive/folders/\(id)" : "https://drive.google.com/file/d/\(id)/view")
    }

    /// 打开一个任务的网盘目的地（Google Drive 网页）
    func openInDriveWeb(fs: String) {
        guard let name = remoteName(of: fs), remote(named: name)?.isDrive == true,
              let c = fs.firstIndex(of: ":") else { return }
        let path = String(fs[fs.index(after: c)...])
        Task { [weak self] in
            if let url = await self?.driveWebURL(remote: name, path: path, isDir: true) {
                NSWorkspace.shared.open(url)
            } else {
                self?.addLog(.warn, L("在网盘里找不到这个位置（可能还没开始传或已被删除）：", "Couldn't find this location in the cloud (not started yet, or deleted): ") + fs)
            }
        }
    }

    /// 测试某个网盘连接是否可用（返回是否成功 + 说明）
    func testRemote(_ name: String) async -> (Bool, String) {
        guard let client else { return (false, L("引擎未就绪", "Engine not ready")) }
        do {
            let about = try await client.call("operations/about", ["fs": "\(name):"], timeout: 60)
            authProblem = nil
            let total = (about["total"] as? NSNumber)?.int64Value
            let used = (about["used"] as? NSNumber)?.int64Value
            if let total, let used {
                return (true, L("连接正常 · 已用 ", "OK · used ") + Format.bytes(used) + L(" / 共 ", " / ") + Format.bytes(total))
            }
            return (true, L("连接正常", "OK"))
        } catch {
            // 有些后端不支持 about，退回列根目录
            if (try? await client.call("operations/list", ["fs": "\(name):", "remote": "", "opt": ["recurse": false]], timeout: 60)) != nil {
                authProblem = nil
                return (true, L("连接正常（该网盘不支持容量查询）", "OK (this remote doesn't report quota)"))
            }
            return (false, L("连接失败：令牌可能过期，或 rclone 共享 key 已被 Google 停用。请重新连接；反复失败就改用自己的 client_id。\n", "Failed: token may be expired, or rclone's shared key was retired. Reconnect; if it keeps failing, use your own client_id.\n") + error.localizedDescription)
        }
    }

    func makeFolder(remote: String, path: String) async -> Bool {
        guard let client else { return false }
        let ok = (try? await client.call("operations/mkdir", ["fs": "\(remote):", "remote": path])) != nil
        if ok { addLog(.info, L("已新建文件夹：", "Created folder: ") + "\(remote):\(path)") }
        return ok
    }

    @discardableResult
    func deleteEntry(remote: String, entry: RemoteEntry) async -> Bool {
        guard let client else { return false }
        let endpoint = entry.isDir ? "operations/purge" : "operations/deletefile"
        do {
            _ = try await client.call(endpoint, ["fs": "\(remote):", "remote": entry.path], timeout: 600)
            addLog(.warn, L("已删除：", "Deleted: ") + "\(remote):\(entry.path)")
            return true
        } catch {
            addLog(.error, L("删除失败：", "Delete failed: ") + "\(remote):\(entry.path) — \(error.localizedDescription)")
            return false
        }
    }

    /// 删除一个网盘配置（只删本地配置项，不删除云端任何数据）
    func deleteRemote(_ name: String) {
        guard let rclonePath, let configPath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: rclonePath)
        p.arguments = ["config", "delete", name, "--config", configPath]
        try? p.run(); p.waitUntilExit()
        if defaultDestRemote == name { defaultDestRemote = nil }
        addLog(.info, L("已删除网盘配置：", "Removed remote: ") + name)
        Task { await refreshRemotes() }
    }

    // MARK: - 校验（rclone check，只读）

    @Published var verifyingJobs: Set<UUID> = []

    /// full = 逐个哈希比对（会把来源完整读一遍，较慢）；否则只核对文件清单和大小（很快）。
    /// 注：rclone 上传时本来就会对每个文件做 MD5 校验，所以「快速核对」主要确认没有漏传。
    func verify(_ id: UUID, full: Bool = true, automatic: Bool = false) {
        guard let job = jobs.first(where: { $0.id == id }) ?? history.first(where: { $0.id == id }),
              let rclonePath, let configPath else { return }
        guard !verifyingJobs.contains(id) else { return }
        verifyingJobs.insert(id)
        let mode = full ? L("完整哈希比对", "full hash compare") : L("快速核对文件清单和大小", "quick file-list & size check")
        addLog(.info, (automatic ? L("自动校验：", "Auto-verify: ") : L("开始校验：", "Verifying: ")) + job.sourceLabel + "（\(mode)）")
        var args = ["check", job.sourceFs, job.destFs, "--one-way", "--config", configPath, "--checkers", "16"]
        if !full { args.append("--size-only") }
        if job.isSingleFile != true { for r in excludeRules(job.settings) { args += ["--exclude", r] } }
        let label = job.sourceLabel
        let isUpload = job.direction == .upload
        Task.detached { [weak self] in
            let (ok, out): (Bool, String) = {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: rclonePath)
                p.arguments = args
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                do {
                    try p.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
                } catch { return (false, error.localizedDescription) }
            }()
            let summary = QueueEngine.summarizeCheck(out)
            await MainActor.run {
                guard let self else { return }
                self.verifyingJobs.remove(id)
                let note = (ok ? "✓ " : "✗ ") + summary + " · " + (full ? L("完整哈希", "full hash") : L("快速核对", "quick check"))
                if let i = self.jobs.firstIndex(where: { $0.id == id }) {
                    if ok { self.jobs[i].verified = true }
                    self.jobs[i].verifyNote = note
                    self.recordHistory(self.jobs[i])
                } else if let h = self.history.firstIndex(where: { $0.id == id }) {
                    if ok { self.history[h].verified = true }
                    self.history[h].verifyNote = note
                    self.scheduleHistorySave()
                }
                self.scheduleSave()
                if ok {
                    let tail = isUpload ? L(" 与网盘一致，可放心格式化储存卡", " matches the cloud — safe to format the card") : L(" 校验一致", " matches")
                    self.addLog(.success, L("校验通过：", "Verified: ") + label + tail + "（\(summary)）")
                    if !automatic { self.notify(L("校验通过", "Verified"), label + L(" 校验一致", " matches")) }
                } else {
                    self.addLog(.error, L("校验发现差异：", "Verify found differences: ") + "\(label) — \(summary)")
                    self.notify(L("校验发现差异", "Verify found differences"), label + " — " + summary)
                }
            }
        }
    }

    /// 从 rclone check 输出里提取“N 个一致 / N 个缺失 / N 处差异”
    nonisolated static func summarizeCheck(_ out: String) -> String {
        var parts: [String] = []
        for raw in out.split(separator: "\n") {
            let line = String(raw)
            if let r = line.range(of: #"(\d+) matching files"#, options: .regularExpression) {
                let n = line[r].split(separator: " ").first.map(String.init) ?? "?"
                parts.append(L("\(n) 个文件一致", "\(n) files match"))
            } else if let r = line.range(of: #"(\d+) files missing"#, options: .regularExpression) {
                let n = line[r].split(separator: " ").first.map(String.init) ?? "?"
                parts.append(L("\(n) 个文件缺失", "\(n) missing"))
            } else if let r = line.range(of: #"(\d+) differences found"#, options: .regularExpression) {
                let n = line[r].split(separator: " ").first.map(String.init) ?? "?"
                if n != "0" { parts.append(L("\(n) 处差异", "\(n) differences")) }
            } else if let r = line.range(of: #"(\d+) hashes could not be checked"#, options: .regularExpression) {
                let n = line[r].split(separator: " ").first.map(String.init) ?? "?"
                parts.append(L("\(n) 个无法比对哈希", "\(n) hashes not checked"))
            }
        }
        if parts.isEmpty {
            let tail = out.split(separator: "\n").suffix(2).joined(separator: " ")
            return tail.isEmpty ? L("无输出", "no output") : String(tail.prefix(200))
        }
        return parts.joined(separator: "，")
    }

    func scheduleSave() {
        saveThrottle?.cancel()
        saveThrottle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self?.save()
        }
    }

    func save(immediate: Bool = false) {
        guard stateLoaded else { return }   // 还没读到旧数据前绝不覆盖
        // 重启后可续传：不持久化易变的瞬时统计的“运行中”状态本身
        let persistJobs = jobs.map { j -> TransferJob in
            var c = j
            if c.status == .running { c.status = .queued; c.jobid = nil }
            return c
        }
        let st = PersistState(settings: settings, jobs: persistJobs, selectedPresetID: selectedPresetID,
                              defaultDestRemote: defaultDestRemote, defaultDestPath: defaultDestPath,
                              dailyCapUntil: dailyCapUntil, dailyUploads: dailyUploads)
        if let data = try? JSONEncoder().encode(st) {
            try? data.write(to: AppPaths.stateFile, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.stateFile) else { return }
        guard let st = try? JSONDecoder().decode(PersistState.self, from: data) else {
            // 读不懂就备份一份，避免被新数据覆盖后彻底丢失
            let bak = AppPaths.supportDir.appendingPathComponent("state.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? data.write(to: bak)
            addLog(.warn, L("上次的队列文件无法读取，已备份为 ", "Previous queue file was unreadable; backed up as ") + bak.lastPathComponent)
            return
        }
        settings = st.settings
        selectedPresetID = st.selectedPresetID
        defaultDestRemote = st.defaultDestRemote
        defaultDestPath = st.defaultDestPath
        dailyCapUntil = st.dailyCapUntil
        dailyUploads = st.dailyUploads ?? [:]
        // 恢复：把“运行中”重置为排队以便自动续传；用户手动暂停的保持暂停
        jobs = st.jobs.map { j in
            var c = j
            if c.status == .running { c.status = .queued; c.jobid = nil }
            return c
        }
    }

    // MARK: - 数字解析

    private func i64(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }
    private func dbl(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
}

/// 点击系统通知 → 打开主窗口；App 在前台时也显示横幅
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .cfShowMainWindow, object: nil)
        }
        completionHandler()
    }
}

extension Notification.Name {
    static let cfShowMainWindow = Notification.Name("cfShowMainWindow")
}
