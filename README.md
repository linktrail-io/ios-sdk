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
.package(url: "https://github.com/linktrail-io/ios-sdk.git", from: "0.0.8")
```

### CocoaPods

```ruby
pod 'LinkTrailSDK', '~> 0.0.8'
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
