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

    func testTwoPointRouteAppearsOnEachSideOfMidnight() {
        let app = launch(fixture: "midnight")
        app.tabBars.buttons["回顾"].tap()
        let days = app.descendants(matching: .any).matching(identifier: "review-day")
        XCTAssertTrue(days.element(boundBy: 1).waitForExistence(timeout: 8))
        for index in 0...1 {
            days.element(boundBy: index).tap()
            let walk = app.buttons.matching(identifier: "timeline-entry")
                .matching(NSPredicate(format: "label CONTAINS %@", "步行")).firstMatch
            scrollTo(walk, in: app, horizontalOffset: 0.98)
            XCTAssertTrue(walk.isHittable, app.debugDescription)
            walk.tap()
            XCTAssertTrue(app.buttons["显示全天"].waitForExistence(timeout: 5))
            app.navigationBars.buttons["回顾"].tap()
        }
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

    func testDiscardCurrentAndDeleteLegacyUnfinishedRecord() {
        let app = launch(fixture: "unfinished")
        let paused = app.staticTexts["已暂停"]
        XCTAssertTrue(paused.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "这条记录尚未结束")).firstMatch.exists)

        app.tabBars.buttons["回顾"].tap()
        app.buttons["回顾选项"].tap()
        app.buttons["管理记录"].tap()
        XCTAssertTrue(app.staticTexts["未结束 · 还没有定位点"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.tabBars.buttons["记录"].tap()

        let discard = app.buttons["丢弃这次记录"]
        scrollTo(discard, in: app)
        discard.tap()
        app.buttons["取消"].tap()
        XCTAssertTrue(paused.exists)
        discard.tap()
        app.buttons["丢弃记录"].tap()
        XCTAssertTrue(app.buttons["回看当前路线"].waitForExistence(timeout: 5))

        app.tabBars.buttons["回顾"].tap()
        app.buttons["回顾选项"].tap()
        app.buttons["管理记录"].tap()
        XCTAssertFalse(app.staticTexts["未结束 · 还没有定位点"].exists)
        let unfinished = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "未结束")).firstMatch
        XCTAssertTrue(unfinished.waitForExistence(timeout: 5), app.debugDescription)
        unfinished.swipeLeft()
        app.buttons["删除"].tap()
        app.buttons["删除路线"].tap()
        XCTAssertTrue(app.staticTexts["没有可管理的记录"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.tabBars.buttons["记录"].tap()
        XCTAssertTrue(app.buttons["开始记录"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["开始记录"].waitForExistence(timeout: 5))
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

    func testDamagedPlaceNamesCanBeRebuiltAndSaved() {
        let app = launch(fixture: "damaged-names")
        app.tabBars.buttons["回顾"].tap()
        let day = app.descendants(matching: .any).matching(identifier: "review-day").firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 8))
        day.tap()
        let stay = app.buttons.matching(identifier: "timeline-entry")
            .matching(NSPredicate(format: "label CONTAINS %@", "停留地点")).firstMatch
        scrollTo(stay, in: app, horizontalOffset: 0.98)
        XCTAssertTrue(stay.isHittable)
        stay.tap()
        let edit = app.buttons["编辑地名"]
        scrollTo(edit, in: app, horizontalOffset: 0.98)
        edit.tap()

        let rebuild = app.buttons["重建地名文件"]
        XCTAssertTrue(rebuild.waitForExistence(timeout: 5))
        app.buttons["重试读取"].tap()
        XCTAssertTrue(rebuild.exists)
        rebuild.tap()
        let confirm = app.alerts["重建地名文件？"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.buttons["取消"].tap()
        XCTAssertTrue(rebuild.exists)
        rebuild.tap()
        confirm.buttons["重建"].tap()

        let name = app.textFields["地点名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Restored")
        app.buttons["保存"].tap()
        let restored = app.buttons.matching(identifier: "timeline-entry")
            .matching(NSPredicate(format: "label CONTAINS %@", "Restored")).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, horizontalOffset: Double = 0.5) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: horizontalOffset, dy: 0.73))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: horizontalOffset, dy: 0.49))
        for _ in 0..<12 {
            if element.isHittable { return }
            start.press(forDuration: 0.15, thenDragTo: end)
        }
    }

    private func launch(fixture: String, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extraArguments
        app.launchEnvironment = ["LIFEMEM_UI_TEST_FIXTURE": fixture, "LIFEMEM_UI_TEST_STORAGE_ID": UUID().uuidString]
        app.launch()
        return app
    }
}
