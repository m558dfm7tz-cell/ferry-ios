# Ferry iOS build 18: real tail visibility and reliable first render

Date: 2026-10-30. This branch starts at the **build 17** repair SHA `4b5575ef`; build 17 is still available separately and main has not been replaced.

## Root cause addressed

The bottom-right "return to latest" button was driven by `contentOffset + containerSize >= contentSize - 24`. This calculation omitted the keyboard/composer-adjusted content inset and, more importantly, assumed `LazyVStack`'s offscreen `contentSize` is exact. Apple's SwiftUI guidance warns that it is estimated. The UI also had a date `ForEach` emitting multiple sibling nodes, plus a message `ForEach` that could emit a cell and a conditional gap button, making lazy scroll-to-ID estimation unstable.

When the first cache-backed ten messages were rendered, `LazyVStack` could leave visible rows unavailable until a user scroll caused fresh layout. Merely observing the invisible bottom anchor as a geometry value is not proof that the latest message painted.

## Changes

- Render a **short active transcript (30 messages or fewer) using VStack** so all initially loaded cells exist immediately. Keep `LazyVStack` for long historical pages; do not eagerly load the full server history.
- A day is now a `Section`, and each message inside a `ForEach` is exactly **one** identified VStack (which contains both the bubble and optional gap button). This also preserves the existing `scrollTo(message.id)` behavior for date/search/favorite jumps.
- Detect the actual bottom sentinel via `.onScrollVisibilityChange`; separately detect whether the **newest bubble itself** is visible. Both are real visible-subview signals, not raw estimated scroll offsets.
- Show the "return to latest" pill **only** when the user has left tail-follow, the last bubble and sentinel are both offscreen, and the transcript has painted. Never show it merely because an estimated geometry distance briefly becomes nonzero.
- When an actual drag ends, restore tail-follow only if the bottom sentinel or newest bubble is visible; avoid reclassifying a keyboard animation as user browsing.
- Use `ScrollGeometry.visibleRect` and `contentInsets.bottom` for any remaining numeric fallback. Keyboard corrections treat an already visible latest bubble/bottom sentinel as aligned, rather than issuing needless scroll requests.
- A keyboard frame-change begins its settlement using UIKit's animation duration; `didShow`/`didChangeFrame` events still provide the final settlement. This avoids a premature correction competing with native dismissal.
- Keep build 17's foreground viewport-remount and actual tail visibility checks. In short transcripts remounted view now uses eager layout, reducing blank until swiped.
- Add a UI test to assert no false "return to latest" pill on launch or after keyboard appearance; retain existing background+relaunch painted-content tests.
- Build numbers for app and share extension increment **17 -> 18**. Bundle IDs stay `com.ferry.test` and `com.ferry.test.FerryShare` and existing signing/entitlements and all local data files are unchanged.

## Validation checklist

1. Build branch `fix/ios-chat-visibility-scroll-state-20261030` in Codemagic's `Ferry iOS V2 - unsigned IPA for Sideloadly` workflow (or Xcode), then sign using a team/profile compatible with the **already installed** Ferry. Do not uninstall the old app.
2. After an actual force-quit, open chat on and off the network: active latest messages should appear without any swipes. Validate on selected assistant conversations and transfer.
3. At the newest bubble, press the input field; during repeated system keyboard show/hide, the bottom-right latest pill must remain hidden and messages track the composer.
4. Browse upward into older history, including >30 messages, verify the pill then appears; tapping it must land on the most recent bubble.
5. Repeat with photos/video thumbnails arriving, native emoji/third-party keyboards, attachment custom input panel, dates/search jump, foreground suspension/recovery.
6. Run XCTest simulator UI tests with a visible software keyboard, particularly `testLatestMessageNeverShowsFalseReturnPill`, `testNewestMessagePaintedAfterForegroundAndRelaunch`, `testNewestBubbleTracksKeyboardResize`. Track memory/frames if lag persists.

**Status:** source edits and static code checks performed; Xcode compile, XCTest execution, physical phone validation and signed IPA are not claimed as completed. Do not merge to main without them.
