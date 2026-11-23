import Foundation
import Combine

// MARK: - Speed test

@MainActor
final class SpeedTester: ObservableObject {
    enum Phase: Equatable { case idle, prepare, uploadMulti, uploadSingle, download, cleanup, done, failed }

    @Published var phase: Phase = .idle
    @Published var phaseText: String = L("未开始", "Not started")
    @Published var result: SpeedTestResult? = nil
    @Published var recommendations: [Recommendation] = []
    @Published var recommendedSettings: TransferSettings? = nil
    @Published var error: String? = nil
    @Published var running: Bool = false

    private let scratch = AppPaths.speedtestScratch

    var isRemoteTarget: Bool = true

    /// 上传约 1.5GB 测试数据（按时长封顶，不必全传完），测速后彻底删除（不进回收站）。
    /// 修复（v1.1）：
    ///  - 旧版下载测速依赖“多线程上传”阶段至少传完一个文件；14 秒内一个都没传完时，下载阶段报
    ///    “directory not found”，整个测速失败。现在先确认云端有可下载的完整文件，没有就先放一个小种子文件。
    ///  - 旧版测速用 rclone 默认的 8MiB 分片，而真实传输用你设置里的分片（如 64MiB），结果偏低；现在用同一套参数。
    ///  - 清理时不进 Google Drive 回收站，不占你的网盘空间。
    func run(client: RCClient, remoteName: String, isDrive: Bool, baseSettings: TransferSettings,
             baseConfig: [String: Any], ramBytes: Int64, includeDownload: Bool,
             fsFor: @escaping (String) -> String) async {
        guard !running else { return }
        running = true
        error = nil
        phase = .prepare
        phaseText = L("生成测试数据…", "Generating test data…")
        let token = UUID().uuidString.prefix(8).lowercased()
        let localMulti = scratch.appendingPathComponent("multi-\(token)")
        let localSingle = scratch.appendingPathComponent("single-\(token)")
        let localSeed = scratch.appendingPathComponent("seed-\(token)")
        let localDown = scratch.appendingPathComponent("down-\(token)")
        let rel = "__cloudferry_speedtest__/\(token)"
        let remoteBase = "\(remoteName):\(rel)"
        let transfers = max(baseSettings.transfers, 8)

        func cleanupLocal() {
            for u in [localMulti, localSingle, localSeed, localDown] { try? FileManager.default.removeItem(at: u) }
        }
        func cleanupRemote() async {
            // 严格限定只删除本 App 自己的测速临时目录；Google Drive 直接彻底删除，不进回收站
            let purgeFs = isDrive ? "\(remoteName),use_trash=false:" : "\(remoteName):"
            if (try? await client.call("operations/stat", ["fs": "\(remoteName):", "remote": rel], timeout: 60))?["item"] is [String: Any] {
                _ = try? await client.call("operations/purge", ["fs": purgeFs, "remote": rel], timeout: 300)
            }
            _ = try? await client.call("operations/rmdir", ["fs": purgeFs, "remote": "__cloudferry_speedtest__"], timeout: 60)
        }

        defer { running = false }
        do {
            // 在后台线程生成测试数据，避免卡界面
            try await Self.generate(dir: localMulti, count: 24, mbEach: 64)   // ~1.5GB，24 个 64MB 文件供并发
            try await Self.generate(dir: localSingle, count: 1, mbEach: 512)  // 单文件，测单连接吞吐

            phase = .uploadMulti
            phaseText = L("多线程上传测速中…", "Testing multi-stream upload…")
            let upAgg = try await measureCopy(client: client, src: localMulti.path,
                                              dst: fsFor("\(remoteBase)/multi"), group: "cf-sp-um-\(token)",
                                              config: baseConfig, transfers: transfers, capSeconds: 14).rate

            phase = .uploadSingle
            phaseText = L("单线程上传测速中…", "Testing single-stream upload…")
            let upStream = try await measureCopy(client: client, src: localSingle.path,
                                                 dst: fsFor("\(remoteBase)/single"), group: "cf-sp-us-\(token)",
                                                 config: baseConfig, transfers: 1, capSeconds: 10).rate

            var down: Double? = nil
            if includeDownload {
                phase = .download
                phaseText = L("下载测速中…", "Testing download…")
                // 云端必须有完整文件可下载；上传阶段若一个都没传完（慢速网络），先放一个 32MB 种子文件
                let have = (try? await client.call("operations/size", ["fs": "\(remoteBase)"], timeout: 60))
                    .flatMap { ($0["bytes"] as? NSNumber)?.int64Value } ?? 0
                if have < 16_000_000 {
                    phaseText = L("下载测速：准备云端测试文件…", "Download test: preparing a cloud test file…")
                    try await Self.generate(dir: localSeed, count: 1, mbEach: 32)
                    _ = try await client.call("operations/copyfile", [
                        "srcFs": localSeed.path, "srcRemote": "t0.bin",
                        "dstFs": fsFor("\(remoteBase)/seed"), "dstRemote": "t0.bin",
                    ], timeout: 600)
                    phaseText = L("下载测速中…", "Testing download…")
                }
                // 多轮下载，直到累计约 8 秒（文件少时一轮太快，测不准）
                var totalBytes = 0.0, totalTime = 0.0, round = 0
                while totalTime < 8 && round < 5 {
                    let dst = localDown.appendingPathComponent("r\(round)")
                    let m = try await measureCopy(client: client, src: fsFor(remoteBase), dst: dst.path,
                                                  group: "cf-sp-dn-\(token)-\(round)", config: baseConfig,
                                                  transfers: transfers, capSeconds: 14 - totalTime)
                    totalBytes += Double(m.bytes); totalTime += m.seconds; round += 1
                    try? FileManager.default.removeItem(at: dst)
                    if m.bytes == 0 { break }
                }
                down = totalTime > 0 ? totalBytes / totalTime / 1_000_000 : 0
            }

            phase = .cleanup
            phaseText = L("清理测试数据…", "Cleaning up test data…")
            await cleanupRemote()
            cleanupLocal()

            let res = SpeedTestResult(uploadMBps: upAgg, downloadMBps: down ?? 0,
                                      sourceReadMBps: nil, ranAt: Date())
            let (settings, recs) = Recommender.recommend(
                uploadAgg: upAgg, uploadStream: upStream, download: down,
                sourceRead: nil, ramBytes: ramBytes, base: baseSettings)
            self.result = res
            self.recommendedSettings = settings
            self.recommendations = recs
            self.phase = .done
            self.phaseText = L("完成", "Done")
        } catch {
            self.error = error.localizedDescription
            self.phase = .failed
            self.phaseText = L("测速失败", "Speed test failed")
            // 尽力清理
            await cleanupRemote()
            cleanupLocal()
        }
    }

