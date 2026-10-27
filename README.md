# LinkTrail iOS SDK

Mobile **attribution** and **deferred deep linking** for iOS. Distributed as a **binary
XCFramework**. The module name is `LinkTrailSDK` and the entry point is `LinkTrail`. The counterpart
of the [LinkTrail Android SDK](https://github.com/linktrail-io/android-sdk).

- **Version:** 0.1.0 · **Module:** `LinkTrailSDK` (Swift Package Manager · CocoaPods)
- **Requires:** iOS 15+ · Swift 5.9+ / Xcode 15+
- **Docs:** [docs.linktrail.io](https://docs.linktrail.io) ·
  **Release notes:** [GitHub releases](https://github.com/linktrail-io/ios-sdk/releases)

## TL;DR

Mobile attribution + deferred deep linking: click a tracking link → App Store → install → the first
launch routes straight to the linked content, campaign context intact. Resilient by design:
exponential-backoff retries, an offline event queue, idempotency keys, in-flight install
coalescing and persisted attribution, with both callback and `async/await` APIs.

**Consent is deny-by-default** (`requireConsent: true`) and is the defining behaviour:

| Decision | Install request |
|---|---|
| not yet made | **held**, persisted across launches: no call at all, and the clipboard isn't read |
| granted (`setConsent(true)`) | sent with `consent: true`: counted and attributed |
| denied (`setConsent(false)`) | sent once with `consent: false`: the deep link still resolves so the user lands correctly, nothing is recorded, and **no device identifier is sent** (neither `deviceId` nor the `Idempotency-Key` derived from it) |

Also gated: custom events are dropped and re-engagement opens aren't recorded, but the user is still
routed. `force` does **not** bypass the gate; it means "send it again", never "send it early". An
app that never calls `setConsent(_:)` sends nothing at all, so call it once your consent UI resolves,
or opt out with `requireConsent: false` if consent is handled elsewhere. **A denial always wins:**
`setConsent(false)` applies even with `requireConsent: false`.

**Deferred click token.** iOS has no install referrer, so the web interstitial leaves
`lt_click=<32-hex>` on the clipboard for the SDK to replay on first launch. `clickTokenSource`:

| | Behaviour |
|---|---|
| `.pasteButton` *(default)* | your app renders `LinkTrailPasteButton`: no system alert, and the tap **also records consent while it is undecided** (an earlier `setConsent(false)` stands; `grantsConsent: true` overrides it, `false` never touches consent) |
| `.automatic` | the SDK reads the clipboard itself → iOS shows **"Allow Paste"**, at most once (never after the install is tracked) |
| `.none` | the clipboard is never touched, by any path: even `trackInstall(clickToken:)` ignores a token handed to it |

The token is consumed once (pasteboard cleared), held across the consent decision and across a
failed request, and replayed with whichever install eventually goes out. Only a clipboard holding
exactly `lt_click=<32-hex>` is used and cleared; text that merely contains a token is left alone.

**Routing ≠ tracking.** A user who declines, or hasn't answered, still reaches the right screen;
only the recording is withheld.

## Install

### Swift Package Manager

In Xcode: **File → Add Package Dependencies…** → paste this repo's URL → pick a version. Or in a
`Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/linktrail-io/ios-sdk.git", from: "0.1.0")
],
targets: [
    .target(name: "YourApp", dependencies: [.product(name: "LinkTrailSDK", package: "ios-sdk")])
]
```

### CocoaPods

```ruby
pod 'LinkTrailSDK', '~> 0.1.0'
```

Then run `pod install` and open the generated `.xcworkspace`.

Upgrading from 0.0.12? Read [Upgrading to 0.1.0](#upgrading-to-010) first: 0.1.0 has breaking
changes.

## Quick start

```swift
import LinkTrailSDK

// At launch (SwiftUI App.init or AppDelegate). The API key is required: configure throws
// LinkTrailError.missingAPIKey if it is blank.
try LinkTrail.configure(apiKey: "lt_live_…")

// One hook handles both first-launch (deferred) AND re-engagement links:
LinkTrail.shared?.onLink { link, source in
    router.route(to: link.path, customData: link.customData)   // e.g. "/products/aj1" + ["voucher": "SUMMER25"]
}

// Observe failures if you want:
LinkTrail.shared?.onError { error in /* e.g. LinkTrailError.invalidAPIKey (401) */ }
```

The install is tracked automatically by `configure` (held until the user's consent decision, see
[Consent](#consent)). Forward incoming links (see [Deep-link setup](#deep-link-setup) for the
wiring).

Every callback API also has an `async throws` twin (`trackInstall`, `handleDeepLink`, `trackEvent`).
Callbacks are delivered on the main thread.

### `configure` is a singleton

- A repeat call with the **same key and equal options** is a no-op that returns the existing
  instance (`linkDomains` compare as a set, so a reordered list is still a no-op).
- A call with a **different key or options** shuts the previous instance down (its pending work is
  cancelled and its callbacks are dropped) and returns a new one. **Re-register** `onLink`,
  `onAttribution` and `onError` on the returned instance.
- Don't keep a reference to an old instance: every call on a replaced instance is ignored.
- Persisted state (install flags, consent, device id) is untouched by a reconfigure.

## More

```swift
// Custom post-install events:
LinkTrail.shared?.trackEvent(name: "purchase", value: 59.99, currency: "USD")

// Cached results:
let attribution = LinkTrail.shared?.lastAttribution
let lastLink = LinkTrail.shared?.lastDeepLink

// Attribution stream (fires for every install, attributed or organic):
LinkTrail.shared?.onAttribution { attribution in /* … */ }

// ATT / SKAdNetwork:
await LinkTrail.shared?.requestTrackingAuthorization()
LinkTrail.shared?.registerForSKAdAttribution()
LinkTrail.shared?.updateConversionValue(42, coarseValue: .medium)

// The SDK version:
LinkTrail.version   // "0.1.0"
```

`LinkTrailOptions` also takes `logEnabled`, `logLevel`, `requestTimeout`, `retryPolicy`,
`autoTrackInstall` and `linkDomains`. Out-of-range values (`maxAttempts < 1`, non-positive delays
or `requestTimeout`) are clamped at `configure` with a WARNING, never thrown.

Custom events that fail with a transport error, 408, 429 or 5xx are queued and retried. Any other
status (400, 401, 403, 404, 409, 422, …) is reported to `onError` and dropped.

## Consent

```swift
LinkTrail.shared?.setConsent(true)    // grant → sends the held install (counted, attributed) + flushes queued events
LinkTrail.shared?.setConsent(false)   // deny → sent once with consent: false, no device id, recorded nowhere; drops queued events
// Collecting consent elsewhere? Opt out: LinkTrailOptions(requireConsent: false)
```

The hold is **persisted**, so a user who decides on a later launch is still attributed, with the
click token captured before the decision. Because the deferred link is resolved by that install,
routing happens **after** the answer.

> **You must call `setConsent(_:)`.** An app that never calls it records nothing at all. That is
> the intended deny-by-default behaviour, not a bug.

The SDK's state (including the consent answer) lives in a device-only file that is **excluded from
iCloud and device backups**. A restore onto a new phone, or a reinstall from a backup, starts fresh
and the consent question has to be asked again. Show your consent UI whenever the SDK has no answer,
not only on the very first launch.

## Deferred attribution: how the click token is read

iOS has no install referrer, so a deterministic install match depends on a `lt_click` token the web
interstitial leaves on the clipboard. `clickTokenSource` decides how (or whether) the SDK reads it:

```swift
LinkTrailOptions(clickTokenSource: .pasteButton)   // default
```

- **`.pasteButton`** (default, **no alert**): your app places a `LinkTrailPasteButton` (Apple's
  `UIPasteControl`); the user's tap *is* the permission, so iOS shows no "Allow Paste" alert. Pair it
  with `autoTrackInstall: false` so the install waits for the tap.

  ```swift
  if #available(iOS 16.0, *) {
      LinkTrailPasteButton()   // reads the token on tap → trackInstall(clickToken:)
  }
  ```

  `grantsConsent` is a `Bool?`:

  | `grantsConsent` | The tap… |
  |---|---|
  | `nil` *(default)* | grants consent **only while it is still undecided**; a user who already declined stays declined |
  | `true` | always grants consent, overriding an earlier denial |
  | `false` | never touches consent (your app collects it separately) |

  After a denial the token is still used for routing: it goes out with the `consent: false` install
  (no device id, not counted), or, if that install already went out, it is held and sent with the
  counted install if the user grants consent later.

- **`.automatic`** (**shows the alert**): the SDK reads the clipboard itself at install. Nothing to
  add to your UI, but iOS shows the system **"Allow Paste"** alert on first launch.

- **`.none`** (**never touches the clipboard**): no token, no alert, nothing to add to your UI;
  attribution is purely probabilistic. Use it when your links don't stage a token (no web
  interstitial), or when you'd rather not ask for clipboard access at all. Under `.none`,
  `trackInstall(clickToken:)` ignores the token it's handed, so a stray paste button can't quietly
  re-enable clipboard reads.

If there's no token, attribution falls back to the probabilistic IP path. You can also hand a pasted
string in yourself with `trackInstall(clickToken:)`.

> **Probabilistic matching is lossy.** It misses on shared IPs (offices, CGNAT, public wifi), VPNs,
> and the common case of clicking on cellular then installing on wifi, and it can occasionally match
> the *wrong* user, so treat deferred link content as best-effort personalization. Only a click token
> gives a deterministic, IP-independent match.

## Deferred deep links

When the install resolves a deferred link, the SDK hands it to `onLink` with `source == .deferred`.
You can register `onLink` whenever suits your app, for example after a splash, onboarding or login
screen:

- The link is **saved on the device** until a handler has been called with it. If `onLink` isn't
  set yet, it's delivered (on the main thread) as soon as you set it, in the same launch or a later
  one, even if the app was killed or `configure` was called again in between.
- Delivery is **at least once**: the saved link is removed only after your handler returns, so if
  the app crashes inside the handler, the link is delivered once more on the next launch. Make your
  routing idempotent.
- A saved link that is **older than 7 days** is dropped and never delivered.
- The **first** deferred link wins: while one is waiting for `onLink`, a later install doesn't
  replace it.
- The install itself is never re-sent; only the delivery is retried.

## Deep-link setup

Declare your LinkTrail host as a Universal Link and forward incoming URLs to the SDK.

- Add the **Associated Domains** capability with `applinks:<your-link-host>` (for example
  `applinks:kick.linktrail.io`). LinkTrail hosts the `apple-app-site-association` file for your link
  domains.
- Forward links from your SwiftUI `App` (or the equivalent `AppDelegate`/`SceneDelegate` hooks):

  ```swift
  .onOpenURL { url in
      if LinkTrail.shared?.handleDeepLink(url) == true { return }   // a LinkTrail link: onLink routes it
      router.handle(url)                                           // everything else is yours
  }
  .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
      if let url = activity.webpageURL, LinkTrail.shared?.handleDeepLink(url) != true {
          router.handle(url)
      }
  }
  ```

### Which links the SDK claims

`handleDeepLink(_:)` claims a URL only when it is a LinkTrail link:

1. the scheme is `https`;
2. the host (lowercased, port and trailing dot ignored, internationalised names compared in
   punycode) is `linktrail.io` or one of its subdomains (`kick.linktrail.io`), or a host you list in
   `linkDomains`, or one of its subdomains. Malformed or look-alike hosts (`\` or `%` in the
   authority, user-info tricks, a bad port) are never claimed;
3. the path has a slug (`https://kick.linktrail.io/summer`, not `https://kick.linktrail.io/`).

Anything else (your own `myapp://settings`, `mailto:`, OAuth callbacks, your website's Universal
Links) returns `false` (the async call throws `LinkTrailError.notALinkTrailURL`) with no network
call and no `onError`.

### `linkDomains`: list every custom domain

`*.linktrail.io` links are always claimed. **Every custom link domain must be listed** in
`linkDomains`, or its links are not handled. An empty `linkDomains` (the default) means "only
`*.linktrail.io`", **not** "every link".

```swift
try LinkTrail.configure(apiKey: "lt_live_…",
                        options: LinkTrailOptions(linkDomains: ["go.acme.com"]))
```

Entries are normalised (`https://Go.Acme.com:443/x` → `go.acme.com`), deduped and sorted. An empty
or invalid entry (blank, wildcard, empty label, space, bracketed IPv6) is ignored with a WARNING.

### Custom URL schemes

The SDK only claims `https` LinkTrail links. A custom scheme (`myapp://…`) is your own routing:
register it under `CFBundleURLTypes` if your app needs one, and handle it yourself. To open a
LinkTrail link in the app, use its `https` URL.

## Upgrading to 0.1.0

0.1.0 has breaking changes (a `0.x` minor bump). Check each one against your integration:

1. **Custom link domains must be listed in `linkDomains`.** `handleDeepLink` now claims only `https`
   links on `linktrail.io` (or a subdomain) or on a `linkDomains` entry (or a subdomain). Before, an
   empty `linkDomains` claimed any URL with a path. Links on `*.linktrail.io` need no change; for a
   custom domain:

   ```swift
   // 0.0.12: LinkTrailOptions()  (empty linkDomains handled every link)
   // 0.1.0:
   LinkTrailOptions(linkDomains: ["go.acme.com"])
   ```

   Custom-scheme LinkTrail links (`myapp://slug`) are no longer handled; use the `https` link.
2. **`LinkTrailPasteButton` no longer grants consent after a denial.** `grantsConsent` is now
   `Bool?`, default `nil`. Pass `grantsConsent: true` for the old "the tap always grants" behaviour.
3. **`LinkTrail.configure` is a singleton.** Re-register callbacks on the instance a reconfigure
   returns. See [`configure` is a singleton](#configure-is-a-singleton).
4. **`setConsent(false)` wins even with `requireConsent: false`.** A denial always sends one
   `consent: false` install with no device id and drops custom events.
5. **Invalid options are clamped at `configure`**, not in `LinkTrailRetryPolicy.init`, which now
   stores the values you pass.
6. **`LinkTrailRetryPolicy.disabled.baseDelay` is `0.5`** (was `0`). No behaviour change.
7. **Log format.** Every line is `[LinkTrail] [LEVEL] <message>`; the `WARN` level is now `WARNING`,
   and logged URLs drop their query and fragment. Update any log filters.
8. **SDK state is no longer backed up.** It moves from `UserDefaults` to a device-only file on the
   first launch (automatic). A restored or new phone starts fresh and must ask for consent again.
9. **Stricter clipboard token.** The pasteboard is used only when its whole content is
   `lt_click=<32 hex>`.
10. **Rejected events are dropped, not queued.** A non-retryable status still reaches `onError`, but
    the event is no longer retried on later launches.

Full notes: [0.1.0 release](https://github.com/linktrail-io/ios-sdk/releases/tag/0.1.0).

## Testing

Reset the SDK in a debug build to replay a first launch:

```swift
#if DEBUG
LinkTrail.resetForTesting()   // clears all SDK state: install flags, cached attribution, saved deferred link,
                              // queued events, consent, held install + click token, clipboard-read flag, device id
LinkTrail.shared?.setConsent(true)            // the reset cleared the decision; the install is held without it
LinkTrail.shared?.trackInstall(force: true)   // force a fresh install event
#endif
```

Then create a link in the LinkTrail dashboard, open `https://<host>/<slug>` once (registers a
click), and launch the app: `onLink` should fire with `source == .deferred` and that link's path.
Turn on `logEnabled: true` to watch each step in the console.

The SDK always talks to LinkTrail's production backend. There is no base-URL option, and the
published framework can't be pointed at another backend.

More testing tips: [docs.linktrail.io](https://docs.linktrail.io).

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `configure` throws `.missingAPIKey` | The key is blank or whitespace (local check) |
| `onError` / async throws `.invalidAPIKey` | The backend rejected the key (401): unknown, revoked, or not authorized for this app |
| `404 No app found for this identifier` | The app's bundle id isn't registered in the key's workspace |
| Nothing is sent; log shows `Install held — awaiting consent decision` | Expected: consent is required by default. Call `setConsent(_:)` (or set `requireConsent: false`) |
| A custom-domain link opens the app but never routes (`Not a LinkTrail link — ignoring`) | The host isn't in `linkDomains`. List every custom domain |
| Install always `attributed: false` | No matching click (open the link first), or click/install IPs don't line up |
| `onLink` (deferred) never fires | The install was organic (no matching click), the user hasn't answered consent yet, or `path` is `/` |
| Universal Link opens Safari, not the app | Associated Domains entitlement not set for that host |
| No logs at all | Expected: the SDK is silent by default. Set `logEnabled: true` to debug |

More: [docs.linktrail.io/troubleshooting](https://docs.linktrail.io/troubleshooting).

## Example app

[`example/`](example/) is **KickFlip**, a small SwiftUI storefront that shows deferred deep linking
end to end. It consumes this package's binary exactly as your app would. A link button fires the
four scenarios (home · category · product · product + voucher). Requires
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
cd example && LINKTRAIL_KEY=lt_live_… xcodegen generate && open KickFlipDemo.xcodeproj
```

The key is baked into `Info.plist` at build time, so it never has to be written into a source file;
without one the demo still routes the simulator's links locally. Add
`LINKTRAIL_TOKEN_SOURCE=automatic|pasteButton|none` to try each deferred-token mode. See
[example/README.md](example/README.md).

## License

Copyright © 2026 LinkTrail. All rights reserved. See [LICENSE](LICENSE).
