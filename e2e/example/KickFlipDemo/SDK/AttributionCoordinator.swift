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
    /// `LINKTRAIL_TOKEN_SOURCE` env var (baked in by e2e/scripts/e2e-maestro.sh), so the same example
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
    /// deny-by-default (`requireConsent`), so without an explicit answer the install is held and
    /// nothing is ever sent.
    ///
    /// The SDK is deny-by-default: with `requireConsent` on it does nothing at all — no install, no
    /// clipboard read — until the host app records a decision. `.pasteButton` has its own affordance
    /// (the paste tap is the consent), so every OTHER mode needs this screen or the app would sit
    /// there having sent nothing, which is the intended behaviour but looks like a broken demo.
    static var usesTrackingConsentScreen: Bool { tokenSource != .pasteButton }

    /// Records the user's tracking choice, which releases the install the SDK has been holding.
    ///
    /// `autoTrackInstall` is off in this mode, so nothing has been sent yet — and with the SDK's
    /// hold-until-decision gate nothing would have been sent anyway. On **Allow** the install goes
    /// out once, carrying the real answer; on **Not now** it is dropped.
    func answerTrackingConsent(granted: Bool) {
        // setConsent releases whatever the SDK was holding — the install it auto-fired at launch, or
        // one this app sent itself. Only call trackInstall when neither applies, i.e. auto-tracking
        // is off and nothing was held; otherwise the SDK already has an install to send and a second
        // call is redundant.
        LinkTrail.shared?.setConsent(granted)
        if !Self.usesAutoTrackInstall { LinkTrail.shared?.trackInstall() }
    }

    /// Mirrors the `autoTrackInstall` passed to `configure` below.
    static var usesAutoTrackInstall: Bool { tokenSource == .automatic }

    init(store: Store) {
        self.store = store
        configureSDK()
    }

    private func configureSDK() {
        // linkDomains → only treat our own link host's Universal Links as ours. The host is baked in
        //   at build time (LINKTRAIL_LINK_HOST → Info.plist), so the demo follows whichever
        //   environment the E2E run targets instead of hardcoding production.
        // clickTokenSource → see `tokenSource` above.
        // autoTrackInstall: only in .automatic does the install fire at launch (reading the clipboard,
        //   which shows "Allow Paste"). .pasteButton defers it until the user's paste tap, and .none
        //   defers it until they answer the tracking-consent screen — so the install carries their
        //   real answer instead of the deny-by-default `consent: false`.
        // logEnabled → the demo prints what the SDK is doing (install, consent value, routing), which
        // is what you want when eyeballing a deferred flow. Real apps leave it off. Build with
        // LINKTRAIL_LOGS=NO to check that a build with logging off prints no [LinkTrail] lines.
        let options = LinkTrailOptions(logEnabled: Self.logsEnabled,
                                       logLevel: .debug,
                                       linkDomains: [Self.linkHost] + (Self.customLinkHost.map { [$0] } ?? []),
                                       autoTrackInstall: Self.usesAutoTrackInstall,
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
        #if DEBUG
        // E2E only: the re-engagement flows' Universal Link forwarder and the reward flows' event hook.
        if let forwarded = E2ELinks.universalLink(url) { return handleIncomingURL(forwarded) }
        if let events = E2ELinks.trackRequest(url) { return E2EDebug.send(events, store: store) }
        #endif
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

    /// Whether the SDK prints its `[LinkTrail]` log lines in this build, baked in at build time from
    /// `LINKTRAIL_LOGS` (see e2e/example/Config/KickFlip.xcconfig). On unless the build says `NO`, so a
    /// missing or unexpanded value keeps the logs the demo relies on.
    static let logsEnabled: Bool = {
        let value = (Bundle.main.object(forInfoDictionaryKey: "LinkTrailLogs") as? String)?
            .trimmingCharacters(in: .whitespaces).uppercased()
        return !["NO", "FALSE", "0"].contains(value ?? "")
    }()

    /// The LinkTrail-hosted host this build's links live on, baked in at build time from
    /// `LINKTRAIL_LINK_HOST` (see example/project.yml). It drives both `linkDomains` and the
    /// Associated Domains entitlement, so a test-environment build scopes re-engagement to the test
    /// host rather than production.
    static let linkHost: String =
        (Bundle.main.object(forInfoDictionaryKey: "LinkTrailLinkHost") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "kick.linktrail.io"

    /// An optional second link host (the workspace's custom link domain) from
    /// `LINKTRAIL_CUSTOM_LINK_HOST`, also passed to `linkDomains`; `nil` when the build sets none.
    static let customLinkHost: String? =
        (Bundle.main.object(forInfoDictionaryKey: "LinkTrailCustomLinkHost") as? String)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }

    /// Your workspace SDK key (`lt_live_…`) from the LinkTrail dashboard, baked into Info.plist at
    /// build time from `LINKTRAIL_API_KEY` (see e2e/example/Config/KickFlip.xcconfig): set
    /// `$LINKTRAIL_KEY` or put it in the gitignored e2e/example/Config/Secrets.xcconfig.
    ///
    ///     LINKTRAIL_KEY=lt_live_… bash e2e/scripts/e2e-maestro.sh
    ///
    /// Keeping it out of source means the real key is never written into a tracked file. XcodeGen and
    /// the "Check LinkTrail SDK key" build phase refuse to build without one, so a missing key here
    /// means the Info.plist was edited by hand; stop loudly rather than run an app that only gets 401s.
    private static let apiKey: String = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "LinkTrailApiKey") as? String,
              !key.isEmpty, !key.contains("REPLACE"), !key.hasPrefix("$(") else {
            fatalError("LinkTrailApiKey is missing from Info.plist. Set LINKTRAIL_KEY or e2e/example/Config/Secrets.xcconfig and rebuild; see e2e/README.md.")
        }
        return key
    }()
}