    /// 在后台线程生成测试数据（零数据；Drive 不压缩，测速有效），避免卡界面
    nonisolated private static func generate(dir: URL, count: Int, mbEach: Int) async throws {
        try await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let chunk = Data(count: 4 * 1_048_576) // 4MB 一块
            for i in 0..<count {
                let f = dir.appendingPathComponent("t\(i).bin")
                FileManager.default.createFile(atPath: f.path, contents: nil)
                let h = try FileHandle(forWritingTo: f)
                var written = 0
                while written < mbEach { h.write(chunk); written += 4 }
                try? h.close()
            }
        }.value
    }

    /// 稳定段测速：忽略前 3 秒 TCP 加速期，只用稳定窗口的字节增量；到 capSeconds 就停，保证测够时长又不过量。
    private func measureCopy(client: RCClient, src: String, dst: String, group: String,
                             config: [String: Any], transfers: Int,
                             capSeconds: Double) async throws -> (rate: Double, bytes: Int64, seconds: Double) {
        var cfg = config
        cfg["Transfers"] = transfers
        cfg["Checkers"] = transfers
        cfg["CheckFirst"] = false
        cfg.removeValue(forKey: "MaxTransfer"); cfg.removeValue(forKey: "CutoffMode")
        cfg.removeValue(forKey: "BwLimit")   // 测的是网络上限，不受白天限速表影响
        let resp = try await client.call("sync/copy", [
            "srcFs": src, "dstFs": dst, "_async": true, "_group": group, "_config": cfg,
        ])
        let jid = (resp["jobid"] as? NSNumber)?.intValue ?? 0
        var samples: [(t: Double, b: Int64)] = []
        let start = Date()
        var stopped = false
        while true {
            try await Task.sleep(nanoseconds: 400_000_000)
            if let stats = try? await client.call("core/stats", ["group": group]) {
                samples.append((Date().timeIntervalSince(start), (stats["bytes"] as? NSNumber)?.int64Value ?? 0))
            }
            let elapsed = Date().timeIntervalSince(start)
            if let st = try? await client.call("job/status", ["jobid": jid]),
               (st["finished"] as? Bool ?? false) {
                if !(st["success"] as? Bool ?? false) {
                    throw RcloneError.server((st["error"] as? String) ?? L("测速传输失败", "Speed-test transfer failed"))
                }
                break
            }
            if !stopped && elapsed >= capSeconds {
                stopped = true
                _ = try? await client.call("job/stop", ["jobid": jid])   // 测够时长就停，剩余不再传
                try await Task.sleep(nanoseconds: 300_000_000)
                if let stats = try? await client.call("core/stats", ["group": group]) {
                    samples.append((Date().timeIntervalSince(start), (stats["bytes"] as? NSNumber)?.int64Value ?? 0))
                }
                break
            }
            if elapsed > capSeconds + 20 { break }
        }
        guard let last = samples.last, last.b > 0 else { return (0, 0, samples.last?.t ?? 0) }
        // 稳定窗口：从第一个 ≥3s 的采样到最后一个
        let warm = samples.first(where: { $0.t >= 3.0 }) ?? samples.first!
        let dt = last.t - warm.t
        let db = Double(last.b - warm.b)
        if dt > 0.8 && db > 0 { return ((db / dt) / 1_000_000, last.b, last.t) }
        return (Double(last.b) / max(last.t, 0.001) / 1_000_000, last.b, last.t)
    }
}

