# LinkTrail iOS SDK

Mobile attribution and deferred deep linking for iOS. Distributed as a **binary XCFramework** —
the module name is `LinkTrailSDK`; the API type is `LinkTrail`.

## Install (Swift Package Manager)

In Xcode: **File → Add Package Dependencies…** → paste this repo's URL → pick a version.

Or in a `Package.swift`:

```swift
.package(url: "https://github.com/linktrail-io/ios-sdk.git", from: "0.0.1")
```

Requires iOS 15+.

## Quick start

```swift
import LinkTrailSDK

// At launch (SwiftUI App.init or AppDelegate). The API key is required.
try LinkTrail.configure(apiKey: "lt_live_…")

// One hook handles both first-launch (deferred) and re-engagement links:
LinkTrail.shared?.onLink { link, source in
    router.route(to: link.path, customData: link.customData)
}

// Forward Universal Links / custom schemes:
//   .onOpenURL { LinkTrail.shared?.handleDeepLink($0) }
//   .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { … handleDeepLink(url) }
```

The install is tracked automatically by `configure`. Observe failures with
`LinkTrail.shared?.onError { … }`.

## Versioning

Releases are tagged with semantic versions. Each release ships a rebuilt XCFramework.
