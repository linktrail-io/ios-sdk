import SwiftUI

@main
struct KickFlipDemoApp: App {
    @StateObject private var store: Store
    private let coordinator: AttributionCoordinator

    init() {
        let store = Store()
        _store = StateObject(wrappedValue: store)
        coordinator = AttributionCoordinator(store: store)
    }

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator)
                .environmentObject(store)
                // Custom scheme (kickflip://…)
                .onOpenURL { coordinator.handleIncomingURL($0) }
                // Universal Links (https://kick.linktrail.io/…) arrive as a browsing activity.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { coordinator.handleIncomingURL(url) }
                }
        }
    }
}

/// Home → product navigation, plus the deep-link simulator and the "arrived via link" banner.
private struct RootView: View {
    let coordinator: AttributionCoordinator
    @EnvironmentObject private var store: Store
    @State private var showSimulator = false
    @State private var pendingScenario: AttributionCoordinator.Scenario?

    var body: some View {
        NavigationStack(path: $store.path) {
            HomeView()
                .navigationDestination(for: Product.self) { product in
                    ProductView(product: product)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSimulator = true
                        } label: {
                            Label("Simulate a link", systemImage: "link")
                        }
                    }
                }
        }
        .sheet(isPresented: $showSimulator, onDismiss: {
            // Route only after the sheet is fully gone, so the NavigationStack push sticks.
            if let scenario = pendingScenario {
                pendingScenario = nil
                coordinator.simulate(scenario)
            }
        }) {
            DeepLinkSimulatorView(scenarios: coordinator.scenarios) { scenario in
                pendingScenario = scenario
            }
        }
        .overlay(alignment: .top) {
            if let banner = store.banner {
                LandingBannerView(banner: banner)
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: banner.id) {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        withAnimation { store.banner = nil }
                    }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.banner)
    }
}

/// The transient banner shown when a deep link (deferred or re-engagement) lands.
private struct LandingBannerView: View {
    let banner: Store.LandingBanner

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: banner.source == .deferred ? "sparkles" : "arrow.uturn.backward.circle.fill")
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.subheadline.weight(.semibold))
                Text(banner.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(.separator).opacity(0.4)))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
    }
}