// MARK: - Recommendation engine

enum Recommender {
    /// 根据实测速度推荐参数 + 生成中文解释
    static func recommend(uploadAgg: Double, uploadStream: Double?, download: Double?,
                          sourceRead: Double?, ramBytes: Int64,
                          base: TransferSettings) -> (TransferSettings, [Recommendation]) {
        var s = base
        var recs: [Recommendation] = []
        let up = max(uploadAgg, 0.1)

        // 单/多连接比：判断是否需要更多并发
        let ratio: Double? = {
            guard let single = uploadStream, single > 0.1 else { return nil }
            return uploadAgg / single
        }()

        // 1) transfers —— 按上行速度分档，并结合单/多连接比与来源读速
        var transfers: Int
        switch up {
        case ..<6: transfers = 4
        case ..<15: transfers = 6
        case ..<40: transfers = 8
        case ..<80: transfers = 10
        case ..<130: transfers = 12
        default: transfers = 16
        }
        var transfersNote = L("实测上行约 \(fmt(up)) MB/s，据此设定并发。",
                              "Measured uplink ≈ \(fmt(up)) MB/s; parallelism set accordingly.")
        if let r = ratio {
            if r < 1.3 {
                transfers = min(transfers, 6)
                transfersNote = L("单连接就已接近多连接速度（约 \(fmt(uploadAgg)) MB/s），说明上行链路本身是瓶颈，过高并发无益，降到 \(transfers)。",
                                  "One stream already ≈ the aggregate (~\(fmt(uploadAgg)) MB/s), so the uplink itself is the bottleneck; more parallelism won't help — set to \(transfers).")
            } else if r > 2.5 {
                transfers = min(transfers + 2, 20)
                transfersNote = L("多连接明显快于单连接（\(fmt(uploadAgg)) vs \(fmt(uploadStream ?? 0)) MB/s），加大并发能提速，设为 \(transfers)。",
                                  "Aggregate is much faster than one stream (\(fmt(uploadAgg)) vs \(fmt(uploadStream ?? 0)) MB/s); more parallelism helps — set to \(transfers).")
            }
        }
        if let sr = sourceRead, sr < up * 0.9 {
            transfersNote += L(" 注意读卡/硬盘速度约 \(fmt(sr)) MB/s 更低，才是真正瓶颈。",
                               " Note the card/disk read (~\(fmt(sr)) MB/s) is lower and is the real bottleneck.")
        }
        s.transfers = transfers
        recs.append(Recommendation(title: L("并发文件数 --transfers", "Parallel files --transfers"), value: "\(transfers)", reason: transfersNote))
        if transfers > 12 {
            recs.append(Recommendation(title: L("⚠️ 关于高并发", "⚠️ About high concurrency"), value: ">12",
                reason: L("并发超过 12 时，务必已自建 Google client_id，否则很容易触发 403 限速反而更慢。",
                          "Above 12 you must use your own Google client_id, or you'll hit 403 rate limits and go slower.")))
        }

        // 2) checkers
        s.checkers = min(transfers + 4, 24)
        recs.append(Recommendation(title: L("并发校验数 --checkers", "Parallel checkers --checkers"), value: "\(s.checkers)",
            reason: L("比对本地与网盘已存在文件的并发数，通常略高于 transfers 即可。",
                      "Parallelism for comparing local vs cloud; slightly above transfers is fine.")))

        // 3) chunk-size —— 快链路加大分片；用 RAM 上限收敛（占用 ≤ 30% 内存）
        var chunk = up >= 80 ? 128 : 64
        chunk = fitChunkToRAM(transfers: transfers, chunk: chunk, buffer: s.bufferSizeMiB, ramBytes: ramBytes)
        s.driveChunkSizeMiB = chunk
        let estGB = Double(transfers) * Double(chunk + s.bufferSizeMiB) / 1024.0
        recs.append(Recommendation(title: L("上传分片 --drive-chunk-size", "Upload chunk --drive-chunk-size"), value: "\(chunk)Mi",
            reason: L("分片越大吞吐略高但更吃内存。当前组合预估占用约 \(String(format: "%.1f", estGB)) GB 内存（上限按 30% 收敛）。",
                      "Larger chunks give a bit more throughput but use more RAM. This combo ≈ \(String(format: "%.1f", estGB)) GB (capped at 30%).")))

        // 4) tpslimit
        s.tpsLimit = 10
        recs.append(Recommendation(title: L("每秒请求上限 --tpslimit", "Requests/sec --tpslimit"), value: "10",
            reason: L("Google Drive 约每秒 10 次请求；保持 10 可稳定避免 403（rclone 自带退避作二次保护）。",
                      "Google Drive allows ~10 requests/sec; keeping 10 avoids 403s (rclone's pacer is a backup).")))

        // 5) bwlimit
        s.bwLimit = ""
        recs.append(Recommendation(title: L("限速 --bwlimit", "Bandwidth limit --bwlimit"), value: L("不限速", "Unlimited"),
            reason: L("默认跑满带宽。若白天要留带宽，可在设置里填时间表，如 08:00,20M 23:00,off（单位是 MiB/s，1Gbps≈125MiB/s）。",
                      "Full speed by default. To reserve daytime bandwidth, set a schedule like 08:00,20M 23:00,off (unit MiB/s; 1Gbps≈125MiB/s).")))

        // 6) 每日上限保护
        s.stopOnUploadLimit = true
        recs.append(Recommendation(title: L("每日上限保护 --drive-stop-on-upload-limit", "Daily-cap guard --drive-stop-on-upload-limit"), value: L("开启", "On"),
            reason: L("Google 每账号每天约 750GB 上传上限；开启后到达即安全停止，队列会等次日自动续传。",
                      "Google caps uploads at ~750GB/account/day; this stops safely on hit and the queue resumes next day.")))

        // 瓶颈总结
        let bottleneck: String
        if let sr = sourceRead, sr < up * 0.9 {
            bottleneck = L("读卡/硬盘（~\(fmt(sr)) MB/s）", "Card/disk read (~\(fmt(sr)) MB/s)")
        } else if let r = ratio, r < 1.3 {
            bottleneck = L("上行链路单连接上限（~\(fmt(up)) MB/s）", "Single-stream uplink limit (~\(fmt(up)) MB/s)")
        } else {
            bottleneck = L("上行总带宽（~\(fmt(up)) MB/s）", "Total uplink bandwidth (~\(fmt(up)) MB/s)")
        }
        recs.insert(Recommendation(title: L("瓶颈判断", "Bottleneck"), value: bottleneck,
            reason: L("以上参数已围绕该瓶颈优化。你也可以在设置里手动微调，每项都有说明。",
                      "The settings above are tuned around this bottleneck. You can fine-tune each in Settings.")), at: 0)

        return (s, recs)
    }

    static func fitChunkToRAM(transfers: Int, chunk: Int, buffer: Int, ramBytes: Int64) -> Int {
        var c = chunk
        let budget = Double(ramBytes) * 0.30
        while c > 16 {
            let need = Double(transfers) * Double(c + buffer) * 1_048_576 + 300 * 1_048_576
            if need <= budget { break }
            c /= 2
        }
        return c
    }

    private static func fmt(_ d: Double) -> String { String(format: "%.0f", d) }
}
