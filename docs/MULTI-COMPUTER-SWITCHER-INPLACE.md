# Ferry iPhone computer switcher and in-place IPA

Branch: `feat/multi-computer-isolation-20261029`.

## iPhone UI
- The existing top-left Wi-Fi connection icon in the original Ferry timeline now opens **切换电脑**, not device management.
- The sheet shows the selected computer and its current connection state, saved computer addresses/names, and one fixed **添加电脑** button at the bottom.
- Add opens the existing QR / manual address / LAN discovery chooser. Saved computers still use AppModel's per-origin Keychain token, local caches and exclusive active-server polling; no central router or background subscription to unselected computers is introduced.
- Per-computer rename/remove stays available by long-pressing the saved computer row; ordinary device administration remains in **更多 → 设置 → 设备管理**.
- Existing chat, favorites and saved-server preferences must not be wiped on upgrade.

## Identity and installation
- The Codemagic manual workflow `ferry-ios-multi-computer-validation` no longer rewrites `com.ferry.test` to `com.ferry.test.multi`.
- The main app remains `com.ferry.test`, share extension remains `com.ferry.test.FerryShare`, and the app group remains `group.com.ferry.test.shared`.
- Codemagic packages an **unsigned** IPA named `Ferry-MultiComputer-INPLACE-UNSIGNED.ipa`; it is NOT ready for direct iPhone installation.
- Re-sign and install with the **same Apple Team ID, same app identifier and compatible app-group entitlements** as the existing Ferry installation. Updating from a previous `com.ferry.test.multi` test app or using another signing team will **not** automatically replace it or preserve its data.
- Before installing, export/backup important local data. Do not uninstall the existing app. Do not use installation tools/options that delete and reinstall the app. If signing fails, stop and inspect the installed app identity before retrying.

## Required tests
1. Run the manual Codemagic workflow on this exact feature branch. There are deliberately no simulator UI tests.
2. Verify `Payload/Ferry.app/Info.plist` has `CFBundleIdentifier=com.ferry.test` and the embedded share extension retains its original identifier.
3. Sign with the original installer credentials; update over the existing app and confirm old chat/caches and saved computers remain.
4. Tap the former Wi-Fi icon, switch A ↔ B, verify only selected server notifications, and add another computer by each of QR, manual address and LAN discovery.
5. Try a revoked token or incorrect password and confirm the device requests reauthentication.

Source inspections completed; **Codemagic build/signing and physical upgrade still need validation**.
