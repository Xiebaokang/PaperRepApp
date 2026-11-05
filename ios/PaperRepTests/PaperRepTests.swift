import XCTest
import PDFKit
@testable import PaperRepIOS

final class PaperRepTests: XCTestCase {
    var base: URL!
    var disk: LibraryDisk!
    func testHostUsesIsolatedLibrary() {
        XCTAssertTrue(ProcessInfo.processInfo.arguments.contains("--ui-testing"), "Tests must not initialize the production library or its GitHub connection")
    }
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        disk = LibraryDisk(root: base.appendingPathComponent("Library"), support: base.appendingPathComponent("Support"))
        try disk.initialize()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    private func pdf(_ name: String) throws -> URL {
        let url = base.appendingPathComponent(name)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        try renderer.pdfData { c in c.beginPage(); ("PaperRep PDF test" as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 14)]) }.write(to: url)
        return url
    }
    func testGitBlobHashesMatchGit() throws {
        XCTAssertEqual(GitHash.blob(Data()), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
        XCTAssertEqual(GitHash.blob(Data("hello\n".utf8)), "ce013625030ba8dba906f756967f9e9ca394464a")
        let file = base.appendingPathComponent("hash"); try Data("hello\n".utf8).write(to: file)
        XCTAssertEqual(try GitHash.file(file), GitHash.blob(Data("hello\n".utf8)))
    }
    func testRepositoryAndPathValidation() throws {
        XCTAssertEqual(try Repository.parse("https://github.com/you/papers.git").name, "papers")
        XCTAssertThrowsError(try Repository.parse("https://evil.example/you/papers"))
        XCTAssertThrowsError(try Repository.parse("you/../papers"))
        XCTAssertFalse(LibraryPath.managed("2026/11/../../secret.pdf"))
        XCTAssertFalse(LibraryPath.managed("2026/13/file.pdf"))
        XCTAssertFalse(LibraryPath.validFilename("CON.pdf"))
        XCTAssertFalse(LibraryPath.validFilename("bad:name.pdf"))
        XCTAssertTrue(LibraryPath.managed("2026/11/论文.pdf"))
        XCTAssertThrowsError(try disk.makeMonth("2026/13"))
    }
    func testThreeWayMergeKeepsIndependentChangesAndRemoteDeletion() throws {
        let base = ["2026/11/a.pdf": "a", "2026/11/b.pdf": "b", "2026/11/c.pdf": "c"]
        let local = ["2026/11/a.pdf": "edited", "2026/11/b.pdf": "b", "2026/11/c.pdf": "c"]
        let remote = ["2026/11/a.pdf": "a", "2026/11/b.pdf": "b", "2025/01/new.pdf": "new"]
        let merged = try SyncPlanner.merge(baseline: base, local: local, remote: remote)
        XCTAssertEqual(merged["2026/11/a.pdf"], "edited"); XCTAssertEqual(merged["2025/01/new.pdf"], "new"); XCTAssertNil(merged["2026/11/c.pdf"])
    }
    func testConcurrentEditsAndDeleteVersusEditConflict() throws {
        XCTAssertThrowsError(try SyncPlanner.merge(baseline: ["2026/11/a.pdf": "base"], local: ["2026/11/a.pdf": "local"], remote: ["2026/11/a.pdf": "remote"]))
        XCTAssertThrowsError(try SyncPlanner.merge(baseline: ["2026/11/a.pdf": "base"], local: [:], remote: ["2026/11/a.pdf": "edited"]))
        XCTAssertThrowsError(try SyncPlanner.merge(baseline: [:], local: ["2026/11/A.pdf": "a"], remote: ["2026/11/a.pdf": "b"]))
    }
    func testImportMovesSourcesAndCreatesMonthAndManifest() throws {
        let source = try pdf("论文.pdf")
        let result = try disk.importFiles([source], month: "2026/11")
        XCTAssertEqual(result.retainedSources, 0); XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try disk.scan().papers.first?.name, "论文")
        XCTAssertEqual(try disk.scan().folders.count, 2)
        XCTAssertEqual(try disk.manifest().count, 2)
    }
    func testInvalidBatchPreservesAllSourcesAndRefusesSameName() throws {
        let good = try pdf("good.pdf"), bad = base.appendingPathComponent("bad.pdf")
        try Data("invalid".utf8).write(to: bad)
        XCTAssertThrowsError(try disk.importFiles([good, bad], month: "2026/11"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: good.path)); XCTAssertEqual(try disk.scan().papers.count, 0)
        _ = try disk.importFiles([good], month: "2026/11")
        let duplicate = try pdf("GOOD.pdf")
        XCTAssertThrowsError(try disk.importFiles([duplicate], month: "2026/11"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicate.path))
    }
    func testTrashAndRestoreYear() throws {
        _ = try disk.importFiles([pdf("paper.pdf")], month: "2026/11")
        let moved = try disk.trash(["2026", "2026/11/paper.pdf"])
        XCTAssertEqual(moved.count, 1); XCTAssertEqual(try disk.scan().papers.count, 0)
        try disk.restore(moved)
        XCTAssertEqual(try disk.scan().papers.count, 1)
    }
    func testRemoteApplyRollsBackIfDownloadedFileCannotBeInstalled() throws {
        _ = try disk.importFiles([pdf("paper.pdf")], month: "2026/11")
        let original = try Data(contentsOf: disk.url("2026/11/paper.pdf")), manifest = try disk.manifest()
        var desired = manifest; desired["2026/11/paper.pdf"] = "replacement"
        XCTAssertThrowsError(try disk.apply(desired: desired, local: manifest, downloads: ["2026/11/paper.pdf": base.appendingPathComponent("missing")]))
        XCTAssertEqual(try Data(contentsOf: disk.url("2026/11/paper.pdf")), original)
    }
    @MainActor func testPDFAnnotationSaveRemainsReadable() throws {
        let source = try pdf("annotations.pdf")
        let model = ReaderModel(url: source, id: "test")
        let view = PDFView(); view.document = model.document; model.attach(view)
        model.note("A useful result")
        view.setCurrentSelection(model.document?.findString("PaperRep", withOptions: []).first, animate: false)
        model.highlight()
        XCTAssertTrue(model.dirty)
        try model.save()
        XCTAssertFalse(model.dirty)
        XCTAssertEqual(PDFDocument(url: source)?.page(at: 0)?.annotations.first?.contents, "A useful result")
        XCTAssertTrue(PDFDocument(url: source)?.page(at: 0)?.annotations.contains(where: { $0.type == "Highlight" }) == true)
        model.detach()
    }
}
