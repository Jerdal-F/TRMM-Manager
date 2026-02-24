import SwiftUI
import StoreKit

struct DonationSheet: View {
    private static let productIdentifiers = [
        "Donate1usd",
        "Donate5usd",
        "Donate10usd",
        "Donate20usd",
        "Donate50usd",
        "Donate100usd"
    ]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    @State private var products: [Product] = []
    @State private var isLoading = false
    @State private var statusMessage: String?
    @State private var isPurchasing = false

    var body: some View {
        NavigationStack {
            ZStack {
                DarkGradientBackground()
                VStack(spacing: 20) {
                    Text("Support Development")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.white)
                    Text("Select a donation amount to support ongoing work on TacticalRMM Manager.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.white.opacity(0.7))
                        .padding(.horizontal)

                    if isLoading {
                        ProgressView("Loading donation options…")
                            .tint(appTheme.accent)
                    } else if products.isEmpty {
                        Text("Donation options are currently unavailable. Check back soon.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color.white.opacity(0.7))
                            .padding(.horizontal)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            ForEach(products, id: \.id) { product in
                                Button {
                                    Task { await purchase(product) }
                                } label: {
                                    VStack(spacing: 4) {
                                        Text(product.displayPrice)
                                            .font(.headline)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 18)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(appTheme.accent)
                                .buttonBorderShape(.roundedRectangle(radius: 14))
                                .disabled(isPurchasing)
                            }
                        }
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.white)
                            .multilineTextAlignment(.center)
                            .padding(.top, 8)
                    }
                }
                .padding(24)
            }
            .navigationTitle("Donate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(appTheme.accent)
                }
            }
        }
        .task {
            if products.isEmpty {
                await loadProducts()
            }
        }
    }

    @MainActor
    private func loadProducts() async {
        isLoading = true
        statusMessage = nil
        defer { isLoading = false }
        do {
            var fetched = try await Product.products(for: Self.productIdentifiers)
            fetched.sort { $0.price < $1.price }
            products = fetched
            let identifiers = fetched.map { $0.id.description }.joined(separator: ", ")
            DiagnosticLogger.shared.append("Loaded StoreKit products: \(identifiers)")
        } catch {
            statusMessage = "Unable to load donation options: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func purchase(_ product: Product) async {
        guard !isPurchasing else { return }
        isPurchasing = true
        statusMessage = nil
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    statusMessage = "Thank you for your support!"
                case .unverified(_, let error):
                    statusMessage = "Donation unverified: \(error.localizedDescription)"
                }
            case .userCancelled:
                statusMessage = "Donation cancelled."
            case .pending:
                statusMessage = "Donation pending approval."
            @unknown default:
                statusMessage = "Donation completed with an unknown result."
            }
        } catch {
            statusMessage = "Donation failed: \(error.localizedDescription)"
        }
    }
}
