# KickFlip — LinkTrail iOS demo

A small SwiftUI storefront that shows how the **LinkTrail** SDK's deferred deep linking drives
where a user lands after installing. It consumes the SDK's **binary package** at the repo root
(`../`) — the same way an external app would.

## Run it

Requires Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

### 1. Add your API key

Pass your workspace SDK key (`lt_live_…`, from the LinkTrail dashboard) as an environment variable
when you generate the project. It's baked into `Info.plist` at build time, so the key never has to
be written into a source file:

```bash
cd example
LINKTRAIL_KEY=lt_live_… xcodegen generate
```

Without a valid key the backend returns `401`, surfaced via `onError` (you'll see a console
warning). The deep-link **simulator still works without a key** — it fabricates links locally —
so you can explore the UI first and add the key only when you want the real install/open calls
to authenticate.

### 2. Pick how the deferred click token is read

The demo covers all three `clickTokenSource` modes — choose one at generate time:

```bash
LINKTRAIL_TOKEN_SOURCE=automatic   xcodegen generate   # default
LINKTRAIL_TOKEN_SOURCE=pasteButton xcodegen generate
LINKTRAIL_TOKEN_SOURCE=none        xcodegen generate
```

| Mode | First launch shows |
|---|---|
| `automatic` | The storefront plus the iOS **"Allow Paste"** system alert — the SDK reads the clipboard itself. |
| `pasteButton` | A consent gate with a native **Paste** control. The tap *is* the consent, so there's no alert. |
| `none` | An **"Allow tracking?"** screen. The clipboard is never touched; attribution is left to the probabilistic (IP) match. |

### 3. Build and run

```bash
open KickFlipDemo.xcodeproj  # run on any iOS 16+ simulator
```

## The app

Two screens, nothing more:

- **Home** — a category bar on top (All · Basketball · Running · Lifestyle · Skate) and a grid of products.
- **Product** — one product. If a voucher was delivered in the deep link, it shows the voucher badge, the discounted price, and how much you saved.

## The four deferred deep-link scenarios

Tap the **🔗 link button** (top-right) to open the simulator and fire any of these. Each is a real
`LinkTrailDeepLink` — the same object your `onLink` handler receives from a real install.

| Scenario | Deep link | Where you land |
|---|---|---|
| 1 · Just the store | `deepLinkPath: "/"` | Home |
| 2 · Category selected | `deepLinkPath: "/category/running"` | Home with **Running** pre-selected |
| 3 · A product | `deepLinkPath: "/products/aj1"` | The Air Jordan 1 product page |
| 4 · Product + voucher | `deepLinkPath: "/products/aj1"`, `customData: ["voucher": "SUMMER25", "discountPercent": "25"]` | Product page with **SUMMER25 −25%** applied |

The simulator fabricates the deferred link locally so you don't need a real click → install
round-trip. In production these arrive from the SDK — no code changes in the app.

## How it maps to the SDK

The entire integration is one method — [`Store.route(_:source:)`](KickFlipDemo/App/Store.swift) —
which reads `link.path` and `link.customData` and decides the screen. It's wired up once:

```swift
LinkTrail.shared?.onLink { [store] link, source in
    store.route(link, source: source)   // deferred (first launch) AND re-engagement
}
```

| SDK touchpoint | Where |
|---|---|
| `LinkTrail.configure(apiKey:options:)` + `onError` | [`AttributionCoordinator`](KickFlipDemo/SDK/AttributionCoordinator.swift) |
| `onLink { link, source in … }` — the one routing hook | [`AttributionCoordinator`](KickFlipDemo/SDK/AttributionCoordinator.swift) → [`Store`](KickFlipDemo/App/Store.swift) |
| `registerForSKAdAttribution()` on launch | [`AttributionCoordinator`](KickFlipDemo/SDK/AttributionCoordinator.swift) |
| `handleDeepLink(_:)` for the already-installed path | [`AttributionCoordinator`](KickFlipDemo/SDK/AttributionCoordinator.swift), forwarded from `onOpenURL` |

## Test from the terminal

While the app is installed, the custom scheme routes the same way:

```bash
xcrun simctl openurl booted "kickflip://products/aj1?voucher=SUMMER25&discountPercent=25"
```
