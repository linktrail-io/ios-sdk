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

## Install (CocoaPods)

```ruby
pod 'LinkTrailSDK', :git => 'https://github.com/linktrail-io/ios-sdk.git', :tag => '0.0.8'
```

Then run `pod install` and open the generated `.xcworkspace`.

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

## Example app

[`example/`](example/) contains **KickFlip**, a small SwiftUI storefront that shows deferred
deep linking end to end — it consumes this package's binary exactly as your app would. Requires
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
cd example && xcodegen generate && open KickFlipDemo.xcodeproj
```

Set your `lt_live_…` key in `KickFlipDemo/SDK/AttributionCoordinator.swift`, then tap the 🔗
button to fire the four deep-link scenarios (home · category · product · product+voucher).

## Versioning

Releases are tagged with semantic versions. Each release ships a rebuilt XCFramework.
