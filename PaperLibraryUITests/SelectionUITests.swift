import XCTest

final class SelectionUITests: XCTestCase {
    private func element(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label == %@ OR value == %@ OR title == %@ OR identifier == %@",
                    name,
                    name,
                    name,
                    name
                )
            )
            .firstMatch
    }

    func testClickingWorkSelectsItAndShowsInspector() {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing")
        app.launch()

        let workRow = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "界面测试论文"))
            .firstMatch
        XCTAssertTrue(workRow.waitForExistence(timeout: 5), "测试文献应显示在列表中")

        workRow.click()

        XCTAssertTrue(element(named: "书目信息", in: app).waitForExistence(timeout: 3), "单击后应显示右侧检查器")
        let selectedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "已选择"),
            object: workRow
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [selectedExpectation], timeout: 3),
            .completed,
            "单击后应显示选中标志"
        )
    }
}
