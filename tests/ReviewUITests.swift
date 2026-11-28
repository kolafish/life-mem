import CoreLocation
import XCTest

final class ReviewUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAutomaticRecordingSwitchAndRestore() {
        let app = launch(fixture: "empty")
        let toggle = app.switches["自动记录（试用）"]
        scrollTo(toggle, in: app)
        XCTAssertTrue(toggle.isEnabled)
        toggle.tap()
        XCTAssertTrue(app.staticTexts["等待出发"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.buttons["开始记录"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["等待出发"].waitForExistence(timeout: 8))
        #if targetEnvironment(simulator)
        defer { XCUIDevice.shared.location = nil }
        let recording = app.staticTexts["正在自动记录"]
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        for step in 0..<8 {
            let fix = CLLocation(coordinate: .init(latitude: 0, longitude: Double(step) * 0.00015),
                                 altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: .now)
            XCUIDevice.shared.location = XCUILocation(location: fix)
            Thread.sleep(forTimeInterval: 2)
        }
        app.activate()
        XCTAssertTrue(recording.waitForExistence(timeout: 5), app.debugDescription)
        #endif
        scrollTo(toggle, in: app)
        toggle.tap()
        XCTAssertTrue(app.buttons["开始记录"].waitForExistence(timeout: 5))
        #if targetEnvironment(simulator)
        app.tabBars.buttons["回顾"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "review-day").firstMatch.waitForExistence(timeout: 8))
        #endif
    }

    func testSearchPlaceAndRecallVisit() {
        let app = launch(fixture: "day")
        app.tabBars.buttons["回顾"].tap()
        app.buttons["地点"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("测试办公室")
        let office = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "测试办公室")).firstMatch
        XCTAssertTrue(office.waitForExistence(timeout: 5))
        office.tap()
        XCTAssertTrue(app.staticTexts["到访记录"].waitForExistence(timeout: 5))
        let preview = app.buttons["place-map-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.28)).tap()
        XCTAssertTrue(app.buttons["返回地点"].waitForExistence(timeout: 5))
        app.buttons["返回地点"].tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
    }

