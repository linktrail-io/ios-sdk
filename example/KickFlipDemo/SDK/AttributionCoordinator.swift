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

    /// Which deferred click-token path this build exercises. Selected at build time from the
    /// `LINKTRAIL_TOKEN_SOURCE` env var (baked in by scripts/build-example.sh), so the same example
    /// covers every mode:
    ///   • `automatic`   — the SDK reads the clipboard itself → iOS shows the **"Allow Paste"** alert.
    ///   • `pasteButton` — no alert; the user taps a native `LinkTrailPasteButton` on the consent gate.
    ///   • `none`        — the clipboard is never touched: no alert, no gate, attribution is purely
    ///                     probabilistic (the backend's IP match).
    /// Defaults to `.automatic`.
    static let tokenSource: LinkTrailClickTokenSource = {
        switch Bundle.main.object(forInfoDictionaryKey: "LinkTrailTokenSource") as? String {
        case "pasteButton": return .pasteButton
        case "none":        return LinkTrailClickTokenSource.none
        default:            return .automatic
        }
    }()

    /// `true` when this build shows the paste-button consent gate instead of auto-reading.
    static var usesPasteButton: Bool { tokenSource == .pasteButton }

    /// `true` when this build asks for tracking consent up front. In `.none` there's no clipboard
    /// token to collect, so the only thing worth asking about is tracking itself — and the SDK is
    /// deny-by-default (`requireConsent`), so without an explicit answer every install would go out
    /// as `consent: false`.
    static var usesTrackingConsentScreen: Bool { tokenSource == LinkTrailClickTokenSource.none }

    /// Records the user's tracking choice, then sends the install with that value.
    ///
    /// `autoTrackInstall` is off in this mode, so nothing has been sent yet — this is what keeps the
    /// install to a single request carrying the real answer, instead of firing `consent: false` at
    /// launch and correcting it afterwards.
    func answerTrackingConsent(granted: Bool) {
        LinkTrail.shared?.setConsent(granted)
        LinkTrail.shared?.trackInstall()
    }

    init(store: Store) {
        self.store = store
        configureSDK()
    }

    private func configureSDK() {
        // linkDomains → only treat kick.linktrail.io Universal Links as ours.
        // clickTokenSource → see `tokenSource` above.
        // autoTrackInstall: only in .automatic does the install fire at launch (reading the clipboard,
        //   which shows "Allow Paste"). .pasteButton defers it until the user's paste tap, and .none
        //   defers it until they answer the tracking-consent screen — so the install carries their
        //   real answer instead of the deny-by-default `consent: false`.
        // logEnabled → the demo prints what the SDK is doing (install, consent value, routing), which
        // is what you want when eyeballing a deferred flow. Real apps leave it off.
        let options = LinkTrailOptions(logEnabled: true,
                                       logLevel: .debug,
                                       linkDomains: ["kick.linktrail.io"],
                                       autoTrackInstall: Self.tokenSource == .automatic,
                                       clickTokenSource: Self.tokenSource)
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

    /// Your workspace SDK key (`lt_live_…`) from the LinkTrail dashboard, baked in at build time from
    /// the `LINKTRAIL_KEY` environment variable (see `LINKTRAIL_API_KEY` in example/project.yml):
    ///
    ///     LINKTRAIL_KEY=lt_live_… bash scripts/build-example.sh
    ///
    /// Keeping it out of source means the real key is never written into a tracked file. Without the
    /// env var the build falls back to the placeholder, which the backend rejects (surfaced via
    /// `onError`).
    private static let apiKey: String =
        (Bundle.main.object(forInfoDictionaryKey: "LinkTrailApiKey") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "lt_live_REPLACE_WITH_YOUR_KEY"
}
