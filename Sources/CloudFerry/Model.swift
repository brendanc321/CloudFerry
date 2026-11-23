import Foundation

// MARK: - Transfer direction

enum TransferDirection: String, Codable {
    case upload      // 本地/储存卡 -> 网盘
    case download    // 网盘 -> 本地
    case remote      // 网盘 -> 网盘
    case local       // 本地 -> 本地

    var symbol: String {
        switch self {
        case .upload: return "arrow.up.circle.fill"
        case .download: return "arrow.down.circle.fill"
        case .remote: return "arrow.left.arrow.right.circle.fill"
        case .local: return "internaldrive.fill"
        }
    }
    var label: String {
        switch self {
        case .upload: return L("上传备份", "Upload")
        case .download: return L("下载", "Download")
        case .remote: return L("网盘互传", "Cloud → Cloud")
        case .local: return L("本地拷贝", "Local copy")
        }
    }
    /// 完成时的动词（区分上传/下载）
    var doneVerb: String {
        switch self {
        case .upload: return L("已备份", "Backed up")
        case .download: return L("已下载", "Downloaded")
        case .remote: return L("已复制到网盘", "Copied")
        case .local: return L("已复制", "Copied")
        }
    }
    var isDownload: Bool { self == .download }
}

// MARK: - Cutoff mode

enum CutoffMode: String, Codable, CaseIterable, Identifiable {
    case cautious = "CAUTIOUS"
    case soft = "SOFT"
    case hard = "HARD"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cautious: return L("谨慎 (Cautious)", "Cautious")
        case .soft: return L("柔性 (Soft)", "Soft")
        case .hard: return L("硬性 (Hard)", "Hard")
        }
    }
}

// MARK: - Transfer settings (maps 1:1 to rclone flags)

/// 所有可调参数。字段名旁的注释即为对应的 rclone 参数。
struct TransferSettings: Codable, Equatable {
    // 并发
    var transfers: Int = 8            // --transfers
    var checkers: Int = 8             // --checkers
    var maxBacklog: Int = 10000       // --max-backlog
    var orderBy: String = ""          // --order-by  (例如 "size,mixed")

    // Google Drive 后端 (通过连接字符串注入)
    var driveChunkSizeMiB: Int = 64        // --drive-chunk-size
    var driveUploadCutoffMiB: Int = 8      // --drive-upload-cutoff
    var pacerMinSleepMs: Int = 10          // --drive-pacer-min-sleep
    var pacerBurst: Int = 100              // --drive-pacer-burst
    var stopOnUploadLimit: Bool = true     // --drive-stop-on-upload-limit
    var serverSideAcrossConfigs: Bool = false // --drive-server-side-across-configs

    // 速率 / 带宽
    var tpsLimit: Double = 10          // --tpslimit
    var tpsLimitBurst: Int = 20        // --tpslimit-burst
    var bwLimit: String = ""           // --bwlimit (支持时间表 "08:00,10M 23:00,off")
    var maxTransfer: String = ""       // --max-transfer (例如 "740G")
    var cutoffMode: CutoffMode = .cautious // --cutoff-mode

    // 可靠性 / 挂机
    var retries: Int = 10              // --retries
    var lowLevelRetries: Int = 20      // --low-level-retries

    // 完整性 / 行为
    var checkFirst: Bool = true        // --check-first
    var checksum: Bool = false         // --checksum
    var ignoreExisting: Bool = false   // --ignore-existing
    var updateOlder: Bool = false      // --update
    var immutable: Bool = false        // --immutable
    var trackRenames: Bool = false     // --track-renames
    var sizeOnly: Bool = false         // --size-only

    // 内存 / 缓冲
    var bufferSizeMiB: Int = 16        // --buffer-size
    var multiThreadStreams: Int = 4    // --multi-thread-streams (仅下载/部分后端)

    // 过滤 (macOS 垃圾文件等)
    var excludeSystemJunk: Bool = true
    var customExcludes: [String] = []  // --exclude 规则
    var minAge: String = ""            // --min-age (例如 "1m" 避免抓正在写入的文件)

