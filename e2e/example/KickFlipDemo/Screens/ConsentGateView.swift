import SwiftUI
import LinkTrailSDK

/// First-launch consent gate for the **`.pasteButton`** deferred flow.
///
/// In this mode the SDK never touches the clipboard on its own, so iOS shows **no "Allow Paste"
/// alert**. Instead the app presents this screen with Apple's system paste control
/// (``LinkTrailPasteButton``): the user's tap *is* the consent, and the token is handed straight to
/// the SDK (`trackInstall(clickToken:)`), which then routes the deferred link.
///
/// "Not now" is treated as the tracking decision itself: it calls `setConsent(false)`, so the one
/// uncounted `consent: false` install goes out (no token, so nothing routes) and the user lands on
/// the storefront — consistent with what a deny means in every other mode. The paste tap grants
/// consent (``LinkTrailPasteButton``'s `grantsConsent`, on by default); an app that collects
/// tracking consent separately would pass `grantsConsent: false` and keep this screen purely about
/// the clipboard.
///
/// The `.automatic` builds never show this screen; there the SDK reads the clipboard at launch and
/// iOS raises the system alert instead.
struct ConsentGateView: View {
    /// Called once the user has decided, so the host can dismiss the gate.
    let onFinish: () -> Void
    /// "Don't track me" was tapped: tracking is denied, but the paste still routes the link
    /// (deny still routes), so the paste no longer grants.
    @State private var trackingDeclined = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)

                Text("Welcome to KickFlip")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text("Came from a link or an ad? Tap **Paste** so we can take you straight to what you were looking at.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 14) {
                // The system paste control: tapping it IS the consent, so there's no "Allow Paste" alert.
                // The SDK reads the token, replays it as the install's clickId and clears the pasteboard.
                if #available(iOS 16.0, *) {
                    // Dismiss the gate as soon as the token is handed over, so the deferred link the
                    // SDK resolves can actually land on screen. Without this the gate stays up and
                    // covers the routed product page.
                    // After "Don't track me" the paste must not grant consent (`grantsConsent:
                    // false`); `.id` rebuilds the control so the new setting takes effect.
                    LinkTrailPasteButton(grantsConsent: trackingDeclined ? false : nil) { _ in onFinish() }
                        .frame(height: 44)
                        .accessibilityIdentifier("consent-paste")
                        .id(trackingDeclined)
                }

                if trackingDeclined {
                    Text("Tracking is off. Paste to still open your link; nothing is counted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("consent-tracking-off")
                } else {
                    // Deny tracking but keep the paste: the SDK sends one uncounted install with the
                    // token, so the user still lands on the linked screen.
                    Button("Don't track me") {
                        LinkTrail.shared?.setConsent(false)
                        trackingDeclined = true
                    }
                    .font(.footnote.weight(.medium))
                    .accessibilityIdentifier("consent-no-tracking")
                }

                Button("Not now") {
                    // Declining the paste IS the answer in this mode — record it, then send the
                    // single consent:false install (setConsent alone sends nothing here: with
                    // auto-tracking off and nothing held, there is no install for it to release).
                    // Without recording a decision these users would stay held forever and never
                    // send anything, unlike every other mode's deny.
                    LinkTrail.shared?.setConsent(false)
                    LinkTrail.shared?.trackInstall()
                    onFinish()
                }
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("consent-skip")

                Text("We only read a LinkTrail campaign token — nothing else on your clipboard.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
