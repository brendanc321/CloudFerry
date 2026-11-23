import Foundation

enum RcloneError: LocalizedError {
    case notFound
    case daemonFailed(String)
    case server(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notFound: return L("找不到 rclone 可执行文件。请安装 rclone（brew install rclone）或在设置中指定路径。",
                                  "rclone executable not found. Install rclone (brew install rclone) or bundle it.")
        case .daemonFailed(let m): return L("rclone 后台服务启动失败：", "rclone engine failed to start: ") + m
        case .server(let m): return m
        case .badResponse: return L("rclone 返回了无法解析的数据。", "rclone returned unparseable data.")
        }
    }
}

// MARK: - Locate the rclone binary

enum RcloneLocator {
    static let commonPaths = [
        "/opt/homebrew/bin/rclone",
        "/usr/local/bin/rclone",
        "/usr/bin/rclone",
        "/opt/local/bin/rclone",
    ]

    /// 查找顺序：App 内置 -> 常见安装位置 -> 登录 shell 的 which
    static func find(bundledOverride: String? = nil) -> String? {
        if let o = bundledOverride, FileManager.default.isExecutableFile(atPath: o) { return o }
        // App 内置（分发时把 rclone 放进 Resources）
        if let res = Bundle.main.resourceURL?.appendingPathComponent("rclone").path,
           FileManager.default.isExecutableFile(atPath: res) { return res }
        for p in commonPaths where FileManager.default.isExecutableFile(atPath: p) { return p }
        // 登录 shell（拿到用户 PATH，包括 Homebrew）
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v rclone"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do {
            try p.run(); p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) {
                return s
            }
        } catch { }
        return nil
    }

    /// 用户 rclone 配置文件路径（这样能看到用户已登录的网盘，如 Google Drive）
    static func configFilePath(rclonePath: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: rclonePath)
        p.arguments = ["config", "file"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do {
            try p.run(); p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            for line in out.split(separator: "\n").reversed() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("/") { return t }
            }
        } catch { }
        return NSString(string: "~/.config/rclone/rclone.conf").expandingTildeInPath
    }
}

// MARK: - rc HTTP client

final class RCClient {
    let baseURL: URL
    let authHeader: String
    private let session: URLSession

    init(port: Int, user: String, pass: String) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let token = Data("\(user):\(pass)".utf8).base64EncodedString()
        self.authHeader = "Basic \(token)"
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    @discardableResult
    func call(_ endpoint: String, _ body: [String: Any] = [:], timeout: TimeInterval? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: baseURL.appendingPathComponent(endpoint))
        if let timeout { req.timeoutInterval = timeout }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, resp) = try await session.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let msg = obj?["error"] as? String ?? "HTTP \(http.statusCode)"
            throw RcloneError.server(msg)
        }
        guard let obj else { throw RcloneError.badResponse }
        return obj
    }

    /// 快速健康检查
    func ping() async -> Bool {
        (try? await call("core/version")) != nil
    }
}

// MARK: - rcd daemon lifecycle

final class RcloneDaemon {
    let rclonePath: String
    let configPath: String
    private(set) var port: Int = 0
    let user = "cloudferry"
    let pass = UUID().uuidString
    private var process: Process?
    private(set) var client: RCClient?
    let logURL: URL

    init(rclonePath: String, configPath: String) {
        self.rclonePath = rclonePath
        self.configPath = configPath
        let dir = AppPaths.supportDir
        self.logURL = dir.appendingPathComponent("rcd.log")
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func start() async throws {
        if isRunning, let c = client, await c.ping() { return }
        var lastErr = "未知错误"
        for _ in 0..<5 {
            let candidate = Int.random(in: 49200...59900)
            do {
                try launch(on: candidate)
                let c = RCClient(port: candidate, user: user, pass: pass)
                // 等待就绪（最多 ~10 秒）
                for _ in 0..<50 {
                    if await c.ping() {
                        self.port = candidate
                        self.client = c
                        return
                    }
                    if !(process?.isRunning ?? false) { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                lastErr = readLogTail()
                stop()
            } catch {
                lastErr = error.localizedDescription
            }
        }
        throw RcloneError.daemonFailed(lastErr)
    }

    /// 每次启动前轮换日志：保留上一次运行的完整日志（rcd.1.log），而不是直接清空
    private var rotatedThisRun = false
    private func rotateLogIfNeeded() {
        guard !rotatedThisRun else { return }
        rotatedThisRun = true
        let fm = FileManager.default
        let prev = logURL.deletingLastPathComponent().appendingPathComponent("rcd.1.log")
        if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? NSNumber, size.intValue > 0 {
            try? fm.removeItem(at: prev)
            try? fm.moveItem(at: logURL, to: prev)
        }
    }

    /// 清理上次崩溃/强退后遗留的 CloudFerry 后台进程（否则它可能还在传，和新任务重复上传）
    static func killOrphans() -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let me = ProcessInfo.processInfo.processIdentifier
        var killed = 0
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            let cmd = parts[2]
            // 只认我们自己启动的 rcd：带 --rc-user cloudferry，且父进程已不存在（被 launchd 收养）
            guard cmd.contains(" rcd "), cmd.contains("--rc-user cloudferry"), ppid == 1, pid != me else { continue }
            kill(pid, SIGTERM)
            killed += 1
        }
        return killed
    }

    private func launch(on port: Int) throws {
        try? FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
        rotateLogIfNeeded()
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        logHandle.seekToEndOfFile()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: rclonePath)
        p.arguments = [
            "rcd",
            "--rc-addr", "127.0.0.1:\(port)",
            "--rc-user", user,
            "--rc-pass", pass,
            "--rc-serve",           // 允许 App 通过本机地址边下边播网盘里的视频/图片（只监听 127.0.0.1，需要密码）
            "--config", configPath,
            "--transfers", "8",     // 默认值，具体任务用 _config 覆盖
            "--log-level", "INFO",  // 详细日志（可在「运行日志」里切换 DEBUG）
        ]
        p.standardOutput = logHandle
        p.standardError = logHandle
        try p.run()
        self.process = p
    }

    private func readLogTail() -> String {
        guard let data = try? Data(contentsOf: logURL),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return String(s.suffix(500))
    }

    func stop() {
        if let c = client {
            Task { try? await c.call("core/quit") }
        }
        process?.terminate()
        process = nil
        client = nil
    }
}

// MARK: - App paths

enum AppPaths {
    static var supportDir: URL {
        // CLOUDFERRY_DATA_DIR：自检/测试用的独立数据目录，绝不碰用户真实的队列和设置
        if let o = ProcessInfo.processInfo.environment["CLOUDFERRY_DATA_DIR"], !o.isEmpty {
            let d = URL(fileURLWithPath: o, isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("CloudFerry", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var stateFile: URL { supportDir.appendingPathComponent("state.json") }
    static var historyFile: URL { supportDir.appendingPathComponent("history.json") }
    static var eventsLog: URL { supportDir.appendingPathComponent("events.log") }
    static var speedtestScratch: URL {
        let d = supportDir.appendingPathComponent("speedtest", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}