    /// 预估内存占用 (transfers × (chunk-size + buffer) + ~300MB 基础)
    var estimatedRAMBytes: Int64 {
        Int64(transfers) * Int64(driveChunkSizeMiB + bufferSizeMiB) * 1_048_576 + 300 * 1_048_576
    }

    // Google Drive 要求 chunk-size / upload-cutoff 必须是 2 的幂（≥256KiB），用下拉选择避免非法值
    static let chunkSizeOptions = [8, 16, 32, 64, 128, 256, 512, 1024]
    static let uploadCutoffOptions = [8, 16, 32, 64, 128, 256, 512, 1024]
    static let transfersRange = 1...32
    static let checkersRange = 1...64
}

// MARK: - Presets

struct Preset: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let settings: TransferSettings

    static var all: [Preset] { [
        Preset(
            id: "balanced",
            name: L("省心默认", "Balanced (default)"),
            subtitle: L("平衡、稳定，适合大多数情况", "Balanced and stable for most cases"),
            settings: {
                var s = TransferSettings()
                s.transfers = 8; s.checkers = 8
                s.driveChunkSizeMiB = 64
                s.driveUploadCutoffMiB = 64   // 让常见 RAW/JPG 单请求上传，减少 API 往返
                s.tpsLimit = 10
                s.checkFirst = true
                s.stopOnUploadLimit = true
                return s
            }()
        ),
        Preset(
            id: "many-small",
            name: L("照片卡备份 · 海量小文件", "Photo card · many small files"),
            subtitle: L("几千~几万张 RAW/JPG，最大化并发", "Thousands of RAW/JPG, max parallelism"),
            settings: {
                var s = TransferSettings()
                s.transfers = 12; s.checkers = 16
                s.driveChunkSizeMiB = 64
                s.driveUploadCutoffMiB = 64   // RAW/JPG 单请求上传
                s.tpsLimit = 10; s.tpsLimitBurst = 20
                s.checkFirst = true
                s.orderBy = "size,mixed"
                s.stopOnUploadLimit = true
                s.excludeSystemJunk = true
                return s
            }()
        ),
        Preset(
            id: "one-huge",
            name: L("单个大文件 · 大视频", "Single huge file · video"),
            subtitle: L("200–500GB 单文件，加大分片", "200–500GB single file, larger chunks"),
            settings: {
                var s = TransferSettings()
                s.transfers = 4; s.checkers = 4
                s.driveChunkSizeMiB = 256    // 单文件靠大分片提吞吐（Drive 不支持单文件多线程上传）
                s.driveUploadCutoffMiB = 256
                s.tpsLimit = 10
                s.checkFirst = false
                s.stopOnUploadLimit = true
                s.retries = 15
                s.lowLevelRetries = 40       // 网络抖动时在同一次运行内自动续传该大文件，不从头重来
                return s
            }()
        ),
        Preset(
            id: "overnight",
            name: L("通宵挂机 · 多卡排队 + 750GB/日保护", "Overnight · multi-card + 750GB/day guard"),
            subtitle: L("夜间限速表 + 达到每日上限自动暂停次日续传", "Night bandwidth schedule + auto-resume next day"),
            settings: {
                var s = TransferSettings()
                s.transfers = 10; s.checkers = 12
                s.driveChunkSizeMiB = 128
                s.tpsLimit = 10
                s.checkFirst = true
                s.stopOnUploadLimit = true
                s.maxTransfer = "740G"        // 贴近 Google 每日 ~750GB 上限
                s.cutoffMode = .cautious      // 到达上限时不切断正在传的文件
                s.retries = 20; s.lowLevelRetries = 30
                s.bwLimit = ""                // 用户可在设置里填时间表，如 "08:00,20M 23:00,off"
                s.excludeSystemJunk = true
                return s
            }()
        ),
    ] }

    static var `default`: Preset { all[0] }
}

// MARK: - Remote (a configured rclone backend)

struct Remote: Identifiable, Codable, Equatable {
    var name: String           // 不含冒号
    var type: String           // "drive", "dropbox", "onedrive", "s3"...
    var clientID: String? = nil  // Google Drive：自建通道的 client_id；空 = 用 rclone 公用通道
    var id: String { name }

