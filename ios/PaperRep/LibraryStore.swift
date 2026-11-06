import SwiftUI
import UIKit

@MainActor final class LibraryStore: ObservableObject {
    @Published var snapshot = LibrarySnapshot()
    @Published var syncState = SyncState()
    @Published var busy = false
    @Published var phase = ""
    @Published var error: String?
    @Published var notice: String?
    @Published var undoItems: [TrashedItem] = []
    let disk: LibraryDisk
    private var started = false
    init(disk: LibraryDisk = LibraryDisk()) {
        self.disk = disk
        do { try disk.initialize(); syncState = try disk.loadState(); snapshot = try disk.scan() }
        catch { self.error = error.localizedDescription }
    }
    var connected: Bool { syncState.repository != nil }
    func refresh() { do { snapshot = try disk.scan() } catch { self.error = error.localizedDescription } }
    func startup() async {
        guard !started else { return }; started = true
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
        if connected { await synchronize() }
    }
    private func operation(_ label: String, _ body: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; phase = label; error = nil
        let task = UIApplication.shared.beginBackgroundTask(withName: "PaperRep sync")
        defer {
            busy = false; phase = ""; refresh()
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
        do { try await body() }
        catch { self.error = GitHubSync.message(error) }
    }
    private func syncUnlocked() async throws {
        guard let repo = syncState.repository else { return }
        let token = TokenVault.read(for: repo)
        guard !token.isEmpty else { throw PaperError.message("请在设置中填写仓库访问令牌。") }
        let progress: @Sendable (String) async -> Void = { [weak self] message in await self?.updatePhase(message) }
        let (resolved, baseline): (Repository, [String: String])
        if repo.provider == .gitee {
            (resolved, baseline) = try await GiteeSync(disk: disk, repository: repo, token: token, progress: progress).synchronize(baseline: syncState.baseline)
        } else {
            (resolved, baseline) = try await GitHubSync(disk: disk, repository: repo, token: token, progress: progress).synchronize(baseline: syncState.baseline)
        }
        syncState.repository = resolved; syncState.baseline = baseline; syncState.lastSync = Date()
        try disk.saveState(syncState)
    }
    private func updatePhase(_ message: String) { phase = message }
    func synchronize() async { await operation("同步", syncUnlocked) }
    func configure(address: String, branch: String, token: String) async -> Bool {
        var saved = false
        await operation("连接仓库") {
            var repo = try Repository.parse(address, branch: branch)
            if let existing = syncState.repository {
                if repo.branch.isEmpty && repo.credentialKey == existing.credentialKey { repo.branch = existing.branch }
            }
            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PaperError.message("请输入仓库访问令牌。") }
            var next = syncState
            if syncState.repository?.identity != repo.identity {
                // Start a fresh three-way merge; local files are additions, never old deletions.
                if syncState.repository != nil {
                    try JSONEncoder().encode(syncState).write(to: disk.support.appendingPathComponent("previous-sync.json"), options: .atomic)
                }
                next.baseline = [:]; next.lastSync = nil
            }
            try TokenVault.save(token.trimmingCharacters(in: .whitespacesAndNewlines), for: repo)
            next.repository = repo
            try disk.saveState(next)
            syncState = next
            saved = true
            try await syncUnlocked()
        }
        return saved && error == nil
    }
    func createMonth(_ month: String) async {
        await operation("创建文件夹") { try disk.makeMonth(month); try await syncUnlocked() }
    }
    func importPDFs(_ sources: [URL], month: String) async {
        let disk = self.disk
        await operation("导入论文") {
            let result = try await Task.detached(priority: .userInitiated) { try disk.importFiles(sources, month: month) }.value
            if result.retainedSources > 0 { notice = "\(result.retainedSources) 个源文件无法移除，已保留。" }
            try await syncUnlocked()
        }
    }
    func delete(_ ids: Set<String>) async {
        await operation("删除") { undoItems = try disk.trash(ids); try await syncUnlocked() }
    }
    func undoDelete() async {
        await operation("恢复文件") { try disk.restore(undoItems); undoItems = []; try await syncUnlocked() }
    }
    func savedPDF() async { await operation("保存批注", syncUnlocked) }
}
