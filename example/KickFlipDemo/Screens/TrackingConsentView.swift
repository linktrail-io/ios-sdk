import SwiftUI
import LinkTrailSDK

/// First-launch tracking consent for the **`.none`** click-token mode.
///
/// In `.none` the SDK never touches the clipboard, so there's no token to collect and nothing to
/// paste — the only thing worth asking is whether the user agrees to be tracked at all.
///
/// The SDK is deny-by-default (`LinkTrailOptions.requireConsent`): until consent is explicitly
/// granted, the gate is closed and every install goes out as `consent: false`. So this screen is
/// what turns "unset" into a real answer:
///
///   • **Allow**  → `setConsent(true)`  → the install is counted and attributed.
///   • **Not now** → `setConsent(false)` → the install is still sent, but not counted.
///
/// Either way the answer is recorded *before* the install fires (`autoTrackInstall` is off in this
/// mode), so exactly one install goes out and it carries the user's real choice.
struct TrackingConsentView: View {
    /// Passes the user's choice up so the host can record it and dismiss the screen.
    let onDecision: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)

                Text("Allow tracking?")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text("We use this to credit the campaign you came from and to tailor your first visit. You can browse the whole store either way.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 14) {
                Button {
                    onDecision(true)
                } label: {
                    Text("Allow")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("tracking-allow")

                Button("Not now") {
                    onDecision(false)
                }
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("tracking-deny")

                Text("No campaign token is read from your clipboard in this mode.")
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
