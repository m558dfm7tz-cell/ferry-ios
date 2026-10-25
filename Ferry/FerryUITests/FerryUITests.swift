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
}
