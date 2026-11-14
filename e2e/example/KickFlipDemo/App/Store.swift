import SwiftUI
import LinkTrailSDK

/// Holds the demo's navigation + storefront state and translates a `LinkTrailDeepLink`
/// (real or simulated) into where the user lands. This `route(_:source:)` method is exactly
/// the code a real app would put inside its `onLink` handler.
final class Store: ObservableObject {

    /// Navigation stack for the home → product push. Empty == showing home.
    @Published var path: [Product] = []
    /// Selected category chip on the home screen. `nil` == "All".
    @Published var selectedCategory: Category?
    /// Vouchers applied per product id (delivered via a deep link's meta).
    @Published var appliedVouchers: [String: Voucher] = [:]
    /// A transient "you arrived via a link" banner.
    @Published var banner: LandingBanner?
    /// The routed link's `linkType` / `source` custom data, shown in a debug-only row on the
    /// product page so the e2e flows can assert which link type delivered the user.
    @Published var linkMeta: LinkMeta?
    #if DEBUG
    /// E2E only: what the SDK answered for the events a `kickflip://e2e-track` URL asked for.
    struct E2EEvents: Equatable { let requested: Int; let sent: Int; let attributed: Int }
    @Published var e2eEvents: E2EEvents?
    /// E2E only: the source of the last routed link, shown on a footer label that stays put (the
    /// landing banner hides itself after 3.5s, often before a Maestro step can see it).
    @Published var e2eLinkSource: String?
    #endif

    struct LinkMeta: Equatable {
        let linkType: String?
        let source: String?
    }

    struct LandingBanner: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let subtitle: String
        let source: LinkTrailLinkSource
    }

    var visibleProducts: [Product] {
        guard let category = selectedCategory else { return Catalog.products }
        return Catalog.products.filter { $0.categoryId == category.id }
    }

    func voucher(for product: Product) -> Voucher? { appliedVouchers[product.id] }

    func selectCategory(_ category: Category?) {
        withAnimation { selectedCategory = category }
    }

    // MARK: - Deep-link routing

    /// Route a deep link into navigation state. The `path` decides the screen; `customData`
    /// carries extras like a voucher. This is the whole integration surface.
    func route(_ link: LinkTrailDeepLink, source: LinkTrailLinkSource) {
        let destination = link.path
        #if DEBUG
        e2eLinkSource = source == .deferred ? "deferred" : "reengagement"
        #endif

        // Scenario 3 & 4 — a specific product (optionally with a voucher in the meta).
        if destination.hasPrefix("/products/") {
            let productId = String(destination.dropFirst("/products/".count))
            guard let product = Catalog.product(id: productId) else { return landOnHome(source) }
            selectedCategory = Catalog.category(id: product.categoryId)

            if let code = link.customData?["voucher"] {
                let percent = Int(link.customData?["discountPercent"] ?? "") ?? 0
                appliedVouchers[product.id] = Voucher(code: code, percentOff: percent)
            }
            let type = link.customData?["linkType"], origin = link.customData?["source"]
            linkMeta = (type == nil && origin == nil) ? nil : LinkMeta(linkType: type, source: origin)
            path = [product]
            banner = LandingBanner(
                title: title(source),
                subtitle: link.customData?["voucher"] != nil
                    ? "Voucher \(link.customData?["voucher"] ?? "") applied to \(product.name)"
                    : "Straight to \(product.name)",
                source: source)
            return
        }

        // Scenario 2 — home with a category pre-selected.
        if destination.hasPrefix("/category/") {
            let categoryId = String(destination.dropFirst("/category/".count))
            selectedCategory = Catalog.category(id: categoryId)
            path = []
            banner = LandingBanner(title: title(source),
                                   subtitle: "\(Catalog.categoryName(categoryId)) picks for you",
                                   source: source)
            return
        }

        // Scenario 1 — just the storefront.
        landOnHome(source)
    }

    private func landOnHome(_ source: LinkTrailLinkSource) {
        selectedCategory = nil
        path = []
        banner = LandingBanner(title: title(source), subtitle: "Browse the latest drops", source: source)
    }

    private func title(_ source: LinkTrailLinkSource) -> String {
        source == .deferred ? "Opened from your link" : "Welcome back"
    }
}
