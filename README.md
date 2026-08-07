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

// Consent-gated install (defer configure's auto-track, then call manually):
let lt = try LinkTrail.configure(apiKey: "lt_live_…", options: LinkTrailOptions(autoTrackInstall: false))
lt.trackInstall()

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
cd example && xcodegen generate && open KickFlipDemo.xcodeproj
```

Set your `lt_live_…` key in `KickFlipDemo/SDK/AttributionCoordinator.swift`; without one it routes
the simulator's links locally. See [example/README.md](example/README.md).

## License

Copyright © 2026 LinkTrail. All rights reserved. See [LICENSE](LICENSE).
