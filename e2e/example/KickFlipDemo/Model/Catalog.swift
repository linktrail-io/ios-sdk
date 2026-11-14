import SwiftUI

/// A shop category shown in the top bar on the home screen.
struct Category: Identifiable, Hashable {
    let id: String
    let name: String
}

/// A single product in the catalog.
struct Product: Identifiable, Hashable {
    let id: String
    let name: String
    let categoryId: String
    let price: Double
    let emoji: String
    let tint: Color
    let blurb: String

    var priceText: String { Product.money(price) }

    static func money(_ value: Double) -> String {
        "$" + String(format: "%.0f", value)
    }

    static func == (lhs: Product, rhs: Product) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A voucher carried in a deep link's `customData` (`voucher` + `discountPercent`).
struct Voucher: Hashable {
    let code: String
    let percentOff: Int

    func discountedPrice(from price: Double) -> Double {
        (price * (1 - Double(percentOff) / 100)).rounded()
    }
    func savings(from price: Double) -> Double {
        price - discountedPrice(from: price)
    }
}

/// The demo's static storefront data.
enum Catalog {
    static let categories: [Category] = [
        Category(id: "basketball", name: "Basketball"),
        Category(id: "running",    name: "Running"),
        Category(id: "lifestyle",  name: "Lifestyle"),
        Category(id: "skate",      name: "Skate"),
    ]

    static let products: [Product] = [
        Product(id: "aj1",      name: "Air Jordan 1", categoryId: "basketball", price: 180, emoji: "👟", tint: .red,    blurb: "The icon that started it all — premium leather, timeless colorway."),
        Product(id: "dunk",     name: "Dunk Low",     categoryId: "basketball", price: 110, emoji: "🏀", tint: .orange, blurb: "Court-born, street-approved. An everyday staple."),
        Product(id: "uboost",   name: "UltraBoost",   categoryId: "running",    price: 190, emoji: "🏃", tint: .blue,   blurb: "Responsive cushioning built for the long miles."),
        Product(id: "pegasus",  name: "Pegasus 40",   categoryId: "running",    price: 140, emoji: "⚡️", tint: .teal,   blurb: "The workhorse daily trainer, refined again."),
        Product(id: "am90",     name: "Air Max 90",   categoryId: "lifestyle",  price: 130, emoji: "✨", tint: .purple, blurb: "Visible Air and heritage lines you know by heart."),
        Product(id: "boost350", name: "Boost 350",    categoryId: "lifestyle",  price: 220, emoji: "🌙", tint: .indigo, blurb: "Knit upper, sock-like fit, all-day comfort."),
        Product(id: "oldskool", name: "Old Skool",    categoryId: "skate",      price: 70,  emoji: "🛹", tint: .pink,   blurb: "The classic side-stripe skate shoe."),
        Product(id: "sbzoom",   name: "SB Zoom",      categoryId: "skate",      price: 100, emoji: "🔥", tint: .green,  blurb: "Board feel with Zoom Air pop."),
    ]

    static func product(id: String) -> Product? { products.first { $0.id == id } }
    static func category(id: String) -> Category? { categories.first { $0.id == id } }
    static func categoryName(_ id: String) -> String { category(id: id)?.name ?? id.capitalized }
}
