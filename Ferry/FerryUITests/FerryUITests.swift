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

    /// Direct bubble tap opens the tapped photo, supports mixed-media
    /// horizontal paging and keeps the chat-wide gallery on the top right.
    @MainActor
    func testChatBubbleOpensPagerWithTopRightMediaGrid() throws {
        let imageBubble = app.buttons["bubble.image"].firstMatch
        XCTAssertTrue(imageBubble.waitForExistence(timeout: 8))
        tap(imageBubble)
        let grid = app.buttons["viewer-open-gallery"].firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 8),
                      "chat photo should open full-screen preview first")
        XCTAssertTrue(app.staticTexts["1 / 2"].waitForExistence(timeout: 5))
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["2 / 2"].waitForExistence(timeout: 6))
        tap(grid)
        XCTAssertTrue(app.navigationBars["媒体"].waitForExistence(timeout: 8))
    }

    /// A tap in the composer restores the system keyboard from the
    /// replacement inputView, without bringing up a second floating panel.
    @MainActor
    func testPlusAttachmentKeyboardHandoff() throws {
        let input = app.textViews["composer-input"].firstMatch
        let plus = app.buttons["添加"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        tap(input)
        tap(plus)
        let file = app.buttons["composer-attachment-file"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["composer-attachment-camera"].exists)
        tap(input)
        XCTAssertFalse(file.waitForExistence(timeout: 2),
                       "attachment input must switch back to software keyboard")
    }

    /// Device-management removal flow in mock mode: open 设备管理, verify the
    /// current-device tag, swipe a non-current device, tap 移除, and confirm the
    /// confirmation alert appears before cancelling.
    @MainActor
    func testDeviceManagementRemovalConfirmation() throws {
        let connectionStatus = app.buttons["connection-status"]
        XCTAssertTrue(connectionStatus.waitForExistence(timeout: 8), "connection-status button should exist")
        tap(connectionStatus)

        // `.firstMatch` so an ambiguous query can never make `exists` false.
        let currentBadge = app.descendants(matching: .any)["current-device-badge"].firstMatch
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
    /// tapping 助手 shows its real commands; 截图 inserts "/截图".
    @MainActor
    func testMentionPickerInsertsCommand() throws {
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "composer input should exist")
        tap(composer)

        // Wait until the composer actually has keyboard focus before typing. On
        // CI the software keyboard may not appear (hardware keyboard), so accept
        // either the keyboard showing or the text view gaining focus directly.
        let keyboardShown = app.keyboards.firstMatch.waitForExistence(timeout: 10)
        if !keyboardShown {
            let focused = NSPredicate(format: "hasKeyboardFocus == true")
            let focusExpectation = expectation(for: focused, evaluatedWith: composer)
            _ = XCTWaiter.wait(for: [focusExpectation], timeout: 10)
        }

        composer.typeText("@")

        let desktop = app.buttons["mention-desktop"].firstMatch
        XCTAssertTrue(desktop.waitForExistence(timeout: 8), "mention list should show 电脑")
        XCTAssertTrue(app.buttons["mention-helper"].waitForExistence(timeout: 5),
                      "mention list should show 助手")

        tap(app.buttons["mention-helper"].firstMatch)

        let screenshot = app.buttons["command-截图"].firstMatch
        XCTAssertTrue(screenshot.waitForExistence(timeout: 5), "real commands should appear")
        tap(screenshot)

        XCTAssertEqual(composer.value as? String, "/截图", "composer should contain actual FerryHelper command")
    }


    /// All built-in avatars, including 总管 and 助手, expose the full menu.
    @MainActor
    func testBuiltInAvatarManagementMenus() throws {
        let bar = app.scrollViews["assistant-bar"].firstMatch
        let chief = app.buttons["assistant-avatar-chief"].firstMatch
        XCTAssertTrue(chief.waitForExistence(timeout: 8))
        chief.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["更换头像"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["编辑信息"].exists)
        XCTAssertFalse(app.buttons["隐藏头像"].exists)
        XCTAssertFalse(app.buttons["删除头像分类"].exists)
        tap(app.buttons["取消"].firstMatch)

        let helper = app.buttons["assistant-avatar-helper"].firstMatch
        XCTAssertTrue(helper.waitForExistence(timeout: 8))
        for _ in 0..<4 {
            if helper.isHittable { break }
            bar.swipeLeft()
        }
        XCTAssertTrue(helper.isHittable)
        helper.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["更换头像"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["编辑信息"].exists)
        XCTAssertFalse(app.buttons["隐藏头像"].exists)
        XCTAssertFalse(app.buttons["删除头像分类"].exists)
        tap(app.buttons["取消"].firstMatch)
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
