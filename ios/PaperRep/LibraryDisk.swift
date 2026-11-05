import Foundation
import PDFKit

struct ImportResult: Sendable {
    var retainedSources: Int
}
struct TrashedItem: Sendable { var original: String; var stored: URL }

struct LibraryDisk: Sendable {
    static let maximumPDFSize = 95 * 1024 * 1024
    let root: URL
    let support: URL
    private var fm: FileManager { .default }
    var stateURL: URL { support.appendingPathComponent("sync.json") }
    init(root: URL? = nil, support: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Library", isDirectory: true)
        self.support = support ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PaperRep", isDirectory: true)
    }
    func initialize() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
    }
    func loadState() throws -> SyncState { fm.fileExists(atPath: stateURL.path) ? try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: stateURL)) : SyncState() }
    func saveState(_ state: SyncState) throws { try JSONEncoder().encode(state).write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    func url(_ relative: String) throws -> URL {
        guard LibraryPath.managed(relative) || LibraryPath.isYear(relative) || LibraryPath.isMonth(relative) else { throw PaperError.message("文件路径无效。") }
        var current = root
        for part in relative.split(separator: "/") {
            current.appendPathComponent(String(part))
            if fm.fileExists(atPath: current.path), try current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw PaperError.message("不支持符号链接。") }
        }
        return current
    }
    func scan() throws -> LibrarySnapshot {
        var snapshot = LibrarySnapshot()
        for year in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]) {
            let y = try year.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard LibraryPath.isYear(year.lastPathComponent), y.isDirectory == true, y.isSymbolicLink != true else { continue }
            var yearCount = 0
            for month in try fm.contentsOfDirectory(at: year, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]) {
                let id = year.lastPathComponent + "/" + month.lastPathComponent
                let m = try month.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
                guard LibraryPath.isMonth(id), m.isDirectory == true, m.isSymbolicLink != true else { continue }
                var count = 0
                for file in try fm.contentsOfDirectory(at: month, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) where file.pathExtension.lowercased() == "pdf" {
                    let value = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                    guard value.isRegularFile == true, value.isSymbolicLink != true else { continue }
                    snapshot.papers.append(Paper(id: id + "/" + file.lastPathComponent, size: Int64(value.fileSize ?? 0), date: value.contentModificationDate ?? .distantPast)); count += 1
                }
                yearCount += count
                snapshot.folders.append(LibraryFolder(id: id, date: m.contentModificationDate ?? .distantPast, count: count))
            }
            snapshot.folders.append(LibraryFolder(id: year.lastPathComponent, date: y.contentModificationDate ?? .distantPast, count: yearCount))
        }
        return snapshot
    }
    func manifest() throws -> [String: String] {
        let snapshot = try scan()
        var files: [String: String] = [:]
        for p in snapshot.papers { files[p.id] = try GitHash.file(url(p.id)) }
        for folder in snapshot.folders where !folder.isYear {
            let key = folder.id + "/.gitkeep", file = try url(key)
            if fm.fileExists(atPath: file.path) { files[key] = try GitHash.file(file) }
        }
        return files
    }
    func makeMonth(_ month: String) throws {
        guard LibraryPath.isMonth(month) else { throw PaperError.message("请选择有效年月。") }
        let folder = try url(month); try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent(".gitkeep"), options: .atomic)
    }
    func importFiles(_ sources: [URL], month: String) throws -> ImportResult {
        guard !sources.isEmpty, sources.count <= 500 else { throw PaperError.message("请选择 PDF 文件。") }
        guard LibraryPath.isMonth(month) else { throw PaperError.message("请选择有效年月。") }
        let staging = support.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let destination = try url(month)
        var names = Set((try? fm.contentsOfDirectory(atPath: destination.path))?.map { $0.precomposedStringWithCanonicalMapping.lowercased() } ?? [])
        var planned: [(source: URL, temporary: URL, target: URL, hash: String)] = []
        var active: [URL] = []
        defer { active.forEach { $0.stopAccessingSecurityScopedResource() } }
        for source in sources {
            if source.startAccessingSecurityScopedResource() { active.append(source) }
            let name = source.lastPathComponent
            guard LibraryPath.validFilename(name) else { throw PaperError.message("文件名无法跨平台使用：\(name)") }
            let normalized = name.precomposedStringWithCanonicalMapping.lowercased()
            guard names.insert(normalized).inserted else { throw PaperError.message("目标月份已有同名论文：\(name)") }
            let resolved = source.resolvingSymlinksInPath().standardizedFileURL
            guard !resolved.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw PaperError.message("论文已在资料库中。") }
            let temporary = staging.appendingPathComponent(name)
            var coordinationError: NSError?, copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
                do {
                    let values = try coordinated.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= Self.maximumPDFSize else { throw PaperError.message("仅支持不超过 95 MB 的 PDF 文件。") }
                    try fm.copyItem(at: coordinated, to: temporary)
                } catch { copyError = error }
            }
            if let error = coordinationError ?? copyError as NSError? { throw error }
            guard let document = PDFDocument(url: temporary), document.pageCount > 0 || document.isLocked else { throw PaperError.message("PDF 无法打开：\(name)") }
            planned.append((source, temporary, destination.appendingPathComponent(name), try GitHash.file(temporary)))
        }
        try makeMonth(month)
        var installed: [URL] = []
        do { for item in planned { try fm.moveItem(at: item.temporary, to: item.target); installed.append(item.target) } }
        catch { installed.forEach { try? fm.removeItem(at: $0) }; throw error }
        var retained = 0
        for item in planned {
            var coordinationError: NSError?, removeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: item.source, options: .forDeleting, error: &coordinationError) { coordinated in
                do {
                    guard try GitHash.file(coordinated) == item.hash else { throw PaperError.message("源文件已改变。") }
                    try fm.removeItem(at: coordinated)
                } catch { removeError = error }
            }
            if coordinationError != nil || removeError != nil { retained += 1 }
        }
        return ImportResult(retainedSources: retained)
    }
    func trash(_ ids: Set<String>) throws -> [TrashedItem] {
        let top = ids.filter { item in !ids.contains(where: { item != $0 && item.hasPrefix($0 + "/") }) }
        let folder = support.appendingPathComponent("Trash/" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var moved: [TrashedItem] = []
        do {
            for id in top.sorted() {
                let stored = folder.appendingPathComponent(UUID().uuidString)
                try fm.moveItem(at: url(id), to: stored)
                moved.append(TrashedItem(original: id, stored: stored))
            }
        } catch { try? restore(moved); throw error }
        return moved
    }
    func restore(_ items: [TrashedItem]) throws {
        for item in items {
            let target = try url(item.original)
            guard !fm.fileExists(atPath: target.path) else { throw PaperError.message("同名文件已存在，无法撤销。") }
        }
        var restored: [(target: URL, stored: URL)] = []
        do {
            for item in items {
                let target = try url(item.original)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: item.stored, to: target); restored.append((target, item.stored))
            }
        } catch { for item in restored.reversed() { try? fm.moveItem(at: item.target, to: item.stored) }; throw error }
    }
    func apply(desired: [String: String], local: [String: String], downloads: [String: URL]) throws {
        var backups: [TrashedItem] = [], installed: [URL] = []
        do {
            // Keep replaced/deleted versions in the app's trash as a recovery copy.
            for key in local.keys.sorted() where desired[key] != local[key] { backups += try trash([key]) }
            for (key, temporary) in downloads {
                let target = try url(key)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: temporary, to: target); installed.append(target)
            }
        } catch {
            installed.forEach { try? fm.removeItem(at: $0) }
            try? restore(backups)
            throw error
        }
        for folder in try scan().folders.sorted(by: { $0.id.count > $1.id.count }) {
            let path = try url(folder.id)
            if try fm.contentsOfDirectory(atPath: path.path).isEmpty { try fm.removeItem(at: path) }
        }
    }
}
