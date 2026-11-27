import XCTest

final class ReviewUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testDailyMapAndTimelineSelection() {
        let app = launch(fixture: "day")
        app.tabBars.buttons["回顾"].tap()
        let day = app.descendants(matching: .any).matching(identifier: "review-day").firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 10))
        day.tap()
        XCTAssertTrue(app.staticTexts["当日概览"].waitForExistence(timeout: 8), app.debugDescription)

        let marker = app.buttons.matching(identifier: "stay-marker")
            .matching(NSPredicate(format: "label CONTAINS %@", "测试办公室")).firstMatch
        for _ in 0..<4 where !marker.isHittable { app.swipeUp() }
        XCTAssertTrue(marker.isHittable, app.debugDescription)
        marker.tap()
        let reset = app.buttons["显示全天"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["编辑地名"].isHittable)
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = "Focused stay on iPhone SE"
        screen.lifetime = .keepAlways
        add(screen)
        reset.tap()
        XCTAssertFalse(reset.exists)

        let home = app.buttons.matching(identifier: "timeline-entry")
            .matching(NSPredicate(format: "label CONTAINS %@", "测试之家")).firstMatch
        for _ in 0..<4 where !home.isHittable { app.swipeDown() }
        XCTAssertTrue(home.isHittable)
        home.tap()
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
    }

    func testEmptyHistoryAtAccessibilitySize() {
        let app = launch(fixture: "empty", extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.tabBars.buttons["回顾"].tap()
        XCTAssertTrue(app.staticTexts["还没有记录"].waitForExistence(timeout: 5))
        app.buttons["回顾选项"].tap()
        XCTAssertTrue(app.buttons["开启自动地名"].waitForExistence(timeout: 5))
        app.buttons["开启自动地名"].tap()
        XCTAssertTrue(app.alerts["开启自动地名？"].waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
    }

    private func launch(fixture: String, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extraArguments
        app.launchEnvironment = ["LIFEMEM_UI_TEST_FIXTURE": fixture]
        app.launch()
        return app
    }
}
