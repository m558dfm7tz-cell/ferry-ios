# iOS keyboard / timeline bottom-follow repair — 2026-10-30

## Why
On the newest chat message, showing/hiding the native keyboard intermittently did nothing or moved the list several messages back. Prior code only used SwiftUI `.defaultScrollAnchor(.bottom, for: .sizeChanges)` and suppressed `atBottom` updates throughout the animation. If the last geometry notification occurred during that suppression, `atBottom` could remain stale. There was no measured-gap repair. Late media layout could also leave the transcript stranded while `keyboardVisible` was true.

## Implementation
- Preserve `isFollowingTail` as the user's intent; a real `DragGesture` cancels automatic follow, including interactive keyboard dismissal.
- Always reconcile stored `atBottom` with actual `ScrollGeometry` (not `old.atBottom`), even during keyboard changes.
- Keep native bottom anchoring for the smooth normal path; **only** when the actual distance to the bottom exceeds 18 points while pinned, coalesce a next-layout corrective scroll to the existing bottom anchor, without a second animation.
- Maintain this behavior while the keyboard remains visible, including late image/media sizing.
- Handle UIKit `keyboardWillChangeFrame` / `keyboardDidChangeFrame`, for third-party, emoji, predictive keyboard and custom `inputView` height changes. Re-snapshot the active bottom-follow intent before dismissing the keyboard.
- Guard searches, historical pagination, real manual drags and deliberate date jumps from unsolicited tail re-anchoring.
- Add a DEBUG-only final message fixture, and a UI regression checking actual on-screen message-to-composer gap when the software keyboard appears. Existing mock media examples stay.
- Increment all Xcode targets' build numbers from 15 to **16**. Preserve `com.ferry.test`, `com.ferry.test.FerryShare` and `group.com.ferry.test.shared`, all local storage, pairing and server protocol. Only iOS files are modified.

## Required verification
1. Compile with Xcode 16.4 iOS 18 SDK; run Ferry UI regression suite with an iOS simulator software keyboard enabled. UI tests cannot validate keyboard geometry when a hardware keyboard prevents the software keyboard from appearing.
2. Physically test keyboard show/hide repeatedly, plus emoji/third-party keyboards and Ferry's plus attachment panel, on media-heavy as well as pure-text conversations.
3. When currently at latest message, the latest bubble must stay just above the composer while the keyboard animates, with no jump several messages back. When reading older history, the keyboard must not force the list to newest.
4. Test tap-to-dismiss, interactive dismissal, reopening, switching chats, date/search jumps, image/video preview, history pagination, app foreground resume and reloading.
5. Use a signed IPA with the SAME app bundle identifier and a signing identity/provisioning compatible with the installed Ferry. The Codemagic `ferry-ios-sideloadly` workflow yields an **unsigned** IPA; do not uninstall the old app to fix signing problems.

**Verification status**: GitHub source patch and UI test authored; actual macOS build, simulator execution and signed in-place update are not claimed until completed.
