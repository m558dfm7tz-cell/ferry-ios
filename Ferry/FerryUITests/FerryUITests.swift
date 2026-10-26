import XCTest

/// UI tests launched with "-uiTestMock", which makes the app skip pairing/
/// network and inject mock messages in DEBUG builds.
final class FerryUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestMock"]
        app.launch()
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    @MainActor
    func testImageAndVideoBubbleContextMenus() throws {
        // Use .any so the element is found regardless of whether SwiftUI
        // exposes the bubble as a Button or an Image.
        let imageBubble = app.descendants(matching: .any)["bubble.image"]
        let videoBubble = app.descendants(matching: .any)["bubble.video"]
        let copyLinkItem = app.buttons["复制临时下载链接"]

        XCTAssertTrue(imageBubble.waitForExistence(timeout: 8), "image bubble should exist")
        imageBubble.press(forDuration: 1.0)
        XCTAssertTrue(copyLinkItem.waitForExistence(timeout: 5), "image bubble context menu should appear")
        tap(copyLinkItem)

        XCTAssertTrue(videoBubble.waitForExistence(timeout: 8), "video bubble should exist")
        videoBubble.press(forDuration: 1.0)
        XCTAssertTrue(copyLinkItem.waitForExistence(timeout: 5), "video bubble context menu should appear")
    }

    /// Device-management removal flow in mock mode: open 设备管理, verify the
    /// current-device tag, swipe a non-current device, tap 移除, and confirm the
    /// confirmation alert appears before cancelling.
    @MainActor
    func testDeviceManagementRemovalConfirmation() throws {
        let connectionStatus = app.buttons["connection-status"]
        XCTAssertTrue(connectionStatus.waitForExistence(timeout: 8), "connection-status button should exist")
        tap(connectionStatus)

        let currentBadge = app.descendants(matching: .any)["current-device-badge"]
        XCTAssertTrue(currentBadge.waitForExistence(timeout: 5), "current-device badge should exist")

        let pcRow = app.staticTexts["Windows PC"]
        XCTAssertTrue(pcRow.waitForExistence(timeout: 5), "Windows PC row should exist")
        pcRow.swipeLeft()

        let removeButton = app.buttons["remove-device-mock-pc"]
        XCTAssertTrue(removeButton.waitForExistence(timeout: 5), "remove action should appear after swipe")
        tap(removeButton)

        let alert = app.alerts["移除设备"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "removal confirmation alert should appear")
        tap(alert.buttons["取消"])
    }

    /// Top bar: the ellipsis menu shows 跳转到日期/收藏/选择/设置, and entering
    /// 选择 shows "已选 0 项".
    @MainActor
    func testTopBarMenuAndSelectionMode() throws {
        let moreButton = app.buttons["more-menu"].firstMatch
        XCTAssertTrue(moreButton.waitForExistence(timeout: 8), "more menu should exist")
        tap(moreButton)

        XCTAssertTrue(app.buttons["跳转到日期"].waitForExistence(timeout: 5), "menu item 跳转到日期")
        XCTAssertTrue(app.buttons["收藏"].waitForExistence(timeout: 5), "menu item 收藏")
        XCTAssertTrue(app.buttons["选择"].waitForExistence(timeout: 5), "menu item 选择")
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 5), "menu item 设置")

        tap(app.buttons["选择"].firstMatch)
        XCTAssertTrue(app.staticTexts["已选 0 项"].waitForExistence(timeout: 5), "selection mode shows 已选 0 项")
    }

    /// "@" mention/command picker (mock mode): typing "@" shows 电脑 + 助手,
    /// tapping 助手 shows its commands, tapping 翻译 inserts "/翻译 ".
    @MainActor
    func testMentionPickerInsertsCommand() throws {
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "composer input should exist")
        tap(composer)
        composer.typeText("@")

        let desktop = app.buttons["mention-desktop"].firstMatch
        XCTAssertTrue(desktop.waitForExistence(timeout: 8), "mention list should show 电脑")
        XCTAssertTrue(app.buttons["mention-helper"].exists, "mention list should show 助手")

        tap(app.buttons["mention-helper"].firstMatch)

        let translate = app.buttons["command-translate"].firstMatch
        XCTAssertTrue(translate.waitForExistence(timeout: 5), "commands should appear")
        tap(translate)

        XCTAssertEqual(composer.value as? String, "/翻译 ", "composer text should be the inserted command")
    }

    /// Wait for an element, then tap it; falls back to a center-coordinate tap
    /// when the element exists but is not reported hittable (e.g. clipped by a
    /// navigation bar).
    @MainActor
    private func tap(_ element: XCUIElement, timeout: TimeInterval = 8,
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "element should exist", file: file, line: line)
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }
}
