import AppKit
import QuickLookThumbnailing

// 浏览网盘的「后台」部分（v1.3）：
//   · 浏览位置（我的网盘 / 与我共享 / 打开的分享链接）
//   · 文件操作：移动、重命名、取到本机（拖到访达）、在线播放地址
//   · Google Drive 接口：缩略图、文件信息、共享权限、按 ID 下载
// 所有 Google 接口都用 rclone 里已保存的、用户自己的登录令牌，只在本机直接请求 googleapis.com。

// MARK: - 浏览位置

struct BrowseRoot: Equatable, Codable, Hashable {
    enum Kind: String, Codable { case remote, sharedWithMe, link }
    var kind: Kind
    var remote: String          // rclone 配置里的网盘名，例如 gdrive
    var folderID: String? = nil // link：分享链接里的文件夹 ID
    var title: String

    /// 交给 rclone 的「网盘名」（可带连接参数），后面接 ":" 就是 fs
    var spec: String {
        switch kind {
        case .remote: return remote
        case .sharedWithMe: return "\(remote),shared_with_me=true"
        case .link: return "\(remote),root_folder_id=\(folderID ?? "")"
        }
    }
    var symbol: String {
        switch kind {
        case .remote: return "externaldrive.connected.to.line.below"
        case .sharedWithMe: return "person.2"
        case .link: return "link"
        }
    }

    /// 用户打开过的分享链接（保存在偏好设置里，侧边栏「链接」一栏）
    static var savedLinks: [BrowseRoot] {
        get {
            guard let d = UserDefaults.standard.data(forKey: "cf.browseLinks"),
                  let v = try? JSONDecoder().decode([BrowseRoot].self, from: d) else { return [] }
            return v
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "cf.browseLinks") }
    }
}

/// Google Drive 分享链接解析
enum DriveLink {
    /// 返回文件/文件夹 ID；isFolder == nil 表示从链接上看不出来
    static func parse(_ s: String) -> (id: String, isFolder: Bool?)? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        func first(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: t) else { return nil }
            return String(t[r])
        }
        if let id = first("/folders/([A-Za-z0-9_-]{10,})") { return (id, true) }
        if let id = first("/file/d/([A-Za-z0-9_-]{10,})") { return (id, false) }
        if let id = first("/d/([A-Za-z0-9_-]{10,})") { return (id, false) }
        if let id = first("[?&]id=([A-Za-z0-9_-]{10,})") { return (id, nil) }
        if t.range(of: "^[A-Za-z0-9_-]{20,}$", options: .regularExpression) != nil { return (t, nil) }
        return nil
    }
}

struct DriveFileMeta {
    let thumbnailLink: String?
    let durationMs: Int?
    let width: Int?
    let height: Int?
    let webViewLink: String?
    let shared: Bool
    let ownedByMe: Bool
    let ownerName: String?
}

struct DrivePermission: Identifiable {
    let id: String
    let type: String      // user / group / domain / anyone
    let role: String      // owner / organizer / fileOrganizer / writer / commenter / reader
    let email: String?
    let name: String?

    var roleLabel: String {
        switch role {
        case "owner": return L("所有者", "Owner")
        case "writer", "fileOrganizer", "organizer": return L("可编辑", "Editor")
        case "commenter": return L("可评论", "Commenter")
        default: return L("可查看", "Viewer")
        }
    }
    var who: String {
        if type == "anyone" { return L("任何获得链接的人", "Anyone with the link") }
        if type == "domain" { return L("同一组织的人", "People in the organization") }
        return name.map { n in email.map { "\(n) <\($0)>" } ?? n } ?? email ?? "?"
    }
}

// MARK: - 文件操作 + Google 接口

extension QueueEngine {
    private static func join(_ dir: String, _ name: String) -> String { dir.isEmpty ? name : "\(dir)/\(name)" }