    func testPreviousVisitOpensSourceFromToday() {
        let app = launch(fixture: "day")
        let office = app.buttons.matching(identifier: "today-stop")
            .matching(NSPredicate(format: "label CONTAINS %@", "测试办公室")).firstMatch
        scrollTo(office, in: app)
        office.tap()
        let last = app.buttons.matching(identifier: "visit-memory").matching(NSPredicate(format: "label CONTAINS %@", "上次")).firstMatch
        XCTAssertTrue(revealTimelineControl(last, in: app), app.debugDescription)
        last.tap()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
        let id = "memory-source-\(Int(yesterday.timeIntervalSince1970))"
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: id).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let selected = app.buttons.matching(identifier: "timeline-entry").matching(NSPredicate(format: "isSelected == true")).firstMatch
        XCTAssertTrue(selected.label.contains("测试办公室"))
    }

    func testFirstVisitOpensSourceFromDailyReview() {
        let app = launch(fixture: "day")
        app.tabBars.buttons["回顾"].tap()
        let yesterdayRow = app.buttons.matching(identifier: "review-day").element(boundBy: 1)
        XCTAssertTrue(yesterdayRow.waitForExistence(timeout: 5))
        yesterdayRow.tap()
        let office = app.buttons.matching(identifier: "timeline-entry")
            .matching(NSPredicate(format: "label CONTAINS %@ AND NOT (label CONTAINS %@)", "测试办公室", "→")).firstMatch
        XCTAssertTrue(revealTimelineControl(office, in: app), app.debugDescription)
        office.tap()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
        let source = app.descendants(matching: .any).matching(identifier: "memory-source-\(Int(yesterday.timeIntervalSince1970))").firstMatch
        XCTAssertFalse(source.exists)
        let first = app.buttons.matching(identifier: "visit-memory").matching(NSPredicate(format: "label CONTAINS %@", "首次")).firstMatch
        XCTAssertTrue(revealTimelineControl(first, in: app), app.debugDescription)
        first.tap()
        XCTAssertTrue(source.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(office.isSelected)
    }

    func testTodayShowsStopsAndOpensSelectedEntry() {
        let app = launch(fixture: "day")
        let title = app.staticTexts["today-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertTrue(title.label.contains("测试办公室"))
        app.buttons.matching(identifier: "today-entry").firstMatch.tap()
        XCTAssertTrue(app.buttons["显示全天"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
    }

    func testDailyMapAndTimelineSelection() {
        let app = launch(fixture: "mainland-day")
        app.tabBars.buttons["回顾"].tap()
        let day = app.descendants(matching: .any).matching(identifier: "review-day").firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 10))
        day.tap()
        XCTAssertTrue(app.staticTexts["当日概览"].waitForExistence(timeout: 8), app.debugDescription)

        let preview = app.descendants(matching: .any).matching(identifier: "day-map-preview").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(preview.frame.height, 160)
        XCTAssertFalse(app.buttons["展开地图"].exists)
        let previewStop = app.buttons.matching(identifier: "stay-marker")
            .matching(NSPredicate(format: "label CONTAINS %@", "测试办公室")).firstMatch
        XCTAssertTrue(previewStop.waitForExistence(timeout: 5), app.debugDescription)
        let blankMap = CGVector(dx: 0.78, dy: 0.22)
        preview.coordinate(withNormalizedOffset: blankMap).tap()
        XCTAssertTrue(app.navigationBars["当天地图"].waitForExistence(timeout: 5))
        let marker = app.buttons.matching(identifier: "stay-marker")
            .matching(NSPredicate(format: "label CONTAINS %@", "测试办公室")).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 5), app.debugDescription)
        let overview = XCTAttachment(screenshot: app.screenshot())
        overview.name = "Full-screen route with named stops"
        overview.lifetime = .keepAlways
        add(overview)
        marker.tap()
        let reset = app.buttons["显示全天"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["当天地图"].waitForExistence(timeout: 5))
        app.buttons["返回时间线"].tap()
        XCTAssertTrue(app.buttons["编辑地名"].waitForExistence(timeout: 5))
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = "Focused stay on iPhone SE"
        screen.lifetime = .keepAlways
        add(screen)
        reset.tap()
        XCTAssertFalse(reset.exists)

        previewStop.tap()
        XCTAssertTrue(app.navigationBars["当天地图"].waitForExistence(timeout: 5))
        let focusedStop = app.buttons.matching(identifier: "timeline-entry").firstMatch
        XCTAssertTrue(focusedStop.waitForExistence(timeout: 5))
        XCTAssertTrue(focusedStop.label.contains("测试办公室") && !focusedStop.label.contains("→"))
        app.buttons["返回时间线"].tap()
        reset.tap()

        preview.coordinate(withNormalizedOffset: blankMap).tap()
        let map = app.descendants(matching: .any).matching(identifier: "daily-route-map").firstMatch
        map.swipeLeft()
        XCTAssertTrue(reset.isEnabled)
        reset.tap()
        app.buttons["返回时间线"].tap()

        let office = app.buttons.matching(identifier: "timeline-entry")
            .matching(NSPredicate(format: "label CONTAINS %@ AND NOT (label CONTAINS %@)", "测试办公室", "→")).firstMatch
        XCTAssertTrue(revealTimelineControl(office, in: app), app.debugDescription)
        office.tap()
        XCTAssertTrue(office.isSelected, app.debugDescription)
        let chosen = office.label
        preview.coordinate(withNormalizedOffset: blankMap).tap()
        XCTAssertTrue(app.navigationBars["当天地图"].waitForExistence(timeout: 5))
        let card = app.buttons.matching(identifier: "timeline-entry").firstMatch
        XCTAssertEqual(card.label, chosen)
        app.buttons["返回时间线"].tap()
        XCTAssertTrue(office.isHittable)
        XCTAssertTrue(office.isSelected, app.debugDescription)
    }

    func testPreviewOpensRepeatedStopWithoutChoosingAVisit() {
        let app = launch(fixture: "mainland-day")
        app.tabBars.buttons["回顾"].tap()
        app.buttons.matching(identifier: "review-day").firstMatch.tap()
        let preview = app.descendants(matching: .any).matching(identifier: "day-map-preview").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let previewGroup = app.buttons.matching(identifier: "stay-marker")
            .matching(NSPredicate(format: "label CONTAINS %@", "测试之家")).firstMatch
        XCTAssertTrue(previewGroup.waitForExistence(timeout: 5), app.debugDescription)
        previewGroup.tap()
        XCTAssertTrue(app.navigationBars["当天地图"].waitForExistence(timeout: 5))
        let group = app.buttons.matching(identifier: "stay-marker")
            .matching(NSPredicate(format: "label CONTAINS %@", "测试之家")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        XCTAssertFalse(group.isSelected)
        XCTAssertEqual(group.frame.midX, app.frame.midX, accuracy: 32)
        group.tap()
        let lastVisit = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "08:35")).firstMatch
        XCTAssertTrue(lastVisit.waitForExistence(timeout: 5))
        lastVisit.tap()
        let card = app.buttons.matching(identifier: "timeline-entry")
            .matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "08:35", "测试之家")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.isHittable)
        XCTAssertTrue(group.isSelected)
    }

    #if targetEnvironment(simulator)
    func testDictationFallbackPreservesTypedNote() {
        XCUIApplication().resetAuthorizationStatus(for: .microphone)
        let app = launch(fixture: "day")
        app.buttons.matching(identifier: "today-entry").firstMatch.tap()
        let note = app.buttons.matching(identifier: "entry-note").firstMatch
        XCTAssertTrue(revealTimelineControl(note, in: app))
        note.tap()
        let input = app.textViews["这次记录的一句话"]
        input.tap()
        input.typeText("River")
        XCTAssertEqual(input.value as? String, "River")
        app.buttons["note-dictation"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 4) {
            let deny = springboard.alerts.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label == %@", "Don", "不允许")).firstMatch
            XCTAssertTrue(deny.exists)
            deny.tap()
        }
        let message = app.staticTexts["note-dictation-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 6))
        XCTAssertTrue(message.label.contains("离线") || message.label.contains("未获授权") || message.label.contains("无法使用麦克风"), message.label)
        XCTAssertTrue(input.waitForExistence(timeout: 4))
        XCTAssertEqual(input.value as? String, "River")
        input.tap()
        input.typeText(" walk")
        XCTAssertEqual(input.value as? String, "River walk")
        app.buttons["保存"].tap()
        XCTAssertTrue(note.label.contains("River walk"))
    }
    #endif

    func testNoteDraftAndSave() {
        let app = launch(fixture: "day")
        app.buttons.matching(identifier: "today-entry").firstMatch.tap()
        let note = app.buttons.matching(identifier: "entry-note").firstMatch
        XCTAssertTrue(revealTimelineControl(note, in: app))
        note.tap()
        let input = app.textViews["这次记录的一句话"]
        input.tap()
        input.typeText("River walk")
        app.buttons["关闭"].tap()
        XCTAssertTrue(note.label.contains("草稿"))
        note.tap()
        XCTAssertEqual(input.value as? String, "River walk")
        app.buttons["保存"].tap()
        XCTAssertTrue(note.label.contains("River walk"))
    }

    func testPhotoOpensItsLocationAndReturnsToEntry() {
        let app = launch(fixture: "photo-day")
        app.tabBars.buttons["回顾"].tap()
        app.buttons.matching(identifier: "review-day").firstMatch.tap()
        let photo = app.buttons["查看照片"].firstMatch
        XCTAssertTrue(revealTimelineControl(photo, in: app))
        photo.tap()
        let map = app.buttons["在地图上看拍摄位置"]
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        map.tap()
        XCTAssertTrue(app.navigationBars["当天地图"].waitForExistence(timeout: 8))
        let mapView = app.descendants(matching: .any).matching(identifier: "daily-route-map").firstMatch
        XCTAssertGreaterThan(mapView.frame.height, app.frame.height * 0.32)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "photo-map-pin").firstMatch.waitForExistence(timeout: 4))
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = "Photo location and timeline card"
        screen.lifetime = .keepAlways
        add(screen)
        app.buttons.matching(identifier: "timeline-entry").firstMatch.tap()
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "photo-map-pin").firstMatch.exists)
        app.buttons["返回时间线"].tap()
        let selected = app.buttons.matching(identifier: "timeline-entry").matching(NSPredicate(format: "isSelected == true")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
    }

    func testHidingPhotoLeavesOtherPhotoAndItsRoute() {
        let app = launch(fixture: "photo-day")
        app.buttons.matching(identifier: "today-entry").firstMatch.tap()
        let photos = app.buttons.matching(identifier: "查看照片")
        XCTAssertTrue(revealTimelineControl(photos.firstMatch, in: app))
        photos.firstMatch.tap()
        app.buttons["照片选项"].tap()
        app.buttons["从记录中隐藏"].tap()
        let remaining = NSPredicate { _, _ in photos.count == 1 }
        expectation(for: remaining, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        photos.firstMatch.tap()
        let map = app.buttons["在地图上看这段记录"]
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        map.tap()
        XCTAssertTrue(app.navigationBars["当天地图"].waitForExistence(timeout: 5))
    }

    func testPhotoConsentAndReturn() {
        let app = launch(fixture: "day")
        app.tabBars.buttons["回顾"].tap()
        app.buttons.matching(identifier: "review-day").firstMatch.tap()
        let enable = app.buttons["显示当天照片"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        enable.tap()
        XCTAssertTrue(app.alerts["关联当天拍摄的照片？"].waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(enable.isHittable)
    }

    func testEmptyHistory() {
        let app = launch(fixture: "empty")
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
            let preview = app.descendants(matching: .any).matching(identifier: "day-map-preview").firstMatch
            XCTAssertTrue(preview.waitForExistence(timeout: 5))
            preview.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.16)).tap()
            XCTAssertTrue(app.navigationBars["当天地图"].waitForExistence(timeout: 5))
            for name in ["起点", "终点"] {
                let pin = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
                XCTAssertTrue(pin.waitForExistence(timeout: 5), app.debugDescription)
            }
            app.buttons["返回时间线"].tap()
            let walk = app.buttons.matching(identifier: "timeline-entry")
                .matching(NSPredicate(format: "label CONTAINS %@", "步行")).firstMatch
            scrollTo(walk, in: app, horizontalOffset: 0.98)
            XCTAssertTrue(walk.isHittable, app.debugDescription)
            walk.tap()
            XCTAssertTrue(app.buttons["显示全天"].waitForExistence(timeout: 5))
            app.navigationBars.buttons["回顾"].tap()
        }
    }

    func testAutomaticPlaceIntroductionAndPrefetch() {
        let app = launch(fixture: "prefetch")
        app.tabBars.buttons["回顾"].tap()
        let intro = app.staticTexts["为停留显示地名"]
        XCTAssertTrue(intro.waitForExistence(timeout: 8))
        app.buttons["以后再说"].tap()
        XCTAssertFalse(intro.exists)
        app.terminate()
        app.launch()
        app.tabBars.buttons["回顾"].tap()
        let days = app.descendants(matching: .any).matching(identifier: "review-day")
        XCTAssertTrue(days.firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(intro.exists)

        app.buttons["回顾选项"].tap()
        app.buttons["开启自动地名"].tap()
        let consent = app.alerts["开启自动地名？"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        consent.buttons["开启"].tap()
        let labeledDay = days.matching(NSPredicate(format: "label CONTAINS %@", "测试街道附近")).firstMatch
        XCTAssertTrue(labeledDay.waitForExistence(timeout: 8))
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
        app.tabBars.buttons["今天"].tap()

        let discard = app.buttons["丢弃这次记录"]
        scrollTo(discard, in: app)
        discard.tap()
        let confirmDiscard = app.buttons["丢弃记录"]
        XCTAssertTrue(confirmDiscard.waitForExistence(timeout: 5))
        let cancel = app.buttons["取消"]
        if cancel.exists {
            cancel.tap()
        } else {
            // Some iPhone versions present this as a popover that dismisses on an outside tap.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.15)).tap()
        }
        XCTAssertTrue(confirmDiscard.waitForNonExistence(timeout: 5))
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
        app.tabBars.buttons["今天"].tap()
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

    private func revealTimelineControl(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let map = app.descendants(matching: .any).matching(identifier: "day-map-preview").firstMatch
        let tabs = app.tabBars.firstMatch
        for _ in 0..<10 {
            let frame = element.exists ? element.frame : .zero
            let mapBottom = map.exists ? map.frame.maxY + 12 : 0
            let tabTop = tabs.exists ? tabs.frame.minY : app.frame.maxY
            if element.isHittable && frame.midY > mapBottom && frame.midY < tabTop { return true }
            // Drag along the margin to scroll the timeline outside the interactive map.
            let aboveMap = !frame.isEmpty && frame.midY <= mapBottom
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: aboveMap ? 0.62 : 0.77))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: aboveMap ? 0.77 : 0.62))
            start.press(forDuration: 0.15, thenDragTo: end)
        }
        return false
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, horizontalOffset: Double = 0.5) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: horizontalOffset, dy: 0.73))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: horizontalOffset, dy: 0.49))
        for _ in 0..<12 {
            if element.isHittable { return }
            start.press(forDuration: 0.15, thenDragTo: end)
        }
    }

    private func launch(fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment = ["LIFEMEM_UI_TEST_FIXTURE": fixture, "LIFEMEM_UI_TEST_STORAGE_ID": UUID().uuidString]
        app.launch()
        return app
    }
}
