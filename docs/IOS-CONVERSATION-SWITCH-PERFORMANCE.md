# Ferry iOS — faster switching between 互传 / 助手 / 总管

## Scope

This optimization changes **only** the iOS client. It keeps Ferry's Go wire
protocol, server selection, Keychain credentials, media caches, notifications,
sharing extension, assistant routing and the original bundle ID untouched.
Base branch commit before these edits: `6e51a85369945bb3a86fab1fd450b2baa5066177`.

## Bottlenecks confirmed in existing source

1. `selectedAssistantID.didSet` invalidated the entire visible transcript and
   date-group cache on **every** avatar selection.
2. `visibleMessages` rescanned all loaded messages and `daySections` reparsed
   their timestamps whenever a different assistant was selected.
3. Unread clearing performed `messages.first(where:)` for each unread ID.
4. `TimelineView` observed the last visible message ID independently from the
   selected assistant ID: changing pages could request a bottom scroll both
   from the last-message observer and the selection observer.
5. The historical-day separator made a new `DateFormatter` for each message.

## Implementation

- `AppModel` now maintains a snapshot-scoped per-conversation message index,
  per-conversation cached day sections and an ID-to-message index.
- Switching assistants selects an indexed bucket without invalidating another
  conversation's sections. Incoming/deleted messages, routing changes, profile
  changes and server changes still invalidate the derived caches.
- Legacy non-isolated mode still displays **all** messages under its nil tab;
  verified routing mode still shows **only transfer** messages under nil.
  Unknown assistant history remains in the unclassified bucket.
- Clearing unread entries uses the same ID index instead of repeated message scans.
- `TimelineView` treats a change of assistant and a new message in the same
  assistant as different events, avoiding duplicate scroll-to-bottom requests.
- Historical date labels reuse a formatter.

No on-disk migrations or message deletions are part of this work.

## Validation

- Static source verification passed for cache invalidation, route selection,
  unread indexing, scroll observer and existing `com.ferry.test` Codemagic workflow.
- A standalone Swift algorithm smoke test compared the indexed selection with
  the old filter semantics for 12,000 synthetic messages, both routing modes
  and five conversation identities (10 checks): passed.
- **Not yet run:** full Xcode/iOS compiler, Codemagic archive, actual iPhone UI
  frame/latency instrumentation and manual regression tests.

## Manual acceptance

1. Build latest `feat/multi-computer-isolation-20261029` in Codemagic
   with workflow `Ferry iOS - multi-computer in-place update unsigned IPA`.
   Simulator UI tests are intentionally not run by this workflow.
2. Sign with the *same* Apple development team and app identity as the
   installed Ferry (`com.ferry.test`); do not uninstall the existing app.
3. With a long media-heavy history, switch 互传 → 助手 → 总管 → 互传
   repeatedly, checking immediate messages, date separators, unread indicators,
   no blank flash, no duplicated scroll animation and stable input focus.
4. Send/receive a message while viewing another assistant; ensure only the
   matching tab's messages appear and notifications/unread badges remain correct.
5. Verify older-page loading, date jump/search jump, favorite location, video
   and image preview, keyboard expansion, notification route and A/B computer switch.

## Rollback

The feature branch's pre-optimization baseline was
`6e51a85369945bb3a86fab1fd450b2baa5066177`. Roll back **only** the
performance commits or restore the three touched Swift files from that commit
in a separate development branch. Never reset production `main`, uninstall
the phone app or delete its caches to recover.