    /// 移动（同一网盘内 Google Drive 是服务器端移动，几乎瞬间完成）。返回失败个数
    func moveEntries(fromSpec: String, _ items: [RemoteEntry], toSpec: String, toDir: String) async -> Int {
        guard let client else { return items.count }
        var failed = 0
        for e in items {
            let dst = Self.join(toDir, e.name)
            if fromSpec == toSpec && (dst == e.path || (e.isDir && (toDir == e.path || toDir.hasPrefix(e.path + "/")))) { continue }
            do {
                if e.isDir {
                    _ = try await client.call("sync/move", ["srcFs": "\(fromSpec):\(e.path)", "dstFs": "\(toSpec):\(dst)",
                                                            "createEmptySrcDirs": true, "deleteEmptySrcDirs": true], timeout: 7200)
                } else {
                    _ = try await client.call("operations/movefile", ["srcFs": "\(fromSpec):", "srcRemote": e.path,
                                                                      "dstFs": "\(toSpec):", "dstRemote": dst], timeout: 7200)
                }
                addLog(.info, L("已移动：", "Moved: ") + "\(fromSpec):\(e.path) → \(toSpec):\(dst)")
            } catch {
                failed += 1
                addLog(.error, L("移动失败：", "Move failed: ") + "\(e.path) — \(error.localizedDescription)")
            }
        }
        return failed
    }

    func renameEntry(spec: String, _ e: RemoteEntry, to newName: String) async -> Bool {
        let parent = (e.path as NSString).deletingLastPathComponent
        let renamed = RemoteEntry(name: e.name, path: e.path, size: e.size, isDir: e.isDir, modTime: e.modTime)
        // 借用 move：目标目录不变，只换名字
        guard let client else { return false }
        let dst = Self.join(parent, newName)
        do {
            if renamed.isDir {
                _ = try await client.call("sync/move", ["srcFs": "\(spec):\(e.path)", "dstFs": "\(spec):\(dst)",
                                                        "createEmptySrcDirs": true, "deleteEmptySrcDirs": true], timeout: 7200)
            } else {
                _ = try await client.call("operations/movefile", ["srcFs": "\(spec):", "srcRemote": e.path,
                                                                  "dstFs": "\(spec):", "dstRemote": dst], timeout: 600)
            }
            addLog(.info, L("已重命名：", "Renamed: ") + "\(e.name) → \(newName)")
            return true
        } catch {
            addLog(.error, L("重命名失败：", "Rename failed: ") + "\(e.name) — \(error.localizedDescription)")
            return false
        }
    }

    /// 直接取到本机某个文件夹（拖到访达时用；大文件/文件夹改走下载队列）
    func fetchToLocal(spec: String, _ e: RemoteEntry, into dir: URL) async -> Bool {
        guard let client else { return false }
        do {
            if e.isDir {
                _ = try await client.call("sync/copy", ["srcFs": "\(spec):\(e.path)", "dstFs": dir.appendingPathComponent(e.name).path], timeout: 7200)
            } else {
                _ = try await client.call("operations/copyfile", ["srcFs": "\(spec):", "srcRemote": e.path,
                                                                  "dstFs": dir.path, "dstRemote": e.name], timeout: 7200)
            }
            addLog(.success, L("已下载到 ", "Downloaded to ") + dir.path + "：" + e.name)
            return true
        } catch {
            addLog(.error, L("下载失败：", "Download failed: ") + "\(e.name) — \(error.localizedDescription)")
            return false
        }
    }

    // MARK: 在线播放 / 预览（rclone rcd --rc-serve）

