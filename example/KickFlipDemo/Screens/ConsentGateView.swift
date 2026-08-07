import SwiftUI
import LinkTrailSDK

/// First-launch consent gate for the **`.pasteButton`** deferred flow.
///
/// In this mode the SDK never touches the clipboard on its own, so iOS shows **no "Allow Paste"
/// alert**. Instead the app presents this screen with Apple's system paste control
/// (``LinkTrailPasteButton``): the user's tap *is* the consent, and the token is handed straight to
/// the SDK (`trackInstall(clickToken:)`), which then routes the deferred link.
///
/// "Not now" skips the paste: no token, so no deterministic match — the install still goes out
/// (falling back to the IP path) and the user lands on the storefront.
///
/// The `.automatic` builds never show this screen; there the SDK reads the clipboard at launch and
/// iOS raises the system alert instead.
struct ConsentGateView: View {
    /// Called once the user has decided, so the host can dismiss the gate.
    let onFinish: () -> Void

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
                    LinkTrailPasteButton { _ in onFinish() }
                        .frame(height: 44)
                        .accessibilityIdentifier("consent-paste")
                }

                Button("Not now") {
                    // No token — the install still goes out and falls back to the IP path.
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
