# Changelog

All notable changes to the LinkTrail iOS SDK are documented in this file.
This project adheres to [Semantic Versioning](https://semver.org).

## [Unreleased]

## [0.2.0] - 2026-11-12

### Added
- **`onLink(nil)` removes the link handler.** Links that resolve while no handler is set are kept
  (a deferred link saved, the latest re-engagement link held for this launch) and go to the next
  handler registered, once. Additive overload; `onLink { … }` is unchanged.
- **`debugDeviceId` (SPI, for debug and e2e tooling).** `@_spi(E2E) import LinkTrailSDK` exposes
  `LinkTrail.shared?.debugDeviceId`: the app-scoped device id the SDK sends with counted installs,
  opens and events, or `nil` while the saved state can't be read (nothing is minted then). The
  example app shows it on a DEBUG label so the e2e run can look a probabilistic install up by
  device. It is compiled into DEBUG builds only and is not in the published interface; no
  change for apps.
- **`LinkTrailError.invalidEvent(reason:)`.** `trackEvent` now refuses, before the consent check,
  a blank name, a NaN/infinite or negative value, and a currency that is not 3 letters: it reports
  `invalidEvent` to `onError` once (the async form throws it) and sends and queues nothing. These
  calls used to fail at the backend with a 400 (or locally with an encoding error). More than 2
  decimals, a currency without a value, `0` and `-0.0` are still sent unchanged. A blank name is Kotlin's
  `isBlank` (NBSP and other Unicode spaces count) and values in the reason print as Kotlin does
  (`-1.0E-5`). Same rules and reason text as Android. An exhaustive `switch` over
  `LinkTrailError` needs the new case (or `@unknown default`).

### Fixed
- **A re-engagement link that resolves before `onLink` is set is no longer dropped.** A Universal
  Link handled (`handleDeepLink`) before the app registers `onLink` is now held in memory for this
  launch and delivered once, on the main thread, when `onLink` is registered. Only the latest such
  link is kept; registering again, replacing the handler, a scene reconnect, or a repeat or new
  `configure` never delivers it twice (a reconfigure moves an undelivered link to the new
  instance, unless an open newer than it was still in flight: that open is cancelled and the older
  link is dropped, so neither link is delivered, rather than routing the app back to the older
  one). "Latest" means opened last, not resolved last: a link whose open started before the held
  link, or before the newest link already delivered this launch, is dropped even with `onLink`
  set (the `async` `handleDeepLink` still returns it to its caller). A link held for more than 7 days (the deferred-link expiry) is dropped. It is not
  persisted, so a later launch never replays it. With `onLink` already registered nothing changes.
  The `async` `handleDeepLink` returns the link to its caller and doesn't hold it as well (it
  drops an older held link instead). A saved deferred link waiting at registration is delivered
  first, also before the first unlock; one whose install is still in flight is delivered when it
  resolves, so it can come after the re-engagement link. New
  DEBUG lines in `LOGS.md`.
- **Deny wins right up to the send.** A `setConsent(false)` landing after a counted install was
  started but before its request was built now turns it into the `consent: false` install (no
  `deviceId`, no `Idempotency-Key`). Tracking requests also check consent before their first
  attempt, not only before retries.
- **Deny then grant keeps the click token.** The `consent: false` install sends the click token for
  routing and now keeps it, so the counted install a later grant sends still carries `clickId`
  (deterministic match) instead of falling back to IP matching. Matches Android, which re-reads the
  Install Referrer.