    /// http://127.0.0.1:端口/[网盘:]/路径 —— 支持断点（Range），视频可以拖动进度条
    func serveURL(spec: String, path: String) -> URL? {
        guard let c = client else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]%")
        let root = ("[" + spec + ":]").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let rest = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }.joined(separator: "/")
        return URL(string: c.baseURL.absoluteString + "/" + root + "/" + rest)
    }
    var serveHeaders: [String: String] { client.map { ["Authorization": $0.authHeader] } ?? [:] }

    /// 本地类网盘（alias 指向本机文件夹）的真实路径：用系统快速查看生成缩略图
    func localPath(remote: String, path: String) async -> String? {
        guard let r = self.remote(named: remote), r.type == "alias", let client,
              let cfg = try? await client.call("config/get", ["name": remote]),
              let root = cfg["remote"] as? String, root.hasPrefix("/") else { return nil }
        return path.isEmpty ? root : root + "/" + path
    }

    // MARK: Google Drive 令牌

    private static var tokenCache: [String: (token: String, expiry: Date)] = [:]

    func driveToken(remote: String, forceRefresh: Bool = false) async -> String? {
        if !forceRefresh, let t = Self.tokenCache[remote], t.expiry.timeIntervalSinceNow > 120 { return t.token }
        guard let c = client else { return nil }
        func read() async -> (String, Date)? {
            guard let cfg = try? await c.call("config/get", ["name": remote]), let tok = cfg["token"] as? String,
                  let d = tok.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let at = j["access_token"] as? String else { return nil }
            return (at, Format.parseModTime(j["expiry"] as? String) ?? Date.distantPast)
        }
        if !forceRefresh, let (t, exp) = await read(), exp.timeIntervalSinceNow > 120 {
            Self.tokenCache[remote] = (t, exp); return t
        }
        // 令牌快过期：随便调一次网盘接口，rclone 会自动续期并写回配置
        _ = try? await c.call("operations/about", ["fs": "\(remote):"], timeout: 60)
        guard let (t, exp) = await read() else { return nil }
        Self.tokenCache[remote] = (t, exp)
        return t
    }

    /// 调 Google Drive REST 接口（401 时刷新令牌重试一次）
    func driveRequest(remote: String, _ method: String, _ url: String, json: [String: Any]? = nil) async -> (Int, Data)? {
        for attempt in 0..<2 {
            guard let token = await driveToken(remote: remote, forceRefresh: attempt == 1), let u = URL(string: url) else { return nil }
            var req = URLRequest(url: u)
            req.httpMethod = method
            req.timeoutInterval = 30
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let json {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: json)
            }
            guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { return nil }
            if http.statusCode == 401 && attempt == 0 { continue }
            return (http.statusCode, data)
        }
        return nil
    }

    private static func q(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
    }
    private static func driveError(_ data: Data) -> String {
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((j?["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? "?"
    }

    /// 当前浏览目录在 Drive 里的文件夹 ID（根目录 = root / 链接 ID；「与我共享」根目录没有 ID）
    func driveFolderID(_ root: BrowseRoot, path: String) async -> String? {
        if path.isEmpty {
            switch root.kind {
            case .remote: return "root"
            case .link: return root.folderID
            case .sharedWithMe: return nil
            }
        }
        guard let client,
              let r = try? await client.call("operations/stat", ["fs": "\(root.spec):", "remote": path], timeout: 60),
              let item = r["item"] as? [String: Any] else { return nil }
        return item["ID"] as? String
    }

    /// 一次取回整个文件夹的缩略图链接、视频时长等（按文件 ID 索引）
    func driveFolderMeta(_ root: BrowseRoot, path: String) async -> [String: DriveFileMeta] {
        guard remote(named: root.remote)?.isDrive == true else { return [:] }
        let query: String
        if let fid = await driveFolderID(root, path: path) {
            query = "'\(fid)' in parents and trashed = false"
        } else if root.kind == .sharedWithMe && path.isEmpty {
            query = "sharedWithMe = true and trashed = false"
        } else { return [:] }
        var out: [String: DriveFileMeta] = [:]
        var pageToken: String? = nil
        for _ in 0..<10 {
            var url = "https://www.googleapis.com/drive/v3/files?pageSize=1000&supportsAllDrives=true&includeItemsFromAllDrives=true"
                + "&q=" + Self.q(query)
                + "&fields=" + Self.q("nextPageToken,files(id,thumbnailLink,videoMediaMetadata(durationMillis),imageMediaMetadata(width,height),webViewLink,shared,ownedByMe,owners(displayName))")
            if let pageToken { url += "&pageToken=" + Self.q(pageToken) }
            guard let (code, data) = await driveRequest(remote: root.remote, "GET", url), code == 200,
                  let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { break }
            for f in (j["files"] as? [[String: Any]]) ?? [] {
                guard let id = f["id"] as? String else { continue }
                let video = f["videoMediaMetadata"] as? [String: Any]
                let image = f["imageMediaMetadata"] as? [String: Any]
                let owner = (f["owners"] as? [[String: Any]])?.first
                out[id] = DriveFileMeta(thumbnailLink: f["thumbnailLink"] as? String,
                                        durationMs: (video?["durationMillis"] as? String).flatMap(Int.init) ?? (video?["durationMillis"] as? NSNumber)?.intValue,
                                        width: (image?["width"] as? NSNumber)?.intValue, height: (image?["height"] as? NSNumber)?.intValue,
                                        webViewLink: f["webViewLink"] as? String,
                                        shared: f["shared"] as? Bool ?? false, ownedByMe: f["ownedByMe"] as? Bool ?? true,
                                        ownerName: owner?["displayName"] as? String)
            }
            pageToken = j["nextPageToken"] as? String
            if pageToken == nil { break }
        }
        return out
    }

    /// 下载一张 Drive 缩略图（px = 长边像素）。带本机磁盘缓存
    func driveThumbnail(remote: String, fileID: String, link: String, px: Int) async -> NSImage? {
        let file = ThumbnailStore.cacheDir.appendingPathComponent("\(fileID)_\(px).jpg")
        if let img = NSImage(contentsOf: file) { return img }
        let sized = link.replacingOccurrences(of: "=s[0-9]+$", with: "=s\(px)", options: .regularExpression)
        guard let (code, data) = await driveRequest(remote: remote, "GET", sized), code == 200, let img = NSImage(data: data) else { return nil }
        try? data.write(to: file)
        return img
    }

    /// 文件/文件夹基本信息（打开链接、共享面板用）
    func driveFileInfo(remote: String, fileID: String) async -> [String: Any]? {
        let url = "https://www.googleapis.com/drive/v3/files/\(fileID)?supportsAllDrives=true&fields="
            + Self.q("id,name,mimeType,size,webViewLink,ownedByMe,owners(displayName,emailAddress),capabilities(canEdit,canShare,canAddChildren,canDownload),thumbnailLink")
        guard let (code, data) = await driveRequest(remote: remote, "GET", url), code == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func drivePermissions(remote: String, fileID: String) async -> [DrivePermission]? {
        let url = "https://www.googleapis.com/drive/v3/files/\(fileID)/permissions?supportsAllDrives=true&fields="
            + Self.q("permissions(id,type,role,emailAddress,displayName)")
        guard let (code, data) = await driveRequest(remote: remote, "GET", url), code == 200,
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return ((j["permissions"] as? [[String: Any]]) ?? []).compactMap { p in
            guard let id = p["id"] as? String else { return nil }
            return DrivePermission(id: id, type: p["type"] as? String ?? "", role: p["role"] as? String ?? "reader",
                                   email: p["emailAddress"] as? String, name: p["displayName"] as? String)
        }
    }

    /// 共享：type = anyone（链接）或 user（邮箱）。返回错误信息，nil = 成功
    func driveShare(remote: String, fileID: String, type: String, role: String, email: String? = nil,
                    notify: Bool = true, message: String? = nil) async -> String? {
        var url = "https://www.googleapis.com/drive/v3/files/\(fileID)/permissions?supportsAllDrives=true"
        var body: [String: Any] = ["type": type, "role": role]
        if type == "user", let email {
            body["emailAddress"] = email
            url += "&sendNotificationEmail=\(notify)"
            if notify, let message, !message.isEmpty { url += "&emailMessage=" + Self.q(message) }
        }
        guard let (code, data) = await driveRequest(remote: remote, "POST", url, json: body) else { return L("网络请求失败", "Request failed") }
        if code == 200 {
            addLog(.info, L("已共享：", "Shared: ") + "\(fileID) → \(type == "anyone" ? "link" : email ?? "") (\(role))")
            return nil
        }
        return Self.driveError(data)
    }

    func driveUnshare(remote: String, fileID: String, permissionID: String) async -> String? {
        let url = "https://www.googleapis.com/drive/v3/files/\(fileID)/permissions/\(permissionID)?supportsAllDrives=true"
        guard let (code, data) = await driveRequest(remote: remote, "DELETE", url) else { return L("网络请求失败", "Request failed") }
        return (code == 204 || code == 200) ? nil : Self.driveError(data)
    }

    /// 按文件 ID 下载（别人分享的单个文件链接）
    func driveDownloadByID(remote: String, fileID: String, into dir: URL) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.call("backend/command", ["command": "copyid", "fs": "\(remote):",
                                                          "arg": [fileID, dir.path + "/"]], timeout: 7200)
            addLog(.success, L("已按链接下载到 ", "Downloaded from link to ") + dir.path)
            return true
        } catch {
            addLog(.error, L("按链接下载失败：", "Link download failed: ") + error.localizedDescription)
            return false
        }
    }
}

// MARK: - 缩略图缓存

@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()
    private let mem = NSCache<NSString, NSImage>()
    private var inflight: [String: Task<NSImage?, Never>] = [:]

    static var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("CloudFerry/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func cached(_ key: String) -> NSImage? { mem.object(forKey: key as NSString) }

    /// 同一个 key 只加载一次；结果进内存缓存
    func load(_ key: String, _ loader: @escaping @MainActor () async -> NSImage?) async -> NSImage? {
        if let m = mem.object(forKey: key as NSString) { return m }
        if let t = inflight[key] { return await t.value }
        let t = Task { @MainActor in await loader() }
        inflight[key] = t
        let img = await t.value
        inflight[key] = nil
        if let img { mem.setObject(img, forKey: key as NSString) }
        return img
    }

    /// 本机文件的系统缩略图（快速查看，和访达一样）
    static func quickLook(path: String, px: CGFloat) async -> NSImage? {
        let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: px, height: px),
                                               scale: 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req).nsImage
    }
}

