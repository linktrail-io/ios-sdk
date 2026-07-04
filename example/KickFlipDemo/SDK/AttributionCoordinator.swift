import Foundation
import LinkTrailSDK

/// Bridges the demo UI to the LinkTrail SDK: configures it, forwards real deferred +
/// re-engagement links into `Store.route`, and can *simulate* the four deferred scenarios
/// locally so you can see each one without a real click → install round-trip.
final class AttributionCoordinator {

    /// One of the demo's deferred-deep-link scenarios.
    struct Scenario: Identifiable {
        let id: String
        let title: String
        let detail: String
        let link: LinkTrailDeepLink
    }

    /// The four scenarios from the brief, each expressed as a real `LinkTrailDeepLink`.
    let scenarios: [Scenario] = [
        Scenario(id: "home",
                 title: "Home",
                 detail: "User just lands on the storefront",
                 link: LinkTrailDeepLink(deepLinkPath: "/", campaign: "brand-awareness")),
        Scenario(id: "category",
                 title: "Home · Running selected",
                 detail: "Lands on home with a category pre-selected",
                 link: LinkTrailDeepLink(deepLinkPath: "/category/running", campaign: "running-sale")),
        Scenario(id: "product",
                 title: "Product · Air Jordan 1",
                 detail: "Lands directly on a product page",
                 link: LinkTrailDeepLink(deepLinkPath: "/products/aj1", campaign: "aj1-launch")),
        Scenario(id: "voucher",
                 title: "Product · Air Jordan 1 + voucher",
                 detail: "Product page with a voucher from the link meta",
                 link: LinkTrailDeepLink(deepLinkPath: "/products/aj1",
                                         campaign: "vip-loyalty",
                                         customData: ["voucher": "SUMMER25", "discountPercent": "25"])),
    ]

    private let store: Store

    init(store: Store) {
        self.store = store
        configureSDK()
    }

    private func configureSDK() {
        // autoTrackInstall: true → the install fires at launch, which also validates the key.
        // linkDomains → only treat kick.linktrail.io Universal Links as ours.
        let options = LinkTrailOptions(linkDomains: ["kick.linktrail.io"], autoTrackInstall: true)
        do {
            try LinkTrail.configure(apiKey: Self.apiKey, options: options)
        } catch {
            assertionFailure("LinkTrail configuration failed: \(error)")
            return
        }
        LinkTrail.shared?.registerForSKAdAttribution()

        // Surface backend failures — most importantly a rejected API key.
        LinkTrail.shared?.onError { error in
            if case LinkTrailError.invalidAPIKey = error {
                print("⚠️ LinkTrail: API key rejected by the server — check your lt_live_… key.")
            } else {
                print("⚠️ LinkTrail error:", error.localizedDescription)
            }
        }

        // The ONE piece of real wiring: route deferred (first launch) + re-engagement links.
        LinkTrail.shared?.onLink { [store] link, source in
            store.route(link, source: source)
        }
    }

    /// Simulate a fresh install arriving via a deferred deep link (no backend needed).
    func simulate(_ scenario: Scenario) {
        store.route(scenario.link, source: .deferred)
    }

    /// Forward an incoming URL (Universal Link or `kickflip://` scheme) to the SDK, and also
    /// route our own scheme locally so manual testing works while the app is installed, e.g.
    /// `xcrun simctl openurl booted "kickflip://products/aj1?voucher=SUMMER25&discountPercent=25"`.
    func handleIncomingURL(_ url: URL) {
        if LinkTrail.shared?.handleDeepLink(url) == true { return }
        guard url.scheme == "kickflip" else { return }

        let segments = ([url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" })
        let destination = "/" + segments.joined(separator: "/")

        var meta: [String: String] = [:]
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.forEach {
            if let value = $0.value { meta[$0.name] = value }
        }
        store.route(LinkTrailDeepLink(deepLinkPath: destination,
                                      customData: meta.isEmpty ? nil : meta),
                    source: .reengagement)
    }

    /// Your workspace SDK key (`lt_live_…`) from the LinkTrail dashboard. Replace this
    /// placeholder with your own — until you do, the backend rejects it (surfaced via `onError`).
    private static let apiKey = "lt_live_REPLACE_WITH_YOUR_KEY"
}
