import XCTest
import PDFKit
@testable import PaperRepIOS

private final class GiteeProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class GiteeSyncTests: XCTestCase {
    func testGiteeValidationErrorReportsStageAndStatusWithoutToken() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base); GiteeProtocol.handler = nil }
        let disk = LibraryDisk(root: base.appendingPathComponent("Library"), support: base.appendingPathComponent("Support"))
        try disk.initialize()
        GiteeProtocol.handler = { _ in
            (400, try JSONSerialization.data(withJSONObject: ["messages": ["content is empty", "secret-test-token", "https://gitee.com/?access_token=secret-test-token"]]))
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [GiteeProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let service = GiteeSync(disk: disk, repository: try Repository.parse("https://gitee.com/you/papers"), token: "secret-test-token", session: session) { _ in }
        do { _ = try await service.synchronize(baseline: [:]); XCTFail("Expected validation error") }
        catch {
            let message = GitHubSync.message(error)
            XCTAssertTrue(message.contains("HTTP 400")); XCTAssertTrue(message.contains("读取仓库"))
            XCTAssertTrue(message.contains("content is empty")); XCTAssertFalse(message.contains("secret-test-token")); XCTAssertFalse(message.contains("https://"))
        }
    }
    func testProviderParsingAndLegacySettings() throws {
        let old = Data(#"{"owner":"you","name":"papers","branch":"main"}"#.utf8)
        let github = try JSONDecoder().decode(Repository.self, from: old)
        XCTAssertEqual(github.provider, .github)
        let gitee = try Repository.parse("https://gitee.com/you/papers.git")
        XCTAssertEqual(gitee.provider, .gitee)
        XCTAssertNotEqual(gitee.credentialKey, github.credentialKey)
        XCTAssertEqual(try Repository.parse("git@gitee.com:you/papers.git").address, gitee.address)
        XCTAssertThrowsError(try Repository.parse("https://gitee.com.evil.test/you/papers"))
    }
    func testEmptyRepositoryInitializationAndMissingBranchProtection() async throws {
        for empty in [true, false] {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: base); GiteeProtocol.handler = nil }
            let disk = LibraryDisk(root: base.appendingPathComponent("Library"), support: base.appendingPathComponent("Support"))
            try disk.initialize(); try disk.makeMonth("2026/11")
            var created = false
            GiteeProtocol.handler = { request in
                let path = request.url!.path
                func response(_ value: Any, _ status: Int = 200) throws -> (Int, Data) { (status, try JSONSerialization.data(withJSONObject: value)) }
                if path.hasSuffix("/papers") { return try response(["default_branch": NSNull()]) }
                if path.contains("/git/trees/") {
                    if !created { return try response(["message": "Tree not found"], 404) }
                    return try response(["tree": [["path": "2026/11/.gitkeep", "mode": "100644", "type": "blob", "sha": GitHash.blob(Data("\n".utf8))]]])
                }
                if path.hasSuffix("/commits") {
                    return empty ? try response(["message": "Repository is empty"], 404) : try response([["sha": "existing"]])
                }
                XCTAssertTrue(empty); XCTAssertEqual(request.httpMethod, "POST")
                var body = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
                    while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(contentsOf: buffer.prefix(n)) }
                }
                let json = try JSONSerialization.jsonObject(with: body) as! [String: String]
                guard let content = json["content"], let bytes = Data(base64Encoded: content), !bytes.isEmpty else {
                    return try response(["messages": ["content is empty"]], 400)
                }
                XCTAssertEqual(bytes, Data("\n".utf8))
                created = true; return try response([:], 201)
            }
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [GiteeProtocol.self]
            let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
            let service = GiteeSync(disk: disk, repository: try Repository.parse("https://gitee.com/you/papers"), token: "fake", session: session) { _ in }
            do {
                let (repository, result) = try await service.synchronize(baseline: [:])
                XCTAssertTrue(empty); XCTAssertTrue(created); XCTAssertEqual(repository.branch, "master"); XCTAssertEqual(result, try disk.manifest())
            } catch { XCTAssertFalse(empty); XCTAssertFalse(created) }
        }
    }
    func testGiteeCreateUpdateDeleteDownloadAndInterruptedRetry() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base); GiteeProtocol.handler = nil }
        let disk = LibraryDisk(root: base.appendingPathComponent("Library"), support: base.appendingPathComponent("Support"))
        try disk.initialize(); try disk.makeMonth("2026/11")
        func pdf(_ text: String) -> Data {
            UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 300)).pdfData { context in
                context.beginPage(); (text as NSString).draw(at: CGPoint(x: 10, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
            }
        }
        let edited = pdf("edited"), downloaded = pdf("cloud"), old = pdf("old")
        try edited.write(to: disk.url("2026/11/a.pdf"))
        try edited.write(to: disk.url("2026/11/b.pdf"))
        var cloud = ["2026/11/a.pdf": old, "2026/11/delete.pdf": old, "2026/11/cloud.pdf": downloaded]
        var baseline = cloud.mapValues(GitHash.blob)
        baseline.removeValue(forKey: "2026/11/cloud.pdf")
        var fail = true, writes: [String] = []
        GiteeProtocol.handler = { request in
            XCTAssertEqual(request.url!.host, "gitee.com")
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["access_token"], "fake-gitee-token")
            let route = request.url!.path.replacingOccurrences(of: "/api/v5/repos/you/papers", with: "")
            func response(_ value: Any, _ status: Int = 200) throws -> (Int, Data) { (status, try JSONSerialization.data(withJSONObject: value)) }
            if route.isEmpty { return try response(["default_branch": "master", "empty": false]) }
            if route == "/git/trees/master" {
                XCTAssertEqual(query["recursive"], "1")
                let tree = cloud.map { ["path": $0.key, "type": "blob", "mode": "100644", "sha": GitHash.blob($0.value), "size": $0.value.count] as [String: Any] }
                return try response(["tree": tree, "truncated": false])
            }
            if route.hasPrefix("/git/blobs/") {
                let sha = String(route.split(separator: "/").last!)
                return try response(["encoding": "base64", "content": cloud.values.first { GitHash.blob($0) == sha }!.base64EncodedString()])
            }
            let key = String(route.dropFirst("/contents/".count))
            if fail && key.hasSuffix("b.pdf") { return try response(["message": "interrupted"], 503) }
            var bodyData = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
                while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bodyData.append(contentsOf: buffer.prefix(count)) }
            }
            let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: String] ?? [:]
            if request.httpMethod == "DELETE" {
                XCTAssertEqual(query["sha"], cloud[key].map(GitHash.blob)); cloud[key] = nil
            } else {
                XCTAssertEqual(body["branch"], "master")
                XCTAssertEqual(request.httpMethod, cloud[key] == nil ? "POST" : "PUT")
                XCTAssertEqual(body["sha"], cloud[key].map(GitHash.blob))
                cloud[key] = Data(base64Encoded: body["content"]!)!
            }
            writes.append(key); return try response([:])
        }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [GiteeProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let service = GiteeSync(disk: disk, repository: try Repository.parse("https://gitee.com/you/papers"), token: "fake-gitee-token", session: session) { _ in }
        do { _ = try await service.synchronize(baseline: baseline); XCTFail("Expected interrupted upload") } catch {}
        XCTAssertEqual(try Data(contentsOf: disk.url("2026/11/a.pdf")), edited)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try disk.url("2026/11/cloud.pdf").path))
        fail = false
        let (resolved, result) = try await service.synchronize(baseline: baseline)
        XCTAssertEqual(resolved.branch, "master")
        XCTAssertEqual(result, try disk.manifest())
        XCTAssertEqual(try Data(contentsOf: disk.url("2026/11/cloud.pdf")), downloaded)
        XCTAssertNil(cloud["2026/11/delete.pdf"])
        XCTAssertEqual(writes.filter { $0 == "2026/11/a.pdf" }.count, 1)
    }
}
