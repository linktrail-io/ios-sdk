import SwiftUI
import LinkTrailSDK

/// A small dev panel that fires each of the four deferred deep-link scenarios so you can see
/// where the app lands — without a real click + install round-trip.
///
/// It only *records* the pick and dismisses; the parent routes in the sheet's `onDismiss`, so
/// the navigation push happens when the main `NavigationStack` is the active context (mutating
/// it while the sheet is still dismissing silently no-ops and you'd stay on home).
struct DeepLinkSimulatorView: View {
    let scenarios: [AttributionCoordinator.Scenario]
    let onSelect: (AttributionCoordinator.Scenario) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(scenarios) { scenario in
                        Button {
                            onSelect(scenario)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(scenario.title).font(.headline).foregroundStyle(.primary)
                                Text(scenario.detail).font(.subheadline).foregroundStyle(.secondary)
                                Text(pathLabel(scenario.link)).font(.caption.monospaced()).foregroundStyle(.blue)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Deferred deep link scenarios")
                } footer: {
                    Text("Simulates a fresh install landing via the SDK's deferred deep link. The link's path and meta decide where you land — the same thing your real `onLink` handler routes on.")
                }
            }
            .navigationTitle("Simulate a Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func pathLabel(_ link: LinkTrailDeepLink) -> String {
        var label = link.path
        if let voucher = link.customData?["voucher"] {
            label += "  ·  meta: voucher=\(voucher)"
            if let percent = link.customData?["discountPercent"] { label += ", \(percent)%" }
        }
        return label
    }
}
