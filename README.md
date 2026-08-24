# LinkTrail iOS SDK

Mobile **attribution** and **deferred deep linking** for iOS. Distributed as a **binary
XCFramework** — the module name is `LinkTrailSDK`, the entry point is `LinkTrail`. The counterpart
of the [LinkTrail Android SDK](https://github.com/linktrail-io/android-sdk).

- **Module:** `LinkTrailSDK` (Swift Package Manager · CocoaPods) · **iOS:** 15+

## Install

### Swift Package Manager

In Xcode: **File → Add Package Dependencies…** → paste this repo's URL → pick a version. Or in a
`Package.swift`:

```swift
.package(url: "https://github.com/linktrail-io/ios-sdk.git", from: "0.0.11")
```

### CocoaPods

```ruby
pod 'LinkTrailSDK', '~> 0.0.11'
```

Then run `pod install` and open the generated `.xcworkspace`.

## Quick start

```swift
import LinkTrailSDK

// At launch (SwiftUI App.init or AppDelegate). The API key is required — configure throws.
try LinkTrail.configure(apiKey: "lt_live_…")

// One hook handles both first-launch (deferred) AND re-engagement links:
LinkTrail.shared?.onLink { link, source in
    router.route(to: link.path, customData: link.customData)   // e.g. "/products/aj1" + ["voucher": "SUMMER25"]
}

// Consent gating is ON by default, so this call is part of the integration, not an extra:
// record the user's answer to your consent prompt. Until it's granted, links route but
// nothing is attributed. See "Consent gating" below.
LinkTrail.shared?.setConsent(true)    // call from your prompt's "Accept"; false on decline

// Observe failures if you want:
LinkTrail.shared?.onError { error in /* e.g. LinkTrailError.invalidAPIKey */ }
```

The install is tracked automatically by `configure`. Forward incoming links (see
[Deep-link setup](#deep-link-setup) for the wiring).

> **⚠️ Integration isn't finished until you call `setConsent(...)`.** `requireConsent` defaults to
> **`true`** and consent is **deny-by-default**, so an app that only calls `configure` + `onLink`
> builds cleanly, routes every deep link correctly, fires no error — and records **zero
> attribution**, permanently. Wire up [Consent gating](#consent-gating), or opt out explicitly with
> `LinkTrailOptions(requireConsent: false)` if your app already collects tracking consent elsewhere.

Every callback API also has an `async throws` twin (`trackInstall`, `handleDeepLink`, `trackEvent`).
Callbacks are delivered on the main thread.

## Consent gating

Consent gating is **on by default** (`requireConsent: true`) and follows the "links work, tracking
waits" model: until the user consents, **deep links still route** — deferred and re-engagement links
reach their destination via `onLink` — but **no attribution is recorded**. The install is sent with
`consent: false`, so the backend resolves the link for routing yet stores nothing, exposes no
attribution, and drops events. Consent is **deny-by-default**: an unset flag counts as no consent,
never as "granted".

When the user accepts your consent prompt, grant it:

```swift
LinkTrail.shared?.setConsent(true)    // sends the counted install + flushes the offline event queue
```

This attributes the install and flushes the queue **without re-routing** a user already sent to
their screen. Revoke (or record a refusal) with `setConsent(false)`, which clears the event queue.
The answer is **persisted across launches** — once granted, a later launch's install is counted at
`configure`. The flow:

1. `configure(...)` — links route immediately; the install is held **unattributed** (`consent: false`).
2. User accepts → `setConsent(true)` → the counted install is sent, queued events flush.
3. User declines → `setConsent(false)` (or do nothing); routing keeps working, nothing is tracked.

While consent is unset **or** denied, the SDK behaves like this:

| | Behaviour |
|---|---|
| Install | **Sent once with `consent: false`** — resolved for routing, but not recorded or attributed (the SDK forces `attributed: false`). The counted-install flag stays unset, so the real install still fires after consent. |
| Deferred deep link | **Routed once** from that same response, so the user lands on the right screen. |
| `trackEvent(...)` | **Dropped — not sent and not queued.** Events fired before consent are gone; they do *not* replay on `setConsent(true)`. |
| `handleDeepLink(...)` | **Not recorded** — the open is resolved via the public endpoint (no API key) so the user is still routed. |

To attribute at init with no gate, opt out:

```swift
try LinkTrail.configure(
    apiKey: "lt_live_…",
    options: LinkTrailOptions(requireConsent: false)   // tracks at configure; setConsent is never consulted
)
```

Separately, `autoTrackInstall: false` defers the install call entirely so you can send it yourself:

```swift
let linkTrail = try LinkTrail.configure(
    apiKey: "lt_live_…",
    options: LinkTrailOptions(autoTrackInstall: false)
)

// … later, once the user has answered your consent prompt:
linkTrail.setConsent(true)   // unlocks the gate — but does NOT send the install here
linkTrail.trackInstall()     // …so send it yourself
```

> **With `autoTrackInstall: false`, `setConsent(true)` does not send the install for you** — it only
> opens the gate. Call `trackInstall()` yourself, or let `LinkTrailPasteButton` do it on tap (it
> calls `trackInstall(clickToken:)`). This pairing is easy to hit by accident, because the default
> `clickTokenSource` is `.pasteButton`, whose recommended pairing *is* `autoTrackInstall: false` —
> see [Deferred attribution](#deferred-attribution--how-the-click-token-is-read).

## More

```swift
// Custom post-install events:
LinkTrail.shared?.trackEvent(name: "purchase", value: 59.99, currency: "USD")

// Cached results:
let attribution = LinkTrail.shared?.lastAttribution
let lastLink = LinkTrail.shared?.lastDeepLink

// Attribution stream (fires when an install is attributed):
LinkTrail.shared?.onAttribution { attribution in /* … */ }

// Consent — required before anything is recorded (see "Consent gating"):
LinkTrail.shared?.setConsent(true)

// ATT / SKAdNetwork:
await LinkTrail.shared?.requestTrackingAuthorization()
LinkTrail.shared?.registerForSKAdAttribution()
LinkTrail.shared?.updateConversionValue(42, coarseValue: .medium)
```

### `LinkTrailOptions`

Every option, with the default it takes when you don't pass one. You normally don't pass `options`
at all — but note that the two defaults that decide whether anything is recorded, `requireConsent`
and `autoTrackInstall`, are both `true`.

| Option | Default | What it does |
|---|---|---|
| `requireConsent` | **`true`** | Gates all recording behind `setConsent(true)` — **on by default**, deny-by-default. See [Consent gating](#consent-gating). `false` tracks from `configure`. |
| `autoTrackInstall` | **`true`** | `configure` sends the install for you. `false` defers it until you call `trackInstall()` (or a `LinkTrailPasteButton` tap does). |
| `clickTokenSource` | `.pasteButton` | How the deferred `lt_click` token is read — see [Deferred attribution](#deferred-attribution--how-the-click-token-is-read). |
| `logEnabled` | `false` | Master switch for SDK logging; silent unless you opt in. |
| `logLevel` | `.info` | Minimum severity emitted when logging is on. |
| `requestTimeout` | `15` | Per-request network timeout, in seconds. |
| `retryPolicy` | `.default` | 3 attempts with backoff; `.disabled` turns retries off. |
| `linkDomains` | `[]` (all) | Hosts to treat as yours in `handleDeepLink` — see [Deep-link setup](#deep-link-setup). |

## Deferred attribution — how the click token is read

iOS has no install referrer, so a deterministic install match depends on a `lt_click` token the web
interstitial leaves on the clipboard. `clickTokenSource` decides how (or whether) the SDK reads it:

```swift
LinkTrailOptions(clickTokenSource: .pasteButton)   // default
```

- **`.pasteButton`** (default, **no alert**) — your app places a `LinkTrailPasteButton` (Apple's
  `UIPasteControl`); the user's tap *is* the consent, so iOS shows no "Allow Paste" alert. Pair it
  with `autoTrackInstall: false` so the install waits for the tap.

  ```swift
  if #available(iOS 16.0, *) {
      LinkTrailPasteButton()   // reads the token on tap → trackInstall(clickToken:)
  }
  ```

- **`.automatic`** (**shows the alert**) — the SDK reads the clipboard itself at install. Nothing to
  add to your UI, but iOS shows the system **"Allow Paste"** alert on first launch.

- **`.none`** (**never touches the clipboard**) — no token, no alert, nothing to add to your UI;
  attribution is purely probabilistic. Use it when your links don't stage a token (no web
  interstitial), or when you'd rather not ask for clipboard access at all. The guarantee holds
  however the SDK is called: under `.none`, `trackInstall(clickToken:)` ignores the token it's
  handed, so a stray paste button can't quietly re-enable clipboard reads.

If there's no token, attribution falls back to the probabilistic IP path. You can also hand a pasted
string in yourself with `trackInstall(clickToken:)`.

> **Probabilistic matching is lossy.** It misses on shared IPs (offices, CGNAT, public wifi), VPNs,
> and the common case of clicking on cellular then installing on wifi — and it can occasionally match
> the *wrong* user, so treat deferred link content as best-effort personalization. Only a click token
> gives a deterministic, IP-independent match.

## Deep-link setup

Declare your LinkTrail host as a Universal Link and forward incoming URLs to the SDK.

- Add the **Associated Domains** capability with `applinks:kick.linktrail.io`.
- Forward links from your SwiftUI `App` (or the equivalent `AppDelegate`/`SceneDelegate` hooks):

  ```swift
  .onOpenURL { LinkTrail.shared?.handleDeepLink($0) }
  .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
      if let url = activity.webpageURL { LinkTrail.shared?.handleDeepLink(url) }
  }
  ```

- For a custom scheme, add it under `CFBundleURLTypes` in `Info.plist`.

LinkTrail infra hosts the `apple-app-site-association` file for your link domains.

**List every link host in `linkDomains`.** When `linkDomains` is non-empty, the SDK routes
re-engagement opens (app already installed) *only* for those hosts — a link on an unlisted host
opens the app but never navigates. Deferred (install-time) links skip this check and route
regardless, so a missing host can look fine on a fresh install yet fail once the app is installed.
Leave `linkDomains` empty (the default) to handle every parseable link.

## Example app

[`example/`](example/) is **KickFlip**, a small SwiftUI storefront that shows deferred deep linking
end to end — it consumes this package's binary exactly as your app would. A link button fires the
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
