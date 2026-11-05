import XCTest

final class PaperRepUITests: XCTestCase {
    func testBrowseSearchReaderAndMonthCreation() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--seed-papers"]; app.launch()
        XCTAssertTrue(app.navigationBars["我的论文"].waitForExistence(timeout: 15))
        app.buttons["所有论文"].firstMatch.tap()
        let paper = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Attention Is All You Need")).firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 5)); paper.tap()
        XCTAssertTrue(app.buttons["pdf-page-count"].waitForExistence(timeout: 5))
        app.buttons["下一页"].tap()
        XCTAssertTrue(app.buttons["pdf-page-count"].label.contains("2 / 3"))
        app.buttons["搜索 PDF"].tap()
        let search = app.textFields["pdf-search"]; XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Attention")
        app.buttons["完成"].firstMatch.tap()
        let librarySearch = app.searchFields.firstMatch
        librarySearch.tap(); librarySearch.typeText("Learning")
        XCTAssertTrue(paper.waitForNonExistence(timeout: 5))
        librarySearch.buttons.firstMatch.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        if cancel.exists { cancel.tap() }
        XCTAssertTrue(paper.waitForExistence(timeout: 5))
        app.buttons["多选"].tap(); paper.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Retrieval-Augmented Generation")).firstMatch.tap()
        app.buttons["删除选中项目"].tap(); app.buttons["删除"].firstMatch.tap()
        XCTAssertTrue(paper.waitForNonExistence(timeout: 5))
        app.buttons["撤销删除"].tap(); XCTAssertTrue(paper.waitForExistence(timeout: 5))
        app.buttons["完成选择"].tap()
        app.buttons["文件夹"].firstMatch.tap()
        app.buttons["更多"].tap(); app.buttons["新建文件夹"].tap()
        XCTAssertTrue(app.navigationBars["新建文件夹"].waitForExistence(timeout: 5))
        app.buttons["创建"].tap()
        XCTAssertTrue(app.navigationBars["我的论文"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "iPhone library"; shot.lifetime = .keepAlways; add(shot)
    }
}
