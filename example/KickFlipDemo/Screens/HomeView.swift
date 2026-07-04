import SwiftUI

/// The storefront: a category bar on top and a grid of products.
struct HomeView: View {
    @EnvironmentObject private var store: Store

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        ScrollView {
            CategoryBar()
                .padding(.top, 8)

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(store.visibleProducts) { product in
                    NavigationLink(value: product) {
                        ProductCard(product: product)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .navigationTitle("KickFlip")
        .background(Color(.systemGroupedBackground))
    }
}

/// Horizontal category chips (including "All").
private struct CategoryBar: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Chip(title: "All", isSelected: store.selectedCategory == nil) {
                    store.selectCategory(nil)
                }
                ForEach(Catalog.categories) { category in
                    Chip(title: category.name, isSelected: store.selectedCategory == category) {
                        store.selectCategory(category)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }

    private struct Chip: View {
        let title: String
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(isSelected ? Color.primary : Color(.secondarySystemBackground))
                    .foregroundStyle(isSelected ? Color(.systemBackground) : .primary)
                    .clipShape(Capsule())
            }
        }
    }
}

/// A product tile in the grid.
private struct ProductCard: View {
    let product: Product

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                product.tint.opacity(0.18)
                Text(product.emoji).font(.system(size: 56))
            }
            .frame(height: 130)
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text(product.name).font(.headline).lineLimit(1)
                Text(Catalog.categoryName(product.categoryId))
                    .font(.caption).foregroundStyle(.secondary)
                Text(product.priceText).font(.subheadline.weight(.semibold)).padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(.separator).opacity(0.5)))
    }
}
