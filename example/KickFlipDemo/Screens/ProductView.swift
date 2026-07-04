import SwiftUI

/// A single product page. If a voucher was delivered for this product (via a deep link's
/// meta), it shows the voucher badge and the discounted price.
struct ProductView: View {
    let product: Product
    @EnvironmentObject private var store: Store

    private var voucher: Voucher? { store.voucher(for: product) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ZStack {
                    product.tint.opacity(0.18)
                    Text(product.emoji).font(.system(size: 120))
                }
                .frame(height: 260)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text(Catalog.categoryName(product.categoryId))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(product.name).font(.largeTitle.bold())
                    Text(product.blurb).font(.body).foregroundStyle(.secondary)
                }

                priceBlock

                Button {
                    // Add-to-bag is out of scope for the demo.
                } label: {
                    Text("Add to Bag")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(product.tint)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var priceBlock: some View {
        if let voucher {
            let discounted = voucher.discountedPrice(from: product.price)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "tag.fill")
                    Text("Voucher \(voucher.code) applied · \(voucher.percentOff)% off")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Color.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Product.money(discounted)).font(.title.bold())
                    Text(product.priceText).font(.title3).strikethrough().foregroundStyle(.secondary)
                    Spacer()
                    Text("Save \(Product.money(voucher.savings(from: product.price)))")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.green.opacity(0.15)).foregroundStyle(.green)
                        .clipShape(Capsule())
                }
            }
        } else {
            Text(product.priceText).font(.title.bold())
        }
    }
}
