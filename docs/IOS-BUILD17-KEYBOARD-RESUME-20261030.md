# Ferry iOS build 17: keyboard smoothness and lazy transcript resume

Date: 2026-10-30. Continues build 16 on `fix/ios-keyboard-tail-follow-20261030` (PR #6).

## Changes
- Eliminated the high-frequency keyboard feedback loop: let SwiftUI's native bottom anchor manage the changing safe area; keep a **measured** tail-gap flag during the animation, and only issue **one** nonanimated correction after the final keyboard geometry settles if still displaced. No per-frame `scrollTo`.
- Retained a coalesced, nonanimated correction for **separate** image-content height changes after the keyboard has already settled; genuine user scroll always cancels follow.
- Unify bottom threshold at 24 points instead of a conflicting 120-point/18-point pair.
- Actual iOS `onScrollVisibilityChange` verifies the last message is displayed, not merely that a hidden bottom spacer is geometrically reachable.
- After a genuine app background->foreground transition **while following newest**, rebuild only the `ScrollView`/lazy-cell hierarchy using a new view identity, leaving `AppModel`, messages, favorites, credentials, paired computers and database untouched. A session initially hydrated from cache gets the same bounded viewport recovery when its latest cell never became visible.
- Media save/share action buttons are now present from the initial image placeholder, preventing this whole extra row from suddenly expanding once an image decodes. The image itself still retains its aspect ratio; this is *not* a blanket guarantee of fixed height for unmeasured image metadata.
- Added UI regression for background->foreground and force-close->relaunch **painted** last bubble (not just `exists`). Existing keyboard/bottom geometry test retained.
- Main app and share extension: Xcode build number **17**. Same `com.ferry.test` and `com.ferry.test.FerryShare` bundle IDs and original entitlements/app group.

## Manual validation required
1. Build the branch in macOS Xcode, run the SwiftUI UI tests on a simulator **with software keyboard enabled**. Static code checks alone do not prove iOS build success.
2. On an actual iPhone, open latest chat; show/hide native keyboard 10 times, interactively dismiss, repeat with media-heavy chat and with keyboard attachment menu.
3. While viewing older history, show/hide keyboard and return foreground: should preserve the user's reading location.
4. In newest chat, send app to background, reopen; latest message must appear **without a gesture**. Force-close from multitasking and reopen to exercise cache-to-server hydration.
5. Test image/video thumbnails loading during keyboard transition, switching assistants, date/search jump and 10-item mobile history pagination.
6. If stutters persist, collect Instruments Time Profiler/SwiftUI updates and log `ScrollGeometry` events; do not layer more asynchronous scroll commands onto this patch.

## Installation
This is a development branch, not yet merged into `main`. Existing manual `ferry-ios-sideloadly` Codemagic workflow can generate an unsigned IPA. Use a signing identity compatible with the **already installed** `com.ferry.test` to perform an in-place update. Do not uninstall, change bundle ID, reset data, or assume an unsigned IPA will preserve app data across unrelated signing teams.

**Status:** source changes made and regression test added; actual Xcode compile, simulator tests and device verification are still pending.
