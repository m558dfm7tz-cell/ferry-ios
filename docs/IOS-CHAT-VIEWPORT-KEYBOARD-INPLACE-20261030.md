# Ferry iOS chat viewport / keyboard repair (2026-10-30)

## Scope
- Development branch only, based on main c5c8e5e. Production main unchanged.
- Fix startup transcript not appearing until an initial swipe; repair accidental tail-detachment during keyboard viewport changes.
- Split true older-page prepend position restoration from cache replacement/reconnect updates.
- Add UI smoke test for initial message visibility and keyboard resize.
- Do not alter server / Helper, local storage format, routes, favorites or authentication.

## In-place installation (must not create a second app)
- Keep original main bundle identifier `com.ferry.test`, share extension `com.ferry.test.FerryShare`, and app group `group.com.ferry.test.shared`.
- Original project's build number is bumped from 14 to 15; display version stays 1.0.
- Existing Codemagic `ferry-ios-sideloadly` manual workflow builds an **unsigned** IPA from whichever branch was selected. Select THIS repair branch when building.
- Signed installation **only** replaces the existing Ferry if both its bundle identifier AND Apple signing team / provisioning remain compatible with the currently installed app. An unsigned IPA alone cannot guarantee update in place.
- Do not uninstall the existing Ferry to solve a signature conflict. Back up important phone data first; stop and inspect signing if the installer proposes an additional app or requires uninstall.
- Verify final signed IPA's main app bundle identifier before installing.

## Validation still required
1. macOS Xcode Release archive; UI regression simulator tests. Source changes are not yet a compiled or device-validated release.
2. Launch after force close: latest conversation renders without a swipe (test with cached and uncached messages, short and media-heavy histories).
3. Keyboard up/down repeatedly while following latest message: tail remains at bottom with no delayed bounce.
4. Drag up into history, show/hide keyboard: do not jump to latest.
5. Load earlier pages, switch assistants, delete a message, date jump/search jump, return to foreground and reconnect: preserve the expected anchor.
6. Test native plus-menu custom inputView switching, saved computers and local data survival after an actual signed upgrade.