    var isDrive: Bool { type == "drive" }
    /// Google Drive 是否用的是用户自己的通道（client_id）
    var usesOwnClient: Bool { !(clientID ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    var fsPrefix: String { "\(name):" }

    var typeLabel: String {
        switch type {
        case "drive": return "Google Drive"
        case "dropbox": return "Dropbox"
        case "onedrive": return "OneDrive"
        case "s3": return L("S3 兼容", "S3-compatible")
        case "b2": return "Backblaze B2"
        case "mega": return "MEGA"
        case "pcloud": return "pCloud"
        case "box": return "Box"
        case "webdav": return "WebDAV"
        case "sftp": return "SFTP"
        default: return type
        }
    }
    var iconName: String {
        switch type {
        case "drive": return "externaldrive.badge.icloud"
        case "s3", "b2": return "cylinder.split.1x2"
        default: return "cloud"
        }
    }
}

struct RemoteQuota: Equatable {
    var total: Int64?
    var used: Int64?
    var free: Int64?
    var trashed: Int64?
}

struct RemoteEntry: Identifiable {
    let name: String
    let path: String
    var size: Int64          // 文件夹可通过"计算大小"填入
    let isDir: Bool
    let modTime: Date?
    var sizeComputed: Bool = false   // 文件夹大小是否已算过
    var fileID: String? = nil        // 网盘内部 ID（Google Drive 用来取缩略图、共享）
    var mimeType: String? = nil
    var id: String { path }
    var ext: String { (name as NSString).pathExtension.lowercased() }
    var isImage: Bool { (mimeType ?? "").hasPrefix("image/") || ["jpg","jpeg","png","heic","heif","tif","tiff","gif","webp","cr3","cr2","arw","nef","raf","dng","orf","rw2"].contains(ext) }
    var isVideo: Bool { (mimeType ?? "").hasPrefix("video/") || ["mp4","mov","m4v","mxf","avi","mts","m2ts","mkv","insv","lrv","braw","r3d","crm"].contains(ext) }
}

struct VolumeInfo: Identifiable, Equatable {
    let url: URL
    let name: String
    let isRemovable: Bool
    let total: Int64
    let free: Int64
    var uuid: String? = nil
    var id: String { url.path }
    var used: Int64 { max(total - free, 0) }
}

/// 来源所在的外接卷（储存卡/SSD）信息，用于自动命名备份文件夹、识别“这张卡备份过没有”
struct SourceVolume {
    let rootURL: URL
    let name: String
    let uuid: String?
    let isExternal: Bool

    /// 只读取卷的元数据（名称/UUID/是否外接），不读取卡里的任何文件内容
    static func of(_ url: URL) -> SourceVolume? {
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeNameKey, .volumeUUIDStringKey,
                                         .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        guard let rv = try? url.resourceValues(forKeys: keys), let root = rv.volume else { return nil }
        let removable = (rv.volumeIsRemovable ?? false) || (rv.volumeIsEjectable ?? false)
        let external = removable || !(rv.volumeIsInternal ?? true)
        return SourceVolume(rootURL: root, name: rv.volumeName ?? root.lastPathComponent,
                            uuid: rv.volumeUUIDString, isExternal: external && root.path != "/")
    }
}

// MARK: - Job status

enum JobStatus: String, Codable {
    case queued          // 排队中
    case running         // 传输中
    case paused          // 已暂停
    case completed       // 完成
    case failed          // 失败
    case canceled        // 已取消
    case waitingDailyCap // 触发每日上限，等待自动续传
    case waitingRetry    // 网络等临时错误，稍后自动重试

    var label: String {
        switch self {
        case .queued: return L("排队中", "Queued")
        case .running: return L("传输中", "Transferring")
        case .paused: return L("已暂停", "Paused")
        case .completed: return L("已完成", "Done")
        case .failed: return L("失败", "Failed")
        case .canceled: return L("已取消", "Canceled")
        case .waitingDailyCap: return L("达每日上限·待续传", "Daily cap · will resume")
        case .waitingRetry: return L("稍后自动重试", "Retrying soon")
        }
    }
    var isActive: Bool { self == .running }
    var isTerminal: Bool { self == .completed || self == .canceled }
    /// 已经结束（会写入历史记录）
    var isFinal: Bool { self == .completed || self == .canceled || self == .failed }
}

// MARK: - Transfer job (queue item)

struct TransferJob: Identifiable, Codable, Equatable {
    let id: UUID
    var sourceFs: String          // 本地路径 或 remote:path
    var sourceLabel: String
    var destFs: String            // remote:path 或 本地路径
    var destLabel: String
    var direction: TransferDirection
    var presetName: String
    var settings: TransferSettings
    var createdAt: Date

    var status: JobStatus = .queued
    var jobid: Int? = nil
    var error: String? = nil
    var resumeAfter: Date? = nil  // 每日上限时的自动续传时间
    var verified: Bool = false    // 已通过 rclone check 校验

    // 实时统计（可持久化，用于重启后展示最后进度）
    var bytes: Int64 = 0
    var totalBytes: Int64 = 0
    var speed: Double = 0
    var etaSeconds: Int? = nil
    var transfersDone: Int = 0
    var totalTransfers: Int = 0
    var checks: Int = 0
    var errorsCount: Int = 0
    var transferringNames: [String] = []

    // v1.1 新增（全部可选，兼容旧版保存的 state.json）
    var isSingleFile: Bool? = nil        // 来源是单个文件（用 copyfile 传，而非整个文件夹）
    var volumeName: String? = nil        // 来源所在储存卡/SSD 的卷名
    var volumeUUID: String? = nil        // 卷 UUID（识别同一张卡）
    var startedAt: Date? = nil
    var finishedAt: Date? = nil
    var activeSeconds: Double? = nil     // 实际传输用时（不含排队）
    var autoRetries: Int? = nil          // 已自动重试次数
    var verifyNote: String? = nil        // 校验结果说明

    /// stats 分组名
    var group: String { "cf-" + id.uuidString.prefix(8).lowercased() }

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(bytes) / Double(totalBytes))
    }
    var hasSizeInfo: Bool { totalBytes > 0 }
    var doneBytes: Int64 { max(bytes, totalBytes) }
    var averageSpeed: Double? {
        guard let s = activeSeconds, s > 1, bytes > 0 else { return nil }
        return Double(bytes) / s
    }
    /// 来源是本机路径（不是 remote:path）
    var sourceIsLocal: Bool { sourceFs.hasPrefix("/") }
    var destIsLocal: Bool { destFs.hasPrefix("/") }

