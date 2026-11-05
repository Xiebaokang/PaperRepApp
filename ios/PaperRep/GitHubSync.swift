import Foundation
import Security
import PDFKit

enum TokenVault {
    private static let service = "com.paperrep.ios.github"
    static func read() -> String {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "token", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "token"]
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw PaperError.message("无法保存 GitHub 凭据。") }
    }
}

struct GitHubFailure: Error { let status: Int; let message: String }

actor GitHubSync {
    let disk: LibraryDisk
    let repository: Repository
    let token: String
    let session: URLSession
    let progress: @Sendable (String) async -> Void
    init(disk: LibraryDisk, repository: Repository, token: String, session: URLSession = .shared, progress: @escaping @Sendable (String) async -> Void) {
        self.disk = disk; self.repository = repository; self.token = token; self.session = session; self.progress = progress
    }
    private var prefix: String { "/repos/\(repository.owner)/\(repository.name)" }
    private func pathComponent(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
    private func request(_ path: String, method: String = "GET", raw: Bool = false) throws -> URLRequest {
        guard let url = URL(string: "https://api.github.com" + prefix + path) else { throw PaperError.message("仓库地址无效。") }
        var request = URLRequest(url: url, timeoutInterval: 900)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(raw ? "application/vnd.github.raw+json" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("PaperRep-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw PaperError.message("GitHub 响应无效。") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? "GitHub 请求失败。"
            throw GitHubFailure(status: http.statusCode, message: message)
        }
    }
    private func json(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = try request(path, method: method)
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: req); try check(response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PaperError.message("GitHub 数据格式无效。") }
        return object
    }
    struct Remote {
        var branch: String
        var head: String?
        var tree: String?
        var files: [String: String]
    }
    private func remote() async throws -> Remote {
        let info = try await json("")
        let branch = repository.branch.isEmpty ? (info["default_branch"] as? String ?? "main") : repository.branch
        let ref: [String: Any]
        do { ref = try await json("/git/ref/heads/" + pathComponent(branch)) }
        catch let failure as GitHubFailure where failure.status == 409 { return Remote(branch: branch, head: nil, tree: nil, files: [:]) }
        catch let failure as GitHubFailure where failure.status == 404 {
            // Only treat an absent reference as an empty repository when it has no commits.
            do { let (data, response) = try await session.data(for: request("/commits?per_page=1")); try check(response, data: data) }
            catch let e as GitHubFailure where e.status == 409 { return Remote(branch: branch, head: nil, tree: nil, files: [:]) }
            throw PaperError.message("找不到所选分支，请检查分支名称。")
        }
        guard let object = ref["object"] as? [String: Any], let sha = object["sha"] as? String else { throw PaperError.message("无法读取仓库分支。") }
        let commit = try await json("/git/commits/" + sha)
        guard let tree = (commit["tree"] as? [String: Any])?["sha"] as? String else { throw PaperError.message("无法读取仓库目录。") }
        let listing = try await json("/git/trees/" + tree + "?recursive=1")
        guard listing["truncated"] as? Bool != true else { throw PaperError.message("仓库目录过大，无法完整同步。") }
        var files: [String: String] = [:]
        for entry in listing["tree"] as? [[String: Any]] ?? [] {
            guard let path = entry["path"] as? String, LibraryPath.managed(path) else { continue }
            guard entry["type"] as? String == "blob", entry["mode"] as? String == "100644" || entry["mode"] as? String == "100755", let hash = entry["sha"] as? String else { throw PaperError.message("仓库中的文件类型不受支持：\(path)") }
            guard (entry["size"] as? Int ?? 0) <= LibraryDisk.maximumPDFSize else { throw PaperError.message("文件超过 95 MB：\(path)") }
            if path.hasSuffix(".pdf") || path.lowercased().hasSuffix(".pdf") { guard LibraryPath.validFilename((path as NSString).lastPathComponent) else { throw PaperError.message("仓库包含无法跨平台使用的文件名：\(path)") } }
            files[path] = hash
        }
        return Remote(branch: branch, head: sha, tree: tree, files: files)
    }
    private func uploadBlob(_ file: URL, expected: String) async throws -> String {
        let body = disk.support.appendingPathComponent(UUID().uuidString + ".json")
        FileManager.default.createFile(atPath: body.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: body) }
        let input = try FileHandle(forReadingFrom: file), output = try FileHandle(forWritingTo: body)
        do {
            try output.write(contentsOf: Data("{\"encoding\":\"base64\",\"content\":\"".utf8))
            while let chunk = try input.read(upToCount: 48 * 1024), !chunk.isEmpty { try output.write(contentsOf: chunk.base64EncodedData()) }
            try output.write(contentsOf: Data("\"}".utf8)); try input.close(); try output.close()
        } catch { try? input.close(); try? output.close(); throw error }
        let (data, response) = try await session.upload(for: request("/git/blobs", method: "POST"), fromFile: body)
        try check(response, data: data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let sha = json?["sha"] as? String, sha == expected else { throw PaperError.message("上传时文件发生变化，请重试同步。") }
        return sha
    }
    func synchronize(baseline: [String: String]) async throws -> (Repository, [String: String]) {
        await progress("检查仓库")
        var remote = try await remote()
        let local = try disk.manifest()
        let desired = try SyncPlanner.merge(baseline: baseline, local: local, remote: remote.files)
        let staging = disk.support.appendingPathComponent("Sync-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var downloads: [String: URL] = [:]
        let needed = desired.keys.filter { desired[$0] != local[$0] }.sorted()
        for (index, key) in needed.enumerated() {
            await progress("下载 \(index + 1)/\(needed.count)")
            guard let sha = desired[key] else { continue }
            let (temporary, response) = try await session.download(for: request("/git/blobs/" + sha, raw: true))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { try check(response, data: Data(contentsOf: temporary)); continue }
            let target = staging.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: temporary, to: target)
            guard (try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= LibraryDisk.maximumPDFSize, try GitHash.file(target) == sha else { throw PaperError.message("下载校验失败，请重试。") }
            if key.lowercased().hasSuffix(".pdf"), PDFDocument(url: target) == nil { throw PaperError.message("仓库中的 PDF 无法打开：\(key)。暂不支持 Git LFS 指针文件。") }
            downloads[key] = target
        }
        // Never publish from a stale local snapshot (e.g. a PDF edited through Files).
        guard try disk.manifest() == local else { throw PaperError.message("同步期间本地文件有更改，请重新同步。") }
        if desired != remote.files {
            if remote.head == nil, let first = desired.keys.sorted().first {
                // GitHub cannot create Git database objects in a completely empty repo.
                await progress("初始化仓库")
                let initialPath = first.split(separator: "/").prefix(2).joined(separator: "/") + "/.gitkeep"
                let encoded = initialPath.split(separator: "/").map { pathComponent(String($0)) }.joined(separator: "/")
                _ = try await json("/contents/" + encoded, method: "PUT", body: ["message": "PaperRep: initialize library", "content": "", "branch": remote.branch])
                remote = try await self.remote()
                guard remote.files == [initialPath: GitHash.blob(Data())] else { throw PaperError.message("仓库刚刚有其他更改，请重试同步。本地文件已保留。") }
            }
            var entries: [[String: Any]] = []
            let changes = Set(desired.keys).union(remote.files.keys).filter { desired[$0] != remote.files[$0] }.sorted()
            for (index, key) in changes.enumerated() {
                if let hash = desired[key] {
                    await progress("上传 \(index + 1)/\(changes.count)")
                    _ = try await uploadBlob(disk.url(key), expected: hash)
                    entries.append(["path": key, "mode": "100644", "type": "blob", "sha": hash])
                } else { entries.append(["path": key, "mode": "100644", "type": "blob", "sha": NSNull()]) }
            }
            if !entries.isEmpty {
                guard let baseTree = remote.tree, let parent = remote.head else { throw PaperError.message("仓库尚未初始化。") }
                let tree = try await json("/git/trees", method: "POST", body: ["base_tree": baseTree, "tree": entries])
                guard let treeSHA = tree["sha"] as? String else { throw PaperError.message("无法生成同步目录。") }
                let commit = try await json("/git/commits", method: "POST", body: ["message": "PaperRep iOS: update library", "tree": treeSHA, "parents": [parent]])
                guard let commitSHA = commit["sha"] as? String else { throw PaperError.message("无法保存同步版本。") }
                await progress("确认同步")
                guard try disk.manifest() == local else { throw PaperError.message("同步期间本地文件有更改，请重新同步。") }
                // No force update: a concurrent desktop push makes this fail safely.
                _ = try await json("/git/refs/heads/" + pathComponent(remote.branch), method: "PATCH", body: ["sha": commitSHA, "force": false])
            }
        }
        guard try disk.manifest() == local else { throw PaperError.message("本地文件已改变，下次同步将继续处理。") }
        await progress("保存文件")
        try disk.apply(desired: desired, local: local, downloads: downloads)
        var resolved = repository; resolved.branch = remote.branch
        return (resolved, desired)
    }
    static func message(_ error: Error) -> String {
        if let failure = error as? GitHubFailure {
            if failure.message.localizedCaseInsensitiveContains("rate limit") { return "GitHub 请求过于频繁，请稍后重试。" }
            switch failure.status {
            case 401, 403, 404: return "无法访问仓库，请检查令牌和仓库读写权限。"
            case 409, 422: return "远程仓库已更新，请重试同步。本地文件已保留。"
            case 429: return "GitHub 请求过于频繁，请稍后重试。"
            default: return "GitHub 暂时不可用，请稍后重试。"
            }
        }
        if let failure = error as? URLError {
            return failure.code == .cancelled ? "同步已中断，本地文件已保留。" : "网络连接失败，本地文件已保留。"
        }
        return error.localizedDescription
    }
}