- **A grant while the denied install is in flight sends the counted install at once.** It used to
  join the in-flight `consent: false` request, so no counted install went out that launch (manual
  tracking: not until the app called `trackInstall()` again). It now re-checks consent when that
  request returns and sends the counted install right after, as Android does. New iOS log line
  `Consent changed during the install — re-evaluating` (Android's text).
- **The first deferred route is no longer swallowed** when the install result equals the cached
  attribution: the `onAttribution` dedupe no longer gates `onLink`.
- **`+` in a resolve query value is encoded** (`%2B`). It was sent bare, and the backend read it as a
  space. Matches Android's `URLEncoder`.

## [0.1.1] - 2026-10-27

### Changed
- **`setSDKIdentifier` is now public so React Native and Flutter can report themselves.**
  `LinkTrail.setSDKIdentifier(platform:version:)` was `@_spi(Wrapper)`, which the published
  XCFramework does not export (only the public `.swiftinterface` ships), so the wrappers could not
  call it and every wrapper install reported `ios/<version>`. It is now ordinary public API, for
  wrapper SDKs only (apps should not call it). Validation is unchanged: `platform` must match
  `[A-Za-z][A-Za-z0-9-]{0,31}` (lowercased) and `version` `[0-9][0-9A-Za-z.+_-]{0,31}`; anything
  else returns `false` and keeps the current value. No change for apps.

### Docs
- **The public repo's README is up to date and it now ships this CHANGELOG.** The 0.1.0 mirror
  README still showed `0.0.12` install snippets, the old `linkDomains` rule ("leave empty to handle
  every link") and a paste button that always grants consent. It now shows `~> 0.1.1`, the
  `linkDomains` claiming rule, the `grantsConsent` default (`nil`: grant only while undecided), and
  the consent and deferred-delivery behaviour. Every release now copies the README and
  `CHANGELOG.md` to the public repo, so they can't go stale again.

## [0.1.0] - 2026-10-26

### Upgrading from 0.0.12
This release has breaking changes (a `0.x` minor bump). Check each one against your integration:

1. **Custom link domains must be listed in `linkDomains`.** `handleDeepLink` now claims only `https`
   links on `linktrail.io` (or a subdomain) or on a `linkDomains` entry (or a subdomain). If your
   links use your own domain, pass it: `LinkTrailOptions(linkDomains: ["go.acme.com"])`. Any other
   URL (`mailto:`, OAuth callbacks, `myapp://settings`) now returns `false` (async: throws
   `notALinkTrailURL`) with no network call and no `onError`, so route those yourself.
   Custom-scheme LinkTrail links (`myapp://slug`) are no longer handled; use the `https` link.
2. **`LinkTrailPasteButton` no longer grants consent after a denial.** `grantsConsent` is now
   `Bool?`, default `nil`: the tap grants consent only while it is still undecided. Pass
   `grantsConsent: true` for the old "the tap always grants" behaviour, `false` to never touch consent.
3. **`LinkTrail.configure` is a singleton.** A repeat call with the same key and equal options returns
   the existing instance. A call with a different key or options shuts the previous instance down
   (pending work cancelled, callbacks dropped) and returns a new one: re-register `onLink`,
   `onAttribution` and `onError` on the returned instance, and don't keep using a reference to the
   old one (every call on it is ignored).
4. **`setConsent(false)` wins even with `requireConsent: false`.** A denial now always sends one
   `consent: false` install with no device id and drops custom events. Before, with
   `requireConsent: false`, the install still went out counted with the device id.
5. **Invalid options are clamped at `configure`, not in `LinkTrailRetryPolicy.init`.**
   `LinkTrailRetryPolicy` now stores the values you pass; out-of-range values (`maxAttempts < 1`,
   non-positive delays or `requestTimeout`) are fixed at `configure` with a WARNING. Code that reads a
   policy's properties sees the raw values.
6. **`LinkTrailRetryPolicy.disabled.baseDelay` is `0.5` (was `0`).** No behaviour change (one attempt
   never waits); only code that reads the value is affected.
7. **Log format.** The `WARN` level is now `WARNING`, a few lines changed level, and logged URLs drop
   their query and fragment. Update any log filters or alerts; the full table is in `LOGS.md`.
8. **SDK state is no longer backed up.** State moves from `UserDefaults` to a device-only file on the
   first launch (automatic, no setup). An app restored from a backup or moved to a new phone starts
   fresh and must ask for consent again.
9. **Stricter clipboard token.** The pasteboard is used (and cleared) only when its whole content is
   `lt_click=<32 hex>`; text that merely contains a token is ignored.
10. **Rejected events are dropped, not queued.** A non-retryable status (400, 401, 403, 404, 409,
    422, ...) still reaches `onError` but the event is no longer retried on later launches.

### Added
- **`LinkTrail.version`**: the SDK version as a public constant (Swift counterpart of Android's
  `LinkTrail.VERSION`). A unit test keeps it equal to the `VERSION` file.
- **`X-LinkTrail-SDK: ios/<version>` header** on every backend request (install, open, events,
  resolve, including retries), so the backend can see which SDK build an app runs. Wrapper SDKs can
  report themselves instead (e.g. `flutter/0.0.4`) via `@_spi(Wrapper) LinkTrail.setSDKIdentifier(platform:version:)`,
  read on every request, so it takes effect even when called after `configure`; invalid values are rejected.

### Changed
- **Breaking: `handleDeepLink` claims only LinkTrail links.** A URL is claimed only if its scheme
  is `https` (`http` in DEBUG builds only), its host (lowercased, port and trailing dot ignored) is
  `linktrail.io` or a subdomain, or a `linkDomains` entry or a subdomain, and its path has a slug.
  Before, the default empty `linkDomains` claimed any URL with a path, whatever the scheme or host:
  `mailto:`, OAuth callbacks and the app's own `myapp://settings` returned `true`, sent an open or
  resolve to the backend with a foreign host and slug, and fired `onLink`/`onError`. Now any other
  URL returns `false` (async: throws `notALinkTrailURL`), makes no network call, doesn't call
  `onError`, and logs the existing DEBUG `Not a LinkTrail link — ignoring: <url>`. `linkDomains`
  entries are normalised at `configure` (scheme, path and port removed, host lowercased, trailing
  dot dropped: `https://Go.Acme.com:443/x` → `go.acme.com`), then deduped and sorted; an empty or
  invalid entry (blank, a wildcard, an empty label, a space, bracketed IPv6) is ignored with the
  WARNING `linkDomains entry "<value>" is not a valid host; ignored` (shared with Android). A
  single-label entry (`com`, `localhost`) is kept with the WARNING
  `linkDomains entry "<value>" is a single label and will match every host under it`. IDN entries and
  incoming hosts are both converted to punycode before matching, so a homoglyph host never matches.
  The incoming host must also be labels of `[a-z0-9-_]` only, and a URL whose raw authority contains
  `\` or `%` is never claimed (`https://evil.com%2F.linktrail.io/x`, `https://linktrail.io@evil.com/x`
  and similar host-confusion URLs are rejected). The authority is parsed strictly: after the last `@`
  only `host` or `host:port` (port 1–5 digits, ≤ 65535), no whitespace or control characters, and
  the host must equal the one `URLComponents` parses; hosts are at most 253 characters, with labels
  of at most 63 characters that don't start or end with `-` (underscores are allowed). The open and
  resolve send the normalised host, and the URL-only fallback link's `url` is rebuilt from the
  normalised parts (`<scheme>://<host><path>?<query>`, no user-info, port or fragment).
  **Migration:** if your links use a custom domain, list it:
  `LinkTrailOptions(linkDomains: ["go.acme.com"])`. Links on `*.linktrail.io` need no change.
  Custom-scheme LinkTrail links (`myapp://slug`) are no longer handled; use the `https` link.
- **Log lines match the Android SDK and the docs.** Every line is `[LinkTrail] [LEVEL] <message>`
  with LEVEL `DEBUG`, `INFO`, `WARNING` (was `WARN`) or `ERROR`; the full table is in `LOGS.md`.
  "Event dropped (no consent)" and "Re-engagement resolved (no consent)" now log at INFO (were DEBUG);
  "Re-engagement resolve failed (no consent)" logs at WARNING (was DEBUG). New lines:
  `Deferred link routed → path: <path>`, plus the `Already configured` (DEBUG) and `Reconfigured` (WARNING)
  line definitions for the singleton `configure` change.
  Log text only; no behaviour change.
- **Logged URLs carry no query or fragment.** "Not a LinkTrail link" and "Handling deep link" log the
  link as `scheme://host/path` only, so OAuth codes and magic-link tokens never reach the log (same
  rule as Android).
- `LinkTrail.resetForTesting()` now prints through the logger: `[LinkTrail] [INFO] Reset for testing — …`
  (was `[LinkTrail] Reset for testing — …`). It is still printed whatever `logEnabled` says.
- **`LinkTrail.configure` is now a safe singleton.** A repeat call with the same API key and equal
  options is a no-op that returns the existing instance (DEBUG "Already configured — reusing the existing instance"). A call with a
  different key or options shuts the previous instance down first (cancels its in-flight and pending
  work, stops its event-queue flushes, drops its callbacks), then creates the new one (WARNING
  "Reconfigured — previous instance shut down (base URL: <baseURL>)"). Concurrent calls leave exactly one live instance.
  Persisted state (install flags, consent, device id) is untouched. Re-register callbacks on the
  instance a reconfigure returns. On a shut-down instance every call is ignored (DEBUG "Instance shut
  down — ignoring call"), including `setConsent`, which then persists nothing and leaves the queue
  alone (as on Android); network work it had in flight, from fire-and-forget or async calls, is
  cancelled and fires no callback. `linkDomains` compare as a set, so a reordered list is still a no-op.
- **Invalid options are clamped, never thrown.** At `configure` time, with a WARNING per fix (logged only
  when the call creates an instance, not on a no-op repeat; texts in `LOGS.md`, iOS only):
  `retryPolicy.maxAttempts < 1` -> 1; `baseDelay <= 0` -> 0.5s; `maxDelay <= 0` -> 8s;
  `maxDelay < baseDelay` -> `baseDelay`; `requestTimeout <= 0` -> 15s (NaN/infinite count as invalid); very large timeouts are capped at
  `Int32.max` ms (~24.8 days) when handed to URLSession, matching Android.
  `LinkTrailRetryPolicy.init` now stores values as given (the clamp moved to `configure`), and
  `LinkTrailOptions`, `LinkTrailRetryPolicy` and `LinkTrailClickTokenSource` are now `Equatable`.
- **`LinkTrailRetryPolicy.disabled.baseDelay` is now `0.5` (was `0`).** `.disabled` is now
  `LinkTrailRetryPolicy(maxAttempts: 1)`, so its `baseDelay` is the default `0.5` instead of `0`
  (a `0` would now be clamped with a WARNING at `configure`). It has no effect on behaviour: with one
  attempt the delay is never used. Only code that reads `.disabled.baseDelay` sees the new value.
- **Re-engagement opens wait for the saved state.** If `handleDeepLink` runs while the SDK state
  can't be read yet (a launch before the first unlock), it first tries the read again, then waits for
  it, like installs, so the open is recorded under the saved device id with the saved consent. If it
  is still unreadable after 2 seconds, the link is resolved route-only (public resolve: no device id,
  nothing recorded), so the user still lands on the right screen with the link's campaign and
  `customData`. Before, the open got a WARNING, `onError` and a URL-only link (no campaign data),
  or, with `requireConsent` on and a saved grant, went out route-only and was not recorded.
- **The old `UserDefaults` are scanned only once.** After the one-time migration a `legacy_migrated`
  marker is saved in the state file. Later launches no longer read and parse the app's whole
  `Preferences/<bundle id>.plist` (it grows with the app's `UserDefaults`) or copy all of
  `UserDefaults` on `configure`'s thread: they look up the SDK's own 12 keys, and run the full
  migration only if one is back (a downgrade, then an upgrade; the old value still wins). Before the
  migration, the old store's readability is checked by reading one byte, not the whole file.

### Fixed
- **A paste after a denial no longer drops the click token.** With the default options
  (`.pasteButton`, `autoTrackInstall: true`), `setConsent(false)` sends the denial install, and a
  later tap on `LinkTrailPasteButton` (or `trackInstall(clickToken:)`) cleared the pasteboard and
  then skipped the install, so the token was lost. Now a pasted token is used or kept: if the
  `consent: false` install has not gone out yet, the token goes with it (no device id, no
  `Idempotency-Key`, not counted) and the deferred link routes; if it has, the token is held with
  the install and the counted install sends it once consent is granted. No log line changes. The pasteboard is cleared only when the token is sent or held,
  so a paste after the install is tracked no longer wipes it.
- **No event leaves the device after a denial.** An event in flight when `setConsent(false)` ran
  could fail (retryable), be queued after the denial had cleared the queue, and be sent with the
  device id on the next launch. Now consent is checked again before a failed event is queued (under
  the queue's lock, so it can't slip in after the denial's clear; INFO `Event '<name>' dropped —
  consent not granted`), and the offline queue sends only while consent allows: `configure`, a
  grant, an install and every successful event still trigger a flush, but it sends nothing while
  consent is denied (or not granted yet under `requireConsent`), and it stops if consent is withdrawn
  mid-flush.
- **Retries stop when consent is withdrawn.** A tracking request being retried (429, 5xx, a
  transport error) checks consent before each retry. If `setConsent(false)` ran meanwhile it stops
  instead of sending the payload and device id again: an event or queued event is dropped (INFO
  `Event '<name>' dropped — consent not granted`, not queued, no `onError`); a re-engagement open is
  routed route-only through the public resolve instead (nothing recorded); a counted install stops
  without being marked sent, and if the denial would have sent an install (auto-tracking or a held
  install) that one consent:false install follows. The consent:false install itself is unchanged.
- **A paste while the state can't be read no longer overrides a saved denial.** The paste button
  applied its default consent rule (grant while undecided) before the saved state was readable, when
  a saved denial still looked undecided. The tap now waits for the state, then applies consent and
  sends the install, in one task.
- **A change made while the state can't be read survives recovery.** Before the first unlock the
  state is kept in memory; once readable, the saved values used to win. A `setConsent(false)` (for
  example an app re-applying a stored CMP answer in a background launch) was reverted by a saved
  grant, the queue it had cleared came back, and a `resetForTesting()` was undone. Now every key set
  or removed meanwhile is applied over the saved state, removals included (a key removed while
  unreadable is removed from the file even if it was never loaded). One exception: a saved device id
  is never replaced (it can still be removed).
- **A reconfigure while the `.automatic` clipboard read waits on the "Allow Paste" alert keeps the
  token.** A new instance with `.automatic` or `.pasteButton` joins the read the old one started,
  and its install carries the token. One with `.none` doesn't wait for it and never uses the token:
  the held copy is removed when the read finishes. If no instance joins, the token is held
  (`held_click_id`) for the next install. `clipboard_read` is
  set only once the read has finished, so a launch killed during the alert reads again.
- **`onLink` registered while the state can't be read** now gets the saved deferred link as soon as
  the state is readable, in the same session (it used to arrive a launch late).
- **Events held while the state can't be read survive a reconfigure.** They move to the new
  instance and are sent with its key once the state is readable (consent checked then). Before, they
  were dropped although the app had been told they were queued for retry.
- **SDK state is no longer backed up or restored.** It moved from `UserDefaults` (copied by iCloud and
  device backups) to one file in Application Support, `io.linktrail/state.plist`, excluded from backup,
  written atomically with `completeUntilFirstUserAuthentication` protection. Before, a restore onto a
  new phone brought back `install_tracked` / `deferred_routed` (the new install was never sent and its
  deferred link never routed) and the device id (two devices shared one id). Now a restored app starts
  fresh, and asks for consent again (the answer is not restored either). No host-app setup needed.
- **One-time migration:** the first launch with this version copies every `io.linktrail.*` key out of
  `UserDefaults` into the file, then deletes them once the file is written (DEBUG
  `Moved SDK state to device-only storage (<n> keys)`). If the write fails, the old keys are kept and
  the move is retried. Old keys that come back (a downgrade, then an upgrade) win over the file, as on
  Android. The event queue and a saved deferred link move with it. Nothing is written to `UserDefaults`
  afterwards. Limitation: iOS can't tell an update from a restore, so restoring a backup taken before
  the app shipped this version migrates the old keys too.
- **Writes** go to a unique temp file that is renamed over the state file; stale temp files are removed
  on load. They run on a background queue (the first load runs on `configure`'s thread). A failed
  write logs WARNING `SDK state write failed: <error>` and is retried on the next change.
- **A corrupt state file** (it can't be parsed) starts a fresh state with WARNING
  `SDK state unreadable — starting fresh: <error>`, never a crash. A file that **can't be read yet**
  (before the first unlock) is never overwritten: DEBUG `SDK state not readable yet — waiting: <error>`,
  no device id is minted, every install path waits in memory, and `trackEvent` fails with the
  retryable `LinkTrailError.transport("SDK state not readable yet")` while the event is kept in memory
  (each then goes out once, with the saved id, never a throwaway one), and the file is read again on
  `protectedDataDidBecomeAvailable`, the next foreground, or the next write; the saved values win.
  The same applies when the old `UserDefaults` plist can't be read on the first launch after the update.
- **Durable writes:** the temp file is synced to disk before it is renamed over the state file.
- **Device id is single-flight:** concurrent first resolutions return the same id.
- `LinkTrail.resetForTesting()` moves any old keys in first, then clears the new store.
- **`.automatic` no longer shows "Allow Paste" on every launch.** The SDK read the pasteboard on each
  launch after a consented install that had no deferred link. It now reads it at most once: never
  after this app's install is tracked (unless `trackInstall(force: true)` on an install that never
  read it), and never again once a read has happened. This also stops an installed app from reading
  and clearing a click token another app's link had just staged.
- **The clipboard is only cleared when it holds exactly the LinkTrail token.** The whole content must
  be `lt_click=<32 hex>` (surrounding whitespace allowed), the string the interstitial writes. Text
  that merely contains a token is no longer used or wiped, on the `.automatic` and paste paths alike.
- **Nested `customData` / `utm` no longer break the install.** A link whose `customData` held an
  object or array failed to decode, so the install was never marked tracked, `onAttribution` never
  fired and the deferred link never routed. Nested values now come through as compact JSON strings
  (`["a","b"]`, `{"x":1}`), like Android; parse them as JSON (object keys are sorted on iOS). A
  `customData` / `utm` that isn't an object is dropped instead of failing the response.
- **The `.automatic` click token survives a failed install.** The pasteboard is cleared when the token
  is read, so a failed request used to lose it. It is now kept (persisted with the held install) until
  an install is acknowledged and replayed by the retry or on the next launch.
- **`LinkTrailPasteButton` no longer overrides an explicit denial.** `grantsConsent` is now `Bool?`,
  default `nil`: the tap grants consent only while it is still undecided. Pass `true` to keep the old
  "the tap always grants" behaviour, `false` to never touch consent. Logs
  `Paste tapped after a denial — consent stays denied (pass grantsConsent: true to override)` (INFO).
- **`setConsent(false)` now wins with `requireConsent: false` too.** The install was still sent with
  `consent: true` and the `deviceId`. A denial now behaves the same whatever `requireConsent` says:
  one install with `consent: false` and no device identifier, custom events dropped.
- **SKAdNetwork conversion values are reported on iOS 15.0–15.3.** `updateConversionValue` only
  re-registered the app there; it now calls `SKAdNetwork.updateConversionValue(_:)` (iOS 15.4+ still
  uses `updatePostbackConversionValue`). The `SKAdNetwork: registered (legacy; conversion values
  unsupported)` log line is gone; those versions log `SKAdNetwork: updated conversion value <value>`.
- **A deferred link is no longer lost when `onLink` is registered late.** A routable deferred link
  is now saved (persisted under `pending_deferred_link` as `{"savedAt": <epoch ms>, "deepLink": {…}}`,
  same as Android) when the install resolves it, and
  delivered to `onLink` on the main thread as soon as a handler is registered, in the same launch or
  a later one. Before, it was kept only in memory and `deferred_routed` was set before delivery, so
  a kill, crash or reconfigure before `onLink` was set lost it for good (apps that register after a
  splash or login screen). `deferred_routed` is now set, and the saved link removed, only after the
  handler has been called, so delivery is at least once: a crash inside the handler can cause one
  redelivery on the next launch. A saved link older than 7 days is dropped, never delivered (one
  exactly 7 days old is still delivered), and the drop sets `deferred_routed` so a later install
  can't bring it back. The first link wins: while a link is waiting for `onLink`, a later install
  neither replaces it nor routes again. A corrupt stored value is dropped with a WARNING. The install
  is never re-sent for this.
  `resetForTesting()` also clears the saved link. New log lines (`LOGS.md`): DEBUG
  `Deferred link saved until onLink is set → <path>`, DEBUG `Delivering saved deferred link → <path>`,
  DEBUG `Saved deferred link expired — dropped` and WARNING
  `Saved deferred link unreadable — dropped: <error>` (all shared with Android).
- **A malformed `Retry-After` no longer retries immediately.** `nan`, `inf` and negative values are
  treated as malformed and fall back to the computed backoff (`nan` used to skip the wait entirely).
  Surrounding whitespace is ignored, so `" 2 "` is honoured as 2 seconds.
- **A failed re-engagement resolve now reaches `onError` without consent too.** When
  `handleDeepLink(_:)` couldn't resolve a link (network failure, 5xx, ...) on the no-consent
  route-only path, the SDK only logged at debug level and never called `onError`. It now logs a
  warning and reports the same `LinkTrailError` to `onError` (on the main thread) whether consent is
  granted, denied or undecided, matching Android. The link is still delivered by URL only. A URL that
  isn't a LinkTrail link is still not an error.
- **Rejected events are no longer queued and retried forever.** Only retryable failures go to the
  offline queue: transport errors (offline, timeout), 408, 429 and 5xx. A 400, 401, 403, 404, 409, 422
  (or any other non-retryable status) still reaches `onError` and throws from the async API, but is
  dropped with WARNING `Event '<name>' rejected (<status>) — not retried`. A failure with no status
  (an unreadable success body, a local error) is not queued either and reaches `onError`, with no
  "rejected" line. A queued entry that gets a non-retryable status on a later flush is dropped with
  the same line (no `onError`). Before, every failure was queued, so
  a bad payload or a revoked key was re-sent on every launch and could push real events out of the
  100-entry queue.
- **Concurrent queue flushes no longer send the same event several times.** Configure, the install,
  `setConsent(true)` and every successful event each trigger a flush; overlapping flushes each sent
  the whole queue (3 flushes of 1 event gave 3 POSTs). Now one flush runs at a time; a flush asked for
  meanwhile runs once after it, so an event queued mid-flush is still sent. Each entry is tried at most
  once per flush chain, so that follow-up doesn't retry an entry that just failed (as on Android).
- **A consent denial mid-flush stops the queue from going out.** A flush worked from a snapshot, so
  `setConsent(false)` cleared the stored queue but the running flush kept sending the cleared events.
  It now skips any entry no longer stored; only the request already in flight completes, and it is
  never re-queued.
- **A cancelled event is never queued as an offline failure.** URLSession reports a cancel as a
  transport error, which is retryable; an event whose own task was cancelled is now treated as
  cancelled (not queued, not logged, no `onError`), like one in flight during a reconfigure.
- **One unreadable queue entry no longer wipes the whole queue.** Entries are decoded one by one; a bad
  one is skipped with WARNING `Skipped a corrupt queued event: <error>` and the rest are kept; the
  cleaned queue is written back. A queue that isn't valid JSON at all is reset with the same warning
  (before, one bad entry read as an empty queue and the next write replaced it with just the new event).

## [0.0.12] - 2026-08-30

### Changed
- **A tap on `LinkTrailPasteButton` now records tracking consent.** In `.pasteButton` mode the user's
  deliberate tap on a system paste control is the affirmative act, so the install that follows is sent
  with `consent: true` and is counted — previously it went out with the consent still unset, which
  under the hold below means it would not have been sent at all. Opt out with
  `LinkTrailPasteButton(grantsConsent: false)` if your app collects consent separately (a CMP, say);
  the token is still read and replayed, the install just waits for your `setConsent(_:)`.

  Consent is persisted *before* the install, and via an internal flag-only path rather than
  `setConsent(true)` — the latter fires its own token-less install when `autoTrackInstall` is on,
  which would mark the install tracked and make the token-carrying call a silent no-op, losing the
  deterministic match the user just handed over.

- **The install is now held until the host app records a consent decision** (`LEG-009`), matching
  Android's `CONSENT_SET` gate and the cross-platform consent contract. With `requireConsent` on and
  no decision yet, `trackInstall()` makes **no network call at all** — previously it POSTed
  `/v1/events/install` with `consent:false`, which put the `deviceId`, the bundle id and an
  `Idempotency-Key: install:<deviceId>` header on the wire before the user had answered. The clipboard
  is not read while the install is held either, so `.automatic` no longer raises "Allow Paste" first.

  `setConsent(_:)` releases the hold **either way**, and both answers produce exactly one install
    (replaying a click token captured before the decision): `true` sends `consent:true`, which is
    counted and attributed; `false` sends `consent:false`, which the backend uses to resolve the deep
    link — so the user still lands in the right place — while recording nothing. A denied install
    carries **no device identifier**: `deviceId` is omitted and the `Idempotency-Key` (built from
    the same value) is not sent, since withholding the field while putting it in a header would
    be theatre — and a denied install is never counted, so there is no double-count to prevent. Sending the denial
    rather than swallowing it is what makes withheld installs countable instead of indistinguishable
    from installs that never happened. Queued custom events are still dropped on a denial: those are
    pure tracking payloads with no routing purpose. The hold is persisted, so a user who decides on a
    later launch is still attributed. "Exactly one" is enforced on the denied path by its own
    persisted one-shot (a denial can never set the counted install's flag): without it an
    auto-tracking app would re-send the `consent:false` install — and, when nothing routed,
    re-raise the `.automatic` "Allow Paste" alert — on every launch.

  > **Breaking for integrators:** an app that never calls `setConsent(_:)` now records **nothing** —
  > no install, no attribution, no deferred routing. That is the deny-by-default contract working as
  > published, but it will look like a regression if your consent prompt isn't wired to
  > `setConsent(_:)` for **both** answers. Apps that set `requireConsent: false` are unaffected.

  Deferred routing now happens *after* the answer, since the deep link is resolved by that install:
  grant and the user lands on their destination, decline and they stay put. iOS is deliberately
  stricter than Android in two places — Android still sends a routing-only `consent:false` install on
  a denial, and its `force` flag opens the gate. On iOS `trackInstall(force:)` means "send it again",
  never "send it without consent", so no public call can transmit an identifier before the decision.

## [0.0.11] - 2026-08-06

### Added
- **`clickTokenSource: .none`** — a third option alongside `.pasteButton` and `.automatic`: the SDK
  **never touches the clipboard**, by any path. No deferred click token, no iOS "Allow Paste" alert,
  and nothing to place in your UI; attribution falls back to the probabilistic (IP) match. Use it
  when your links don't stage a token (no web interstitial) or you'd rather not ask for clipboard
  access at all.

  The guarantee is enforced rather than documented: under `.none`, `trackInstall(clickToken:)`
  ignores the token it is handed and the install stays probabilistic, so a stray
  `LinkTrailPasteButton` left in the UI can't quietly re-enable clipboard reading.

  Probabilistic matching is lossy — it misses on shared IPs (offices, CGNAT, public wifi), VPNs, and
  the common case of clicking on cellular then installing on wifi, and it can occasionally match the
  *wrong* user. Only a click token gives a deterministic, IP-independent match.

  > Spelled `.none`, this shadows `Optional.none` if you store the value as
  > `LinkTrailClickTokenSource?` — write `LinkTrailClickTokenSource.none` there.

### Testing
- **12 end-to-end flows** covering `{custom domain, subdomain} × {allow, deny} × {automatic,
  pasteButton, none}`, driven entirely by Maestro against the local SDK source (Safari interstitial →
  fresh install → consent → routing). See TESTING.md in the source repo for what each covers and how to
  run an individual one.

## [0.0.10] - 2026-07-30

### Changed
- **`clickTokenSource` replaces `readClipboardOnInstall`.** Pick how the deferred `lt_click` token
  is read: `.pasteButton` (default — place a `LinkTrailPasteButton`, **no** iOS "Allow Paste" alert)
  or `.automatic` (SDK auto-reads at launch, shows the alert). *(Breaking: the
  `readClipboardOnInstall` flag is removed.)*

### Fixed
- **Re-engagement now routes without consent.** `handleDeepLink` resolves the destination via the
  public `resolve` endpoint (no `X-Api-Key`, records nothing) when consent is off, instead of
  skipping it — so the user still lands on the right screen (routing ≠ tracking).
- **Deferred link no longer suppressed after a token-less first pass.** `deferred_routed` is set
  only when a link is actually routed, so a first install with no click token (e.g. the paste was
  declined) doesn't block the real deep link that arrives once consent is granted. The clipboard is
  also not re-read once a link is routed — no redundant second "Allow Paste" alert.

## [0.0.9] - 2026-07-28

### Added
- **Deferred deep linking via the clipboard token.** The web interstitial writes `lt_click=<32-hex>`
  before the App Store; the SDK replays it as `clickId` on first launch for a deterministic,
  IP-independent install match, then clears the clipboard. Choose how it's read with
  `LinkTrailOptions(clickTokenSource:)` — `.pasteButton` (`LinkTrailPasteButton`, a `UIPasteControl`,
  no "Allow Paste" alert) or `.automatic` (SDK auto-reads at launch). Or `trackInstall(clickToken:)`.
- **Consent gating** — `LinkTrailOptions(requireConsent:)` + `LinkTrail.shared?.setConsent(_:)`.
  **On by default** and **deny-by-default**: until consent is granted the install is **not counted**,
  custom events are dropped (not queued), and re-engagement opens aren't recorded. Consent is
  persisted across launches; `setConsent(true)` sends the counted install + flushes the queue.
- **Deferred deep linking still routes without consent (Branch-style), per `CONSENT-CONTRACT.md`.**
  The install body now always carries a `consent` boolean. When consent is withheld the install is
  sent once with `consent:false`: the backend resolves the deep link for routing but **must not
  record or attribute** it, and the SDK forces `attributed:false` — so the user still lands on the
  right screen without being counted. A one-shot `deferred_routed` flag routes at most once and
  leaves the later consent-granted (counted) install unblocked.

### Changed
- **`requireConsent` now defaults to `true`.** The SDK records nothing until the host app calls
  `setConsent(true)`. Apps that gather tracking consent elsewhere can opt out with
  `LinkTrailOptions(requireConsent: false)` to restore tracking at `configure`.
- **Dropped the IDFV.** `deviceId` is now an app-scoped, per-install UUID (stored in `UserDefaults`,
  resets on uninstall). The SDK reads **no** system identifier — neither the IDFA nor the IDFV.
  Link routing is unaffected (it's driven by the `clickId` token / URL slug, not `deviceId`); only
  cross-reinstall device dedup is slightly weaker.
- `InstallRequest.clickId` is now a `String` token (was `Int`), for the `lt_click` deferred token.

## [0.0.1] - 2026-06-14

Initial release of the LinkTrail iOS SDK.

### Added
- Backend **Part B (Client SDK)** contract: `POST /v1/events/install` · `/open` · `/events`
  (authenticated with the workspace `X-Api-Key`, `lt_live_…`) and the public
  `GET /v1/links/resolve`. App resolved from bundle id; `deviceId` = IDFV.
- Install attribution returning `{ id, attributed, deepLink }`; deferred deep linking
  (`onDeferredDeepLink`); re-engagement opens (`handleDeepLink` → `/v1/events/open`); and
  server-side custom events (`trackEvent`).
- **Resilience**: exponential-backoff retries (timeouts / 5xx / 429 with `Retry-After`),
  per-request `Idempotency-Key`, a disk-backed offline event queue, and an `onError` callback.
- In-flight install de-duplication; `linkDomains` scoping for `handleDeepLink`.

### Notes
- The `deviceId` is the IDFV (no IDFA collected). Logging defaults to `.info`; sensitive
  values are `.debug`-only.
- Verified against a live backend: link resolution works; full install E2E pending an SDK key
  (backend app-provisioning is currently failing on its side).
- Universal Link / custom-scheme handling (`handleDeepLink`) with server slug resolution.
- App Tracking Transparency authorization + IDFA capture.
- SKAdNetwork / AdAttributionKit registration and conversion-value updates.
- Callback **and** `async/await` public APIs.
- ATT-gated, Keychain-backed device identity (per-install `UserDefaults` id when tracking
  is not authorized, so unauthorized users are not re-identified across reinstalls).
- Quiet-by-default logging (`.info`); deep-link URLs and campaign data log at `.debug` only.
- `PrivacyInfo.xcprivacy` privacy manifest.
- 52 unit tests; clean iOS and macOS builds.
