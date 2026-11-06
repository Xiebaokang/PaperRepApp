import Foundation
import CryptoKit

enum PaperError: LocalizedError, Equatable {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum RepositoryService: String, Codable, Sendable {
    case github, gitee
    var host: String { self == .gitee ? "gitee.com" : "github.com" }
    var title: String { self == .gitee ? "Gitee" : "GitHub" }
}

struct Repository: Codable, Equatable, Sendable {
    var owner: String
    var name: String
    var branch: String
    var service: RepositoryService? = nil
    var provider: RepositoryService { service ?? .github }
    var credentialKey: String { "\(provider.host)/\(owner.lowercased())/\(name.lowercased())" }
    var identity: String { credentialKey + "/" + branch }
    var address: String { "https://\(provider.host)/\(owner)/\(name).git" }
    static func parse(_ address: String, branch: String = "") throws -> Repository {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider: RepositoryService = value.hasPrefix("https://gitee.com/") || value.hasPrefix("git@gitee.com:") ? .gitee : .github
        for prefix in ["https://" + provider.host + "/", "git@" + provider.host + ":"] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        if value.hasSuffix(".git") { value.removeLast(4) }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { throw PaperError.message("请输入有效的 GitHub 或 Gitee 仓库地址。") }
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.contains(".."), !branch.contains("@{"), !branch.hasPrefix("/"), !branch.hasSuffix("/"), !branch.contains("//"), !branch.contains("\\"), !branch.contains(" "), !branch.hasSuffix(".lock"), !branch.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw PaperError.message("分支名称无效。") }
        return Repository(owner: String(parts[0]), name: String(parts[1]), branch: branch, service: provider)
    }
}

struct Paper: Identifiable, Hashable, Sendable {
    let id: String
    let size: Int64
    let date: Date
    var filename: String { (id as NSString).lastPathComponent }
    var name: String { (filename as NSString).deletingPathExtension }
    var month: String { id.split(separator: "/").prefix(2).joined(separator: "/") }
}

struct LibraryFolder: Identifiable, Hashable, Sendable {
    let id: String
    let date: Date
    let count: Int
    var isYear: Bool { !id.contains("/") }
    var title: String { String(id.split(separator: "/").last!) + (isYear ? " 年" : " 月") }
}

struct LibrarySnapshot: Sendable {
    var papers: [Paper] = []
    var folders: [LibraryFolder] = []
}

struct SyncState: Codable, Sendable {
    var repository: Repository?
    var baseline: [String: String] = [:]
    var lastSync: Date?
}

enum LibraryPath {
    static func isYear(_ value: String) -> Bool { value.range(of: #"^[0-9]{4}$"#, options: .regularExpression) != nil }
    static func isMonth(_ value: String) -> Bool { value.range(of: #"^[0-9]{4}/(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil }
    static func managed(_ value: String) -> Bool {
        let p = value.split(separator: "/", omittingEmptySubsequences: false)
        guard p.count == 3, isMonth(p.prefix(2).joined(separator: "/")), !p[2].contains("\\"), !p[2].contains("\0") else { return false }
        return p[2] == ".gitkeep" || p[2].lowercased().hasSuffix(".pdf")
    }
    static func validFilename(_ name: String) -> Bool {
        guard name.lowercased().hasSuffix(".pdf"), name.count > 4, !name.contains("/"), !name.contains("\\"), name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }), name.rangeOfCharacter(from: CharacterSet(charactersIn: "<>:\"|?*")) == nil else { return false }
        return name.range(of: #"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\."#, options: [.regularExpression, .caseInsensitive]) == nil
    }
    static func month(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d/%02d", c.year!, c.month!)
    }
}

enum GitHash {
    static func blob(_ data: Data) -> String {
        var h = Insecure.SHA1(); h.update(data: Data("blob \(data.count)\0".utf8)); h.update(data: data)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func file(_ url: URL) throws -> String {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var h = Insecure.SHA1(); h.update(data: Data("blob \(size)\0".utf8))
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { h.update(data: data) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum SyncPlanner {
    static func merge(baseline: [String: String], local: [String: String], remote: [String: String]) throws -> [String: String] {
        var result: [String: String] = [:], conflicts: [String] = []
        for path in Set(baseline.keys).union(local.keys).union(remote.keys).sorted() {
            let b = baseline[path], l = local[path], r = remote[path]
            if l == b { result[path] = r }
            else if r == b || l == r { result[path] = l }
            else { conflicts.append((path as NSString).lastPathComponent) }
        }
        guard conflicts.isEmpty else { throw PaperError.message("这些文件在两端均有更改，本地版本已保留：\n" + conflicts.prefix(5).joined(separator: "\n")) }
        // A year/month directory must never contain names that collide on Windows/macOS.
        let normalized = result.keys.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        guard Set(normalized).count == normalized.count else { throw PaperError.message("仓库存在跨平台同名文件，请修改文件名后重试。") }
        return result
    }
}