// MARK: - 浏览页后台自检（只在临时配置的 alias 假网盘上跑）

extension QueueEngine {
    func runBrowseSelfTest(remote spec: String, err: (String) -> Void) async {
        guard let root = await listPath(remote: spec, path: ""),
              let img = root.first(where: { !$0.isDir && $0.isImage }) else { err("BROWSE_FAIL list\n"); return }
        let dir = "cf-browse-test"
        guard await makeFolder(remote: spec, path: dir) else { err("BROWSE_FAIL mkdir\n"); return }
        // 1) 移动进文件夹
        let f1 = await moveEntries(fromSpec: spec, [img], toSpec: spec, toDir: dir)
        let inDir = await listPath(remote: spec, path: dir) ?? []
        guard f1 == 0, let moved = inDir.first(where: { $0.name == img.name }) else { err("BROWSE_FAIL move\n"); return }
        // 2) 重命名
        let ok2 = await renameEntry(spec: spec, moved, to: "renamed-" + img.name)
        let after = await listPath(remote: spec, path: dir) ?? []
        guard ok2, let renamed = after.first(where: { $0.name == "renamed-" + img.name }) else { err("BROWSE_FAIL rename\n"); return }
        // 3) 在线读取（rc-serve，带 Range 头，模拟视频拖动进度）
        var served = -1
        if let url = serveURL(spec: spec, path: renamed.path) {
            var req = URLRequest(url: url)
            for (k, v) in serveHeaders { req.setValue(v, forHTTPHeaderField: k) }
            if let (data, _) = try? await URLSession.shared.data(for: req) { served = data.count }
            req.setValue("bytes=0-99", forHTTPHeaderField: "Range")
            if let (part, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 206, part.count == 100 { served = served * 1 } else { served = -2 }
        }
        guard served == Int(renamed.size) else { err("BROWSE_FAIL serve got=\(served) want=\(renamed.size)\n"); return }
        // 4) 取到本机（拖到访达）
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cf-browse-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let ok4 = await fetchToLocal(spec: spec, renamed, into: tmp)
        let localSize = (try? FileManager.default.attributesOfItem(atPath: tmp.appendingPathComponent(renamed.name).path)[.size] as? NSNumber)?.int64Value ?? -1
        guard ok4, localSize == renamed.size else { err("BROWSE_FAIL fetch\n"); return }
        // 5) 还原：改回原名、移回根目录、删掉测试文件夹
        let back = RemoteEntry(name: renamed.name, path: renamed.path, size: renamed.size, isDir: false, modTime: nil)
        _ = await renameEntry(spec: spec, back, to: img.name)
        let restored = RemoteEntry(name: img.name, path: dir + "/" + img.name, size: img.size, isDir: false, modTime: nil)
        let f5 = await moveEntries(fromSpec: spec, [restored], toSpec: spec, toDir: "")
        _ = await deleteEntry(remote: spec, entry: RemoteEntry(name: dir, path: dir, size: 0, isDir: true, modTime: nil))
        let final = await listPath(remote: spec, path: "") ?? []
        try? FileManager.default.removeItem(at: tmp)
        let restoredOK = f5 == 0 && final.contains { $0.name == img.name } && !final.contains { $0.name == dir }
        let link = DriveLink.parse("https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUv?usp=sharing")
        let linkOK = link?.id == "1AbCdEfGhIjKlMnOpQrStUv" && link?.isFolder == true
            && DriveLink.parse("https://drive.google.com/file/d/1ZyXwVuTsRqPoNmLkJiHg/view")?.isFolder == false
        err("BROWSE_OK moved=1 renamed=1 served=\(served) range=206 fetched=\(localSize) restored=\(restoredOK) linkParse=\(linkOK)\n")
    }
}
