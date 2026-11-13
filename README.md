# LinkTrail iOS SDK

Mobile **attribution** and **deferred deep linking** for iOS. Distributed as a **binary
XCFramework** — the module name is `LinkTrailSDK`, the entry point is `LinkTrail`. The counterpart
of the [LinkTrail Android SDK](https://github.com/linktrail-io/android-sdk).

- **Module:** `LinkTrailSDK` (Swift Package Manager · CocoaPods) · **iOS:** 15+

## TL;DR

Mobile attribution + deferred deep linking: click a tracking link → App Store → install → the first
launch routes straight to the linked content, campaign context intact. Resilient by design —
exponential-backoff retries, an offline event queue, idempotency keys, in-flight install
coalescing, persisted attribution — with both callback and `async/await` APIs.

**Consent is deny-by-default** (`requireConsent: true`) and is the defining behaviour:

| Decision | Install request |
|---|---|
| not yet made | **held**, persisted across launches — no call at all, and the clipboard isn't read |
| granted (`setConsent(true)`) | sent with `consent: true` — counted and attributed |
| denied (`setConsent(false)`) | sent once with `consent: false` — the deep link still resolves so the user lands correctly, nothing is recorded, and **no device identifier is sent** (neither `deviceId` nor the `Idempotency-Key` derived from it) |

Also gated: custom events are dropped and re-engagement opens aren't recorded — the user is still
routed. `force` does **not** bypass the gate; it means "send it again", never "send it early". An
app that never calls `setConsent(_:)` sends nothing at all — call it once your consent UI resolves,
or opt out with `requireConsent: false` if consent is handled elsewhere.

**Deferred click token.** iOS has no install referrer, so the web interstitial leaves
`lt_click=<32-hex>` on the clipboard for the SDK to replay on first launch. `clickTokenSource`:

| | Behaviour |
|---|---|
| `.pasteButton` *(default)* | your app renders `LinkTrailPasteButton` — no system alert, and the tap **also records consent** while it is still undecided (an earlier `setConsent(false)` stands; `grantsConsent: true` overrides it, `false` never touches consent) |
| `.automatic` | the SDK reads the clipboard itself → iOS shows **"Allow Paste"** |
| `.none` | the clipboard is never touched, by any path — even `trackInstall(clickToken:)` ignores a token handed to it |

The token is consumed once (pasteboard cleared), held across the consent decision, and replayed
with whichever install eventually goes out.

**Routing ≠ tracking.** A user who declines — or hasn't answered — still reaches the right screen;
only the recording is withheld.

## Install

### Swift Package Manager

In Xcode: **File → Add Package Dependencies…** → paste this repo's URL → pick a version. Or in a
`Package.swift`:

```swift
.package(url: "https://github.com/linktrail-io/ios-sdk.git", from: "0.2.0")
```

### CocoaPods

```ruby
pod 'LinkTrailSDK', '~> 0.2.0'
```

Then run `pod install` and open the generated `.xcworkspace`.

Upgrading from 0.0.12? 0.1.0 has breaking changes (`linkDomains`, the paste button's consent
default, the `configure` singleton, denial semantics): see
[CHANGELOG.md](CHANGELOG.md#upgrading-from-0012). Release notes for every version are in
[CHANGELOG.md](CHANGELOG.md).

## Quick start

```swift
import LinkTrailSDK

// At launch (SwiftUI App.init or AppDelegate). The API key is required — configure throws.
try LinkTrail.configure(apiKey: "lt_live_…")

// One hook handles both first-launch (deferred) AND re-engagement links:
LinkTrail.shared?.onLink { link, source in
    router.route(to: link.path, customData: link.customData)   // e.g. "/products/aj1" + ["voucher": "SUMMER25"]
}

// Observe failures if you want:
LinkTrail.shared?.onError { error in /* e.g. LinkTrailError.invalidApiKey */ }
```

The install is tracked automatically by `configure`. Forward incoming links (see
[Deep-link setup](#deep-link-setup) for the wiring).

Every callback API also has an `async throws` twin (`trackInstall`, `handleDeepLink`, `trackEvent`).
Callbacks are delivered on the main thread.

## More

```swift
// Custom post-install events:
LinkTrail.shared?.trackEvent(name: "purchase", value: 59.99, currency: "USD")

// Cached results:
let attribution = LinkTrail.shared?.lastAttribution
let lastLink = LinkTrail.shared?.lastDeepLink

// Attribution stream (fires when an install is attributed):
LinkTrail.shared?.onAttribution { attribution in /* … */ }

// Consent (on by default, deny-by-default): the install is HELD — nothing leaves the
// device — until your app records a decision. Each answer sends exactly one install:
LinkTrail.shared?.setConsent(true)    // grant → counted, attributed
LinkTrail.shared?.setConsent(false)   // deny → sent once with consent:false, no device id, recorded nowhere
// A denial wins even with requireConsent: false. Collecting consent elsewhere? Opt out of the
// hold with LinkTrailOptions(requireConsent: false); tracking then runs at configure().

// ATT / SKAdNetwork:
await LinkTrail.shared?.requestTrackingAuthorization()
LinkTrail.shared?.registerForSKAdAttribution()
LinkTrail.shared?.updateConversionValue(42, coarseValue: .medium)
```

`LinkTrailOptions` also takes `logEnabled`, `logLevel`, `requestTimeout`, `retryPolicy`, and
`linkDomains`.

## Deferred attribution — how the click token is read

iOS has no install referrer, so a deterministic install match depends on a `lt_click` token the web
interstitial leaves on the clipboard. `clickTokenSource` decides how (or whether) the SDK reads it:

```swift
LinkTrailOptions(clickTokenSource: .pasteButton)   // default
```

- **`.pasteButton`** (default, **no alert**) — your app places a `LinkTrailPasteButton` (Apple's
  `UIPasteControl`); the tap *is* the clipboard permission, so iOS shows no "Allow Paste" alert. Pair
  it with `autoTrackInstall: false` so the install waits for the tap.

  The tap also grants tracking consent, but only while consent is still undecided:
  `grantsConsent` is `Bool?` and defaults to `nil`, so a user who already declined with
  `setConsent(false)` stays declined. Pass `grantsConsent: true` to always grant on tap, or `false`
  to never touch consent.

  ```swift
  if #available(iOS 16.0, *) {
      LinkTrailPasteButton()                        // grants consent only while undecided
      // LinkTrailPasteButton(grantsConsent: false) // read the token, leave consent alone
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

## Deferred deep links — delivery

When the install resolves a deferred link, the SDK hands it to `onLink` with `source == .deferred`.
Register `onLink` whenever suits your app (after a splash, onboarding or login screen):

- The link is **saved on the device** until a handler has been called with it. If `onLink` isn't set
  yet, it's delivered (on the main thread) as soon as you set it, in the same launch or a later one,
  even if the app was killed or `configure` was called again in between.
- Delivery is **at least once**: the saved link is removed only after your handler returns.
- A saved link **older than 7 days** is dropped and never delivered.
- The **first** deferred link wins; the install itself is never re-sent.
- With consent required, the deferred link is resolved by the install, so routing happens **after**
  the answer: grant and the user lands on their destination; decline and the denial install still
  routes them, with nothing recorded.

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

LinkTrail infra hosts the `apple-app-site-association` file for your link domains.

### Which URLs `handleDeepLink` claims

`handleDeepLink(_:)` claims a URL only when it is a LinkTrail link:

1. the scheme is `https`;
2. the host is `linktrail.io` or one of its subdomains (`kick.linktrail.io`), or a host you list in
   `linkDomains`, or one of its subdomains;
3. the path has a slug (`https://kick.linktrail.io/summer`, not `https://kick.linktrail.io/`).

Anything else (`myapp://settings`, `mailto:`, OAuth callbacks, your website's Universal Links)
returns `false` (the async call throws `LinkTrailError.notALinkTrailURL`) with no network call and no
`onError`, so route it yourself:

```swift
.onOpenURL { url in
    if LinkTrail.shared?.handleDeepLink(url) == true { return }   // a LinkTrail link: onLink routes it
    router.handle(url)                                           // everything else is yours
}
```

Custom-scheme LinkTrail links (`myapp://slug`) are not handled; use the `https` link.

**Custom domains must be listed in `linkDomains`.** If your links use your own domain (e.g.
`go.acme.com`), pass it at configure, or those links are not handled:

```swift
try? LinkTrail.configure(apiKey: "lt_live_…",
                         options: LinkTrailOptions(linkDomains: ["go.acme.com"]))
```

Entries are normalised (`https://Go.Acme.com:443/x` → `go.acme.com`); a blank or invalid entry is
ignored with a warning.

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

## Wrapper SDKs

`LinkTrail.setSDKIdentifier(platform:version:)` is for the React Native and Flutter wrappers, so
the `X-LinkTrail-SDK` header reports e.g. `flutter/0.1.1` instead of `ios/0.2.0`. Apps should not
call it.

## License

Copyright © 2026 LinkTrail. All rights reserved. See [LICENSE](LICENSE).