    init(sourceFs: String, sourceLabel: String, destFs: String, destLabel: String,
         direction: TransferDirection, presetName: String, settings: TransferSettings) {
        self.id = UUID()
        self.sourceFs = sourceFs
        self.sourceLabel = sourceLabel
        self.destFs = destFs
        self.destLabel = destLabel
        self.direction = direction
        self.presetName = presetName
        self.settings = settings
        self.createdAt = Date()
    }
}

// MARK: - Speed test result & recommendation

struct SpeedTestResult: Equatable {
    var uploadMBps: Double = 0
    var downloadMBps: Double = 0
    var sourceReadMBps: Double? = nil
    var ranAt: Date = Date()
}

struct Recommendation: Identifiable, Equatable {
    var id = UUID()
    var title: String        // 例如 "并发数 --transfers"
    var value: String        // 例如 "12"
    var reason: String       // 中文解释
}

// MARK: - 实时文件遥测（不落盘）

/// 正在传的单个文件（来自 rclone core/stats 的 transferring 列表）
struct LiveFile: Equatable {
    var name: String
    var size: Int64
    var bytes: Int64
    var percent: Int
    var speed: Double
    var speedAvg: Double
    var eta: Int?
}

/// 刚传完的文件（来自 rclone core/transferred）
struct DoneFile: Equatable {
    var name: String
    var size: Int64
    var error: String
    var completedAt: Date?
    var seconds: Double?
    var ok: Bool { error.isEmpty }
}
