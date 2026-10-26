import XCTest

/// UI tests for the timeline bubble context menus. Launched with "-uiTestMock",
/// which makes the app skip pairing/network and inject one text, one image and
/// one video message in DEBUG builds.
final class FerryUITests: XCTestCase {

    @MainActor
    func testImageAndVideoBubbleContextMenus() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMock"]
        app.launch()

        // Use .any so the element is found regardless of whether SwiftUI
        // exposes the bubble as a Button or an Image.
        let imageBubble = app.descendants(matching: .any)["bubble.image"]
        let videoBubble = app.descendants(matching: .any)["bubble.video"]
        let copyLinkItem = app.buttons["复制临时下载链接"]

        XCTAssertTrue(imageBubble.waitForExistence(timeout: 8), "image bubble should exist")
        imageBubble.press(forDuration: 1.0)
        XCTAssertTrue(copyLinkItem.waitForExistence(timeout: 4), "image bubble context menu should appear")
        copyLinkItem.tap()

        XCTAssertTrue(videoBubble.waitForExistence(timeout: 8), "video bubble should exist")
        videoBubble.press(forDuration: 1.0)
        XCTAssertTrue(copyLinkItem.waitForExistence(timeout: 4), "video bubble context menu should appear")
    }

    /// Device-management removal flow in mock mode: open 设置 → 设备管理,
    /// verify the current-device tag, swipe a non-current device, tap 移除, and
    /// confirm the confirmation alert appears before cancelling. The mock never
    /// touches the network, so nothing is actually removed.
    @MainActor
    func testDeviceManagementRemovalConfirmation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMock"]
        app.launch()

        let connectionStatus = app.buttons["connection-status"]
        XCTAssertTrue(connectionStatus.waitForExistence(timeout: 8), "connection-status button should exist")
        connectionStatus.tap()

        let currentBadge = app.descendants(matching: .any)["current-device-badge"]
        XCTAssertTrue(currentBadge.waitForExistence(timeout: 4), "current-device badge should exist")

        let pcRow = app.staticTexts["Windows PC"]
        XCTAssertTrue(pcRow.waitForExistence(timeout: 4), "Windows PC row should exist")
        pcRow.swipeLeft()

        let removeButton = app.buttons["remove-device-mock-pc"]
        XCTAssertTrue(removeButton.waitForExistence(timeout: 4), "remove action should appear after swipe")
        removeButton.tap()

        let alert = app.alerts["移除设备"]
        XCTAssertTrue(alert.waitForExistence(timeout: 4), "removal confirmation alert should appear")
        alert.buttons["取消"].tap()
    }

    /// Top bar: the ellipsis menu shows 跳转到日期/收藏/选择/设置, and entering
    /// 选择 shows "已选 0 项".
    @MainActor
    func testTopBarMenuAndSelectionMode() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMock"]
        app.launch()

        let moreButton = app.buttons["more-menu"]
        XCTAssertTrue(moreButton.waitForExistence(timeout: 8), "more menu should exist")
        moreButton.tap()

        XCTAssertTrue(app.buttons["跳转到日期"].waitForExistence(timeout: 4), "menu item 跳转到日期")
        XCTAssertTrue(app.buttons["收藏"].waitForExistence(timeout: 4), "menu item 收藏")
        XCTAssertTrue(app.buttons["选择"].waitForExistence(timeout: 4), "menu item 选择")
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 4), "menu item 设置")

        app.buttons["选择"].tap()
        XCTAssertTrue(app.staticTexts["已选 0 项"].waitForExistence(timeout: 4), "selection mode shows 已选 0 项")
    }

    /// "@" mention/command picker (mock mode): typing "@" shows 电脑 + 助手,
    /// tapping 助手 shows its commands, tapping 翻译 inserts "/翻译 ".
    @MainActor
    func testMentionPickerInsertsCommand() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestMock"]
        app.launch()

        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "composer input should exist")
        composer.tap()
        composer.typeText("@")

        XCTAssertTrue(app.buttons["mention-desktop"].waitForExistence(timeout: 4), "mention list should show 电脑")
        XCTAssertTrue(app.buttons["mention-helper"].exists, "mention list should show 助手")

        app.buttons["mention-helper"].tap()

        let translate = app.buttons["command-translate"]
        XCTAssertTrue(translate.waitForExistence(timeout: 4), "commands should appear")
        translate.tap()

        XCTAssertEqual(composer.value as? String, "/翻译 ", "composer text should be the inserted command")
    }
}
