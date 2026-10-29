# iPhone lightweight chat — validation plan

Feature branch: `feat/multi-computer-isolation-20261029`. No production `main` change.

## Behavior

- Each conversation first displays the newest **10** messages.
- Uses a separate on-disk App Support JSON snapshot per server/space and
  conversation, capped at **20** message records. Does not copy the file bytes
  of media into the message snapshot.
- Older history loads **10** at a time. Automatic prefetch requires a real
  upward user drag. Ten short rows at startup cannot trigger it. A manual
  `加载更早消息` button works if the ten rows cannot fill a screen.
- Session text/message history has no 40–60-item cap. Decoded image/video
  thumbnails are separately bounded (48 entries); cached video posters
  load off the main actor.
- Date markers and date jumps use Go server queries rather than a global
  2,000-message startup scan. Search is server-side with file-type filters
  and paged result retrieval. Favorites locate by exact message ID.
- Jumping to distant history creates an explicit `加载较新记录` gap button,
  not a fabricated continuous conversation. The user can page in either
  direction.
- The original Go `/api/v1/messages` remains a compatible fallback when
  the mobile history endpoint is unavailable. No message or favorite is
  deleted from Go because of a phone cache eviction.
- Keyboard dismissal no longer queues a second forced bottom scroll. User
  drag guards history prefetch during keyboard frame changes.

## Deploy order

1. Validate Go `feat/multi-computer-isolation-20261029` in the isolated
   Windows test server and run `go test ./...`.
2. Build iOS from the same feature branch in Codemagic with the existing
   manual workflow `Ferry iOS - multi-computer in-place update unsigned IPA`.
   No simulator UI test is run in that workflow.
3. The unsigned `Ferry-MultiComputer-INPLACE-UNSIGNED.ipa` keeps
   `com.ferry.test`, the original share extension/app group. Use the
   *same compatible Apple signing identity* as the currently installed
   Ferry to update in place; never uninstall or switch signing teams.
4. Back up important local data before sideloading. Verify keyboard up/down,
   helper quick actions, live updates and notifications, 10-row short-chat
   behavior, 20-item disk snapshots after relaunch, long upward paging,
   search filters, date dots/jumps, favorites and old-server fallback.
5. Test switch between two saved computers. Only selected computer should
   provide notifications; snapshots must remain isolated by server space.

**This is a source implementation, NOT a verified iPhone release.**
The Go build, Xcode/Codemagic build and physical device frame timings still
need to be run. If compilation or tests fail, do not replace the installed
iPhone/Go versions. A source-only rollback can restore the iOS branch to
`88b68772558edf5a12aa7c496a2c9f63eef7db3e` and Go to
`19b6c77e3953f0a0c94ed0008005f723b8f9bd0e` on fresh validation
branches; do not reset or rewrite production `main`.
