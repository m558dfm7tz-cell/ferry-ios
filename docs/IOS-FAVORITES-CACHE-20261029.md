# Ferry iOS favorite and cache changes — validation

Source branch: `feat/multi-computer-isolation-20261029`. No installed application has been changed.

- Favorite preview uses Application Support/Favorites offline file first,
  then authenticated `GET /api/v1/favorites/{id}/file` from Go; images use
  file-backed decoding, videos/audio/documents open their file URLs directly.
- Saving a favorite from a large downloaded file uses staging + file copy,
  not an unbounded Data buffer. If the original chat disappears during an
  offline favorite, protected local bytes can be uploaded using authenticated
  `PUT /api/v1/favorites/{id}/file` (max 2 GiB), followed by retrying the same
  timestamped favorite operation.
- Full favorites list is reconciled at login and on a change event; ordinary
  fallback checking is 60 seconds. The existing cheap /changes poll remains.
  Deletion changes advance the cursor by the **last applied event**, never
  skip from first 500 to the global revision.
- Re-downloadable iOS caches have a combined 500 MiB quota for normal media
  and attachments, 100 MiB for video posters, with age expiration and a
  10-minute in-use grace period. Sweep at reconnect and after downloads;
  regular deletions remove corresponding cache keys and poster sidecars.
- Application Support/Favorites, message snapshots, manually exported files
  in the Photos app / Files app and user data are **never** deleted by the
  ordinary cache janitor. Media digest keys now include space + message ID so
  a delete event can clean an off-screen message without its original URL.
  Legacy URL-inclusive cache keys age out under normal cleanup.
- No fixed limit is imposed on live session text messages. The existing
  twenty metadata snapshots per conversation are unchanged.

Validation checklist:
1. Go branch first: run Go tests and launch separate server, not production.
2. Codemagic: `Ferry iOS - multi-computer in-place update unsigned IPA` on
   the feature branch. Archive and sign with the SAME compatible Apple team
   and identity; do not uninstall old Ferry.
3. Test large video favorite, 30+ pictures, file types, original chat deletion,
   return from offline mode, multiple computers, file range streaming,
   cancellation and unstar, plus UI state after server removal.
4. Test 600+ message/favorite deletion events while iPhone offline, reboot
   both ends, and verify no stale results and no cross-space deletion.
5. Inspect app's disk usage across repeat download, preview, delete and
   re-download. Check bounded ordinary caches and preserved favorites.

The code has been statically inspected, not compiled with Xcode here.
Do not substitute this inspection for a successful Codemagic build.
