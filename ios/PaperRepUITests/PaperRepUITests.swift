import XCTest

final class PaperRepUITests: XCTestCase {
    func testBrowseSearchReaderAndMonthCreation() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--seed-papers"]; app.launch()
        XCTAssertTrue(app.navigationBars["我的论文"].waitForExistence(timeout: 15))
        app.buttons["所有论文"].firstMatch.tap()
        let paper = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Attention Is All You Need")).firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 5)); paper.tap()
        XCTAssertTrue(app.buttons["pdf-page-count"].waitForExistence(timeout: 5))
        let canvas = app.otherElements["pdf-canvas"].firstMatch
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).tap()
        XCTAssertTrue(app.buttons["pdf-page-count"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["阅读选项"].exists)
        XCTAssertFalse(app.buttons["完成"].exists)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).tap()
        XCTAssertTrue(app.buttons["pdf-page-count"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["阅读选项"].exists)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).doubleTap()
        XCTAssertTrue(app.buttons["pdf-page-count"].exists)
        app.buttons["下一页"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "2 / 3"), evaluatedWith: app.buttons["pdf-page-count"])
        waitForExpectations(timeout: 5)
        app.buttons["搜索 PDF"].tap()
        let search = app.textFields["pdf-search"]; XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Attention")
        app.buttons["完成"].firstMatch.tap()
        let librarySearch = app.textFields["library-search"]
        librarySearch.tap(); librarySearch.typeText("Learning")
        XCTAssertTrue(paper.waitForNonExistence(timeout: 5))
        app.buttons["清除搜索"].tap()
        XCTAssertTrue(paper.waitForExistence(timeout: 5))
        app.buttons["多选"].tap(); paper.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Retrieval-Augmented Generation")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已选择 2 项"].waitForExistence(timeout: 5))
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
    func testPullToRefreshInEveryListIncludingEmptyMonthAndSearch() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--seed-papers"]; app.launch()
        XCTAssertTrue(app.navigationBars["我的论文"].waitForExistence(timeout: 15))
        func pullAndCheckRefresh() {
            let list = app.descendants(matching: .any).matching(identifier: "library-list").firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 5))
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
            // The isolated library has no repository/credential, so no real network call is made.
            XCTAssertTrue(app.staticTexts["请先在设置中连接 GitHub 仓库。"].waitForExistence(timeout: 5))
            app.buttons["关闭错误"].tap()
            XCTAssertTrue(app.navigationBars["我的论文"].waitForExistence(timeout: 5))
        }
        app.buttons["所有论文"].firstMatch.tap(); pullAndCheckRefresh()
        let search = app.textFields["library-search"]
        search.tap(); search.typeText("no matching papers\n")
        XCTAssertTrue(app.staticTexts["无搜索结果"].waitForExistence(timeout: 5)); pullAndCheckRefresh()
        app.buttons["清除搜索"].firstMatch.tap()
        app.buttons["文件夹"].firstMatch.tap(); pullAndCheckRefresh()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "2026 年")).firstMatch.tap(); pullAndCheckRefresh()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "11 月")).firstMatch.tap(); pullAndCheckRefresh()
        app.buttons["全部文件夹"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "2025 年")).firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "06 月")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["暂无论文"].waitForExistence(timeout: 5)); pullAndCheckRefresh()
    }
}
