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
