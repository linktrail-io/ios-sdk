#if DEBUG
import SwiftUI
import LinkTrailSDK

/// E2E only (DEBUG builds of this example app): the hook the e2e run drives the app with. Only the
/// SDK's public API is used, so the app builds against the published binary package.
///
/// - `kickflip://e2e-track?event=…` (parsed by `E2ELinks.trackRequest`): sends each event through
///   `LinkTrail.trackEvent`, in order. The reward flows (e2e/scripts/reward_*.yaml) use it after the
///   counted install. The label `debug-events-requested` then shows what the SDK answered:
///   `E2E events: requested N · sent S · attributed A`.
enum E2EDebug {
    /// Sends the events in order through `LinkTrail.trackEvent` and records what the SDK answered:
    /// how many were requested, how many it sent (acknowledged with an id) and how many came back
    /// attributed. With tracking denied the SDK sends none, so the footer shows `sent 0` and the
    /// deny flows fail if an SDK ever leaks one.
    static func send(_ events: [E2ELinks.Event], store: Store) {
        Task {
            var sent = 0, attributed = 0
            for event in events {
                let result = try? await LinkTrail.shared?.trackEvent(name: event.name, value: event.value, currency: event.currency)
                if result?.id != nil { sent += 1 }
                if result?.attributed == true { attributed += 1 }
            }
            let summary = Store.E2EEvents(requested: events.count, sent: sent, attributed: attributed)
            await MainActor.run { store.e2eEvents = summary }
        }
    }
}

/// The DEBUG footer under the storefront and product pages: events requested, and the
/// source of the last routed link (`E2E link: deferred | reengagement`), which the re-engagement
/// flows assert instead of the transient landing banner.
struct E2EDebugFooter: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Spacer()
                Text(store.e2eEvents.map { "E2E events: requested \($0.requested) · sent \($0.sent) · attributed \($0.attributed)" }
                     ?? "E2E events: none")
                    .accessibilityIdentifier("debug-events-requested")
            }
            Text("E2E link: \(store.e2eLinkSource ?? "none")").accessibilityIdentifier("e2e-link-source")
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
#endif
