# Ferry iOS build 19 — return-to-latest and assistant keyboard stability

This branch extends the build 18 repair (commit c32a6b0d), without changing production `main`.

## What build 18 missed
- The return-to-latest action still called `ScrollViewReader.scrollTo` on a **1-point lazy bottom spacer**. A user's tap could flip `isFollowingTail` and hide the pill, but fail to move the viewport if the spacer was not ready or a simultaneous keyboard-dismiss gesture changed the layout.
- Chief (总管) and other assistant conversations frequently hold only a few messages. The small content height makes native scroll content alignment and keyboard safe-area resizing behave differently than a long transfer chat. Chief can also have a separate 待查看 row above the messages.

## Fix
- Use the native iOS 18 `ScrollPosition(idType: String.self, edge: .bottom)` bound to the chat scrollview, and call `.scrollTo(edge: .bottom)` for **all bottom-seeking commands**. Retain `ScrollViewReader` for date/search/older-page **message-ID** jumps only.
- Direct user return-to-latest cancels stale date-jump, keyboard retry, and pending pagination scroll commands so that an older request cannot overwrite a tap.
- Place the chat scroll view in a `GeometryReader` and **minimum-fill the changing viewport height for short active conversations (<=30 messages)**, aligning rows at the bottom alongside the composer. Long histories stay lazy and scroll normally. The extra 总管 top bar remains part of its content inset.
- Remove the broad simultaneous tap gesture on the entire ScrollView, which could fire while tapping the latest button and dismiss the keyboard. Existing blank-background-only keyboard dismissal remains.
- Keep the previous build 18 bottom sentinel, actually-visible latest-message checks, cold-start/foreground remount, and native keyboard stabilization.

## Regression fixtures/tests
- `-uiTestMockAssistant`: isolated chief message and real selected 总管 tab; verify the latest bubble remains next to the composer after repeated keyboard toggles and no false latest button.
- `-uiTestMockLongHistory`: insert 48 earlier messages so the transcript uses LazyVStack; scroll back, tap latest, verify that the last message **actually becomes hittable** and the button goes away.

## Safety
- Build numbers **18 -> 19** in app and share extension.
- **Do not change** installed application ID `com.ferry.test`, extension `com.ferry.test.FerryShare`, signing team, group entitlements, local user data, favorites, message routes, Go or Helper.
- Use the same signer/profile as the installed app; **never uninstall Ferry** to upgrade.

## Required on-device checks
1. Tap 最新消息 from a long scrolled-up transfer/assistant conversation, with and without keyboard.
2. In a short 总管/助手 chat, open/close keyboard 10 times, then use a tall message, emoji keyboard, and the attachment input panel.
3. Verify no jumps into older messages, no focus failure, no false latest pill.
4. Test foreground resumption, saved computers, favorites, and search/date jump.
5. Run Xcode build + UI tests on a simulator with visible software keyboard; **not run here**, so code is still a test candidate.


## Build 20 (whitespace dismissal regression repair)

The build-19 fix deliberately removed a whole-scroll simultaneous TapGesture because it could intercept the "return to latest" command. The remaining `.background` handler was behind scroll content, and was not reliably hittable when the assistant/transfer chat viewport contained blank space.

- Add a **dedicated tappable `Color.clear` layer** *inside* the ScrollView's ZStack and **behind** the real transcript content. It is sized with the chat viewport, including the blank space above a short assistant conversation. Taps on chat buttons, media rows and the latest button are not handled by this blanket gesture.
- Restore blank-tap dismiss only when system keyboard, custom plus attachment panel, or focus is actually present.
- Resign the native `UITextView` first responder **before** clearing the attachment-mode binding to avoid swapping in the system keyboard during dismiss.
- Add DEBUG mock short conversation and `testBlankChatTapDismissesKeyboardAndPlusPanel`. Run it with iOS simulator's software keyboard enabled.
- Increment existing application **and share extension** build numbers to **20**. Bundle IDs `com.ferry.test` and `com.ferry.test.FerryShare` unchanged; do not uninstall the existing app for signing workarounds.

The Swift source is patched; actual macOS Xcode compilation, test run, signed IPA and device verification must still be performed.


## Build 21 (tap in actual message-row whitespace)

**User result from build 20:** blank-area dismissal worked only at the very edge of the screen, not in the large empty strip beside a chat bubble.

### Verified structural cause
- `TimelineView` was applying `.contentShape(Rectangle())` to **each entire message row**.
- `MessageRow` expanded its message VStack to `maxWidth: .infinity`, meaning the empty strip opposite the bubble belonged to the row's hit-test surface. The transparent ZStack backdrop could not receive taps there.
- Merely enlarging another backdrop would not fix this overlap without possibly stealing image, file, copy, selection or return-to-latest taps.

### Focused fix
- Every message row now has an **explicit flexible `Color.clear` hit region on the side opposite the bubble**: left of outgoing/right of incoming. That region alone invokes `dismissKeyboardIfPresented` (works for standard keyboard and custom plus `inputView`).
- The bubble/metadata/actions VStack uses its intrinsic width; the former whole-row `.contentShape(Rectangle())` is removed.
- Keep the earlier ZStack backdrop for vertical gaps, top whitespace and very short conversations. No whole-ScrollView TapGesture is reintroduced.
- Test `testBlankChatTapDismissesKeyboardAndPlusPanel` now clicks at **the same height as the actual newest message and to its left**, not the top/edge of the screen; tests both native keyboard and custom plus panel.
- The repair does not modify the iOS 18 native return-to-latest, bottom-follow state, assistant/chief layout, message routing or persistent data.
- Increment app and share-extension build number **20 -> 21**, preserving both bundle IDs and entitlements.

### Not yet verified
The source and static consistency checks are not substitutes for an Xcode build and simulator/iPhone UI tests. Build branch `fix/ios-assistant-keyboard-latest-20261030` in Codemagic with `ferry-ios-sideloadly`. The IPA is unsigned; perform a compatible signed in-place upgrade and **do not uninstall** the existing Ferry.
