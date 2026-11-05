import XCTest
@testable import PaperRepIOS

private final class GitHubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.github.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class GitHubSyncTests: XCTestCase {
    private func object(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
    func testEmptyRepositoryBootstrapAndConcurrentInitializationProtection() async throws {
        for concurrent in [false, true] {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: base); GitHubProtocol.handler = nil }
            let disk = LibraryDisk(root: base.appendingPathComponent("Library"), support: base.appendingPathComponent("Support"))
            try disk.initialize(); try disk.makeMonth("2026/11")
            let data = Data("%PDF local".utf8), hash = GitHash.blob(data)
            try data.write(to: disk.url("2026/11/local.pdf"))
            var initialized = false, patched = false
            GitHubProtocol.handler = { request in
                let path = request.url!.path.replacingOccurrences(of: "/repos/owner/papers", with: "")
                switch (request.httpMethod ?? "GET", path) {
                case ("GET", ""): return (200, try self.object(["default_branch": "main"]))
                case ("GET", "/git/ref/heads/main"):
                    return initialized ? (200, try self.object(["object": ["sha": "initial"]])) : (409, try self.object(["message": "Git Repository is empty."]))
                case ("PUT", "/contents/2026/11/.gitkeep"):
                    XCTAssertEqual(try self.body(request)["content"] as? String, "")
                    initialized = true; return (201, try self.object(["commit": ["sha": "initial"]]))
                case ("GET", "/git/commits/initial"): return (200, try self.object(["tree": ["sha": "initial-tree"]]))
                case ("GET", "/git/trees/initial-tree"):
                    var entries = [["path": "2026/11/.gitkeep", "mode": "100644", "type": "blob", "sha": GitHash.blob(Data())]]
                    if concurrent { entries.append(["path": "2026/11/other-device.pdf", "mode": "100644", "type": "blob", "sha": "other-device"]) }
                    return (200, try self.object(["truncated": false, "tree": entries]))
                case ("POST", "/git/blobs"): return (201, try self.object(["sha": hash]))
                case ("POST", "/git/trees"): return (201, try self.object(["sha": "updated-tree"]))
                case ("POST", "/git/commits"): return (201, try self.object(["sha": "updated-commit"]))
                case ("PATCH", "/git/refs/heads/main"):
                    XCTAssertFalse(concurrent); patched = true; return (200, try self.object(["object": ["sha": "updated-commit"]]))
                default: XCTFail("Unexpected bootstrap request: \(path)"); return (500, Data())
                }
            }
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [GitHubProtocol.self]
            let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
            let service = GitHubSync(disk: disk, repository: Repository(owner: "owner", name: "papers", branch: ""), token: "test", session: session) { _ in }
            do {
                let (_, files) = try await service.synchronize(baseline: [:])
                XCTAssertFalse(concurrent); XCTAssertEqual(files["2026/11/local.pdf"], hash); XCTAssertTrue(patched)
            } catch {
                XCTAssertTrue(concurrent); XCTAssertFalse(patched); XCTAssertTrue(error.localizedDescription.contains("其他更改"))
            }
            XCTAssertEqual(try Data(contentsOf: disk.url("2026/11/local.pdf")), data)
        }
    }
    func testUploadUsesBaseTreeAndNonForceRefUpdateAndPersistsLocalOnRejection() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base); GitHubProtocol.handler = nil }
        let disk = LibraryDisk(root: base.appendingPathComponent("Library"), support: base.appendingPathComponent("Support"))
        try disk.initialize(); try disk.makeMonth("2026/11")
        let file = try disk.url("2026/11/paper.pdf"), newData = Data("%PDF edited".utf8)
        try newData.write(to: file)
        let newSHA = GitHash.blob(newData), oldSHA = GitHash.blob(Data("%PDF old".utf8))
        let emptySHA = GitHash.blob(Data())
        let baseline = ["2026/11/paper.pdf": oldSHA, "2026/11/.gitkeep": emptySHA]
        var methods: [String] = [], reject = false
        GitHubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-token")
            let path = request.url!.path.replacingOccurrences(of: "/repos/owner/papers", with: "")
            let method = request.httpMethod ?? "GET"; methods.append(method + " " + path)
            switch (method, path) {
            case ("GET", ""): return (200, try self.object(["default_branch": "main"]))
            case ("GET", "/git/ref/heads/main"): return (200, try self.object(["object": ["sha": "remote-head"]]))
            case ("GET", "/git/commits/remote-head"): return (200, try self.object(["tree": ["sha": "remote-tree"]]))
            case ("GET", "/git/trees/remote-tree"):
                return (200, try self.object(["truncated": false, "tree": [
                    ["path": "2026/11/paper.pdf", "mode": "100644", "type": "blob", "sha": oldSHA],
                    ["path": "2026/11/.gitkeep", "mode": "100644", "type": "blob", "sha": emptySHA],
                    ["path": "README.md", "mode": "100644", "type": "blob", "sha": "unmanaged"]]]))
            case ("POST", "/git/blobs"): return (201, try self.object(["sha": newSHA]))
            case ("POST", "/git/trees"):
                let body = try self.body(request)
                XCTAssertEqual(body["base_tree"] as? String, "remote-tree")
                let entries = try XCTUnwrap(body["tree"] as? [[String: Any]])
                XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries.first?["path"] as? String, "2026/11/paper.pdf")
                return (201, try self.object(["sha": "new-tree"]))
            case ("POST", "/git/commits"):
                XCTAssertEqual(try self.body(request)["parents"] as? [String], ["remote-head"])
                return (201, try self.object(["sha": "new-commit"]))
            case ("PATCH", "/git/refs/heads/main"):
                XCTAssertEqual(try self.body(request)["force"] as? Bool, false)
                return reject ? (422, try self.object(["message": "not a fast forward"])) : (200, try self.object(["object": ["sha": "new-commit"]]))
            default: XCTFail("Unexpected request: \(method) \(path)"); return (500, Data())
            }
        }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [GitHubProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let service = GitHubSync(disk: disk, repository: Repository(owner: "owner", name: "papers", branch: "main"), token: "unit-test-token", session: session) { _ in }
        let (_, updated) = try await service.synchronize(baseline: baseline)
        XCTAssertEqual(updated["2026/11/paper.pdf"], newSHA)
        XCTAssertEqual(try Data(contentsOf: file), newData)
        XCTAssertTrue(methods.contains("PATCH /git/refs/heads/main"))
        reject = true
        do { _ = try await service.synchronize(baseline: baseline); XCTFail("Expected non-fast-forward rejection") }
        catch { XCTAssertTrue(GitHubSync.message(error).contains("远程仓库已更新")) }
        XCTAssertEqual(try Data(contentsOf: file), newData)
    }
}
