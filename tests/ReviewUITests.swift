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
        app.tabBars.buttons["分析"].tap()
        XCTAssertTrue(app.staticTexts["时间分配与记录覆盖"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "未记录")).firstMatch.exists)
    }

    func testAnalyticsPeriodAndRanking() {
        let app = launch(fixture: "day")
        app.tabBars.buttons["分析"].tap()
        XCTAssertTrue(app.staticTexts["时间分配与记录覆盖"].waitForExistence(timeout: 8), app.debugDescription)
        app.tabBars.buttons["回顾"].tap()
        let day = app.descendants(matching: .any).matching(identifier: "review-day").firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 5))
        app.tabBars.buttons["分析"].tap()
        XCTAssertTrue(app.staticTexts["时间分配与记录覆盖"].waitForExistence(timeout: 5))
        app.buttons["自定义"].tap()
        let startDate = app.descendants(matching: .any).matching(identifier: "analytics-start-date").firstMatch
        let endDate = app.descendants(matching: .any).matching(identifier: "analytics-end-date").firstMatch
        XCTAssertTrue(startDate.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(endDate.exists)
        app.buttons["本月"].tap()
        let ranking = app.staticTexts["常去地点"]
        scrollTo(ranking, in: app)
        XCTAssertTrue(ranking.isHittable)
        let insights = app.staticTexts["本期洞察"]
        scrollTo(insights, in: app)
        XCTAssertTrue(insights.isHittable)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "首次记录到")).firstMatch.exists)
        let frequentRoutes = app.staticTexts["常走路线"]
        XCTAssertTrue(frequentRoutes.waitForExistence(timeout: 8), app.debugDescription)
        scrollTo(frequentRoutes, in: app)
        XCTAssertTrue(frequentRoutes.isHittable)

        let travel = app.staticTexts["通行效率"]
        scrollTo(travel, in: app)
        XCTAssertTrue(travel.isHittable)
        let routine = app.staticTexts["离家与回家"]
        scrollTo(routine, in: app)
        XCTAssertTrue(routine.isHittable)
    }

    func testPlaceSuggestionRequiresConfirmation() {
        let app = launch(fixture: "suggestions")
        app.tabBars.buttons["回顾"].tap()
        let places = app.buttons["地点"]
        XCTAssertTrue(places.waitForExistence(timeout: 8))
        places.tap()
        let suggestionLink = app.descendants(matching: .any).matching(identifier: "place-suggestion-home").firstMatch
        XCTAssertTrue(suggestionLink.waitForExistence(timeout: 8), app.debugDescription)
        suggestionLink.tap()
        let confirm = app.buttons["设为家"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        app.buttons["取消"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        app.buttons["保存"].tap()
        XCTAssertTrue(app.buttons["编辑地名"].waitForExistence(timeout: 5))
        XCTAssertFalse(confirm.exists)
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.73))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.49))
        for _ in 0..<12 {
            if element.isHittable { return }
            start.press(forDuration: 0.15, thenDragTo: end)
        }
    }

    private func launch(fixture: String, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extraArguments
        app.launchEnvironment = ["LIFEMEM_UI_TEST_FIXTURE": fixture]
        app.launch()
        return app
    }
}
