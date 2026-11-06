import Foundation
import PDFKit

/// Gitee v5 has read-only Git database APIs. Writes use Contents with blob-SHA checks.
actor GiteeSync {
    let disk: LibraryDisk
    let repository: Repository
    let token: String
    let session: URLSession
    let progress: @Sendable (String) async -> Void
    init(disk: LibraryDisk, repository: Repository, token: String, session: URLSession = .shared, progress: @escaping @Sendable (String) async -> Void) {
        self.disk = disk; self.repository = repository; self.token = token; self.session = session; self.progress = progress
    }
    private func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
    private func request(_ path: String, method: String = "GET", query: [String: String] = [:]) -> URLRequest {
        var url = URLComponents(string: "https://gitee.com/api/v5/repos/\(repository.owner)/\(repository.name)" + path)!
        url.queryItems = (query.merging(["access_token": token]) { _, new in new }).sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: url.url!, timeoutInterval: 900)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("PaperRep-iOS", forHTTPHeaderField: "User-Agent")
        return req
    }
    private func decode(_ data: Data, _ response: URLResponse) throws -> Any {
        guard let http = response as? HTTPURLResponse else { throw PaperError.message("仓库响应无效。") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? "Gitee 请求失败"
            if http.statusCode == 413 { throw PaperError.message("文件超过 Gitee 接口限制，本地文件已保留。") }
            throw GitHubFailure(status: http.statusCode, message: message)
        }
        return try JSONSerialization.jsonObject(with: data)
    }
    private func get(_ path: String, query: [String: String] = [:]) async throws -> Any {
        let (data, response) = try await session.data(for: request(path, query: query))
        return try decode(data, response)
    }
    private func files(branch: String, empty: Bool = false) async throws -> [String: String] {
        if empty { return [:] }
        let object: Any
        do { object = try await get("/git/trees/" + encoded(branch), query: ["recursive": "1"]) }
        catch let error as GitHubFailure where error.status == 404 || error.status == 409 || error.status == 422 {
            // A missing custom branch must not be mistaken for an empty repository.
            do {
                if let commits = try await get("/commits", query: ["per_page": "1"]) as? [Any], commits.isEmpty { return [:] }
            } catch let failure as GitHubFailure where (failure.status == 404 || failure.status == 409) && failure.message.localizedCaseInsensitiveContains("repository is empty") {
                return [:]
            }
            throw PaperError.message("找不到所选分支，请检查分支名称。")
        }
        guard let tree = object as? [String: Any], let entries = tree["tree"] as? [[String: Any]], tree["truncated"] as? Bool != true else { throw PaperError.message("无法完整读取 Gitee 仓库目录。") }
        var result: [String: String] = [:]
        for entry in entries {
            guard let path = entry["path"] as? String, LibraryPath.managed(path) else { continue }
            guard entry["type"] as? String == "blob", ["100644", "100755"].contains(entry["mode"] as? String ?? ""), let sha = entry["sha"] as? String,
                  (entry["size"] as? Int ?? 0) <= LibraryDisk.maximumPDFSize,
                  path.hasSuffix("/.gitkeep") || LibraryPath.validFilename((path as NSString).lastPathComponent) else { throw PaperError.message("仓库包含不支持的文件：\(path)") }
            result[path] = sha
        }
        return result
    }
    private func write(_ path: String, branch: String, old: String?, file: URL?) async throws {
        let route = "/contents/" + path.split(separator: "/").map { encoded(String($0)) }.joined(separator: "/")
        var fields = ["branch": branch, "message": "PaperRep iOS: update library"]
        if let old { fields["sha"] = old }
        if file == nil {
            let (data, response) = try await session.data(for: request(route, method: "DELETE", query: fields))
            _ = try decode(data, response); return
        }
        // Stream base64 to disk instead of keeping a second full PDF in memory.
        let body = disk.support.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: body) }
        var prefix = try JSONSerialization.data(withJSONObject: fields)
        prefix.removeLast(); prefix.append(contentsOf: Data(",\"content\":\"".utf8))
        try prefix.write(to: body)
        let input = try FileHandle(forReadingFrom: file!), output = try FileHandle(forWritingTo: body)
        defer { try? input.close(); try? output.close() }
        try output.seekToEnd()
        while let chunk = try input.read(upToCount: 48 * 1024), !chunk.isEmpty { try output.write(contentsOf: chunk.base64EncodedData()) }
        try output.write(contentsOf: Data("\"}".utf8)); try output.close()
        let (data, response) = try await session.upload(for: request(route, method: old == nil ? "POST" : "PUT"), fromFile: body)
        _ = try decode(data, response)
    }
    func synchronize(baseline: [String: String]) async throws -> (Repository, [String: String]) {
        await progress("检查 Gitee 仓库")
        guard let info = try await get("") as? [String: Any] else { throw PaperError.message("仓库数据无效。") }
        let branch = repository.branch.isEmpty ? (info["default_branch"] as? String ?? "master") : repository.branch
        var remote = try await files(branch: branch, empty: info["empty"] as? Bool == true)
        let local = try disk.manifest()
        let desired = try SyncPlanner.merge(baseline: baseline, local: local, remote: remote)
        let staging = disk.support.appendingPathComponent("Gitee-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var downloads: [String: URL] = [:]
        for key in desired.keys.sorted() where desired[key] != local[key] {
            await progress("下载论文")
            let sha = desired[key]!
            guard let blob = try await get("/git/blobs/" + encoded(sha)) as? [String: Any], blob["encoding"] as? String == "base64",
                  let content = blob["content"] as? String, content.utf8.count <= LibraryDisk.maximumPDFSize * 2,
                  let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters), data.count <= LibraryDisk.maximumPDFSize, GitHash.blob(data) == sha else { throw PaperError.message("下载校验失败，本地文件已保留。") }
            let file = staging.appendingPathComponent(UUID().uuidString)
            try data.write(to: file)
            if key.lowercased().hasSuffix(".pdf"), PDFDocument(url: file) == nil { throw PaperError.message("仓库中的 PDF 无法打开：\(key)") }
            downloads[key] = file
        }
        let changes = Set(remote.keys).union(desired.keys).filter { remote[$0] != desired[$0] }.sorted()
        for (index, key) in changes.enumerated() {
            guard try disk.manifest() == local else { throw PaperError.message("同步期间本地文件有更改，请重新同步。") }
            await progress("上传 \(index + 1)/\(changes.count)")
            try await write(key, branch: branch, old: remote[key], file: desired[key] == nil ? nil : disk.url(key))
            remote[key] = desired[key]
        }
        // A failed batch leaves local bytes/baseline unchanged. Already committed matching
        // files merge naturally on retry; concurrent edits still produce a conflict.
        guard try await files(branch: branch, empty: remote.isEmpty && info["empty"] as? Bool == true && changes.isEmpty) == desired else { throw PaperError.message("远程仓库已更新，请重新同步。本地文件已保留。") }
        guard try disk.manifest() == local else { throw PaperError.message("同步期间本地文件有更改，请重新同步。") }
        try disk.apply(desired: desired, local: local, downloads: downloads)
        var resolved = repository; resolved.branch = branch
        return (resolved, desired)
    }
}
