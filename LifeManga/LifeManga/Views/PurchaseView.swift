//
//  PurchaseView.swift
//  LifeManga
//
//  Credits 内购页面
//

import SwiftUI
import StoreKit

struct PurchaseView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var store = StoreManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                header

                if store.isLoading && store.products.isEmpty {
                    Spacer()
                    ProgressView("加载商品…")
                    Spacer()
                } else if store.products.isEmpty {
                    Spacer()
                    ContentUnavailableView(
                        "暂无商品",
                        systemImage: "cart",
                        description: Text("无法连接到 App Store，请稍后重试。")
                    )
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(store.products, id: \.id) { product in
                                ProductCard(product: product, store: store)
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                if let error = store.purchaseError {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Button {
                    Task { await store.restorePurchases() }
                } label: {
                    Text("恢复购买")
                        .font(.subheadline)
                }
                .padding(.bottom)
            }
            .navigationTitle("购买 Credits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                await store.loadProducts()
            }
            .onChange(of: store.pendingProductId) { _, new in
                // 购买流程结束后刷新 credits
                if new == nil {
                    Task { await settings.refreshCredits() }
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Text("当前余额")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("\(settings.credits)")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(.indigo)
            Text("credits")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
    }
}

private struct ProductCard: View {
    let product: Product
    @ObservedObject var store: StoreManager
    @State private var isPurchasing = false

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(productName)
                    .font(.headline)
                Text(productDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                Task {
                    isPurchasing = true
                    _ = await store.purchase(product)
                    isPurchasing = false
                }
            } label: {
                if isPurchasing || store.pendingProductId == product.id {
                    ProgressView()
                        .frame(width: 80, height: 36)
                } else {
                    Text(product.displayPrice)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 80, height: 36)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPurchasing || store.pendingProductId != nil)
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var productName: String {
        switch product.id {
        case "credits_10":  return "10 Credits"
        case "credits_60":  return "60 Credits"
        case "credits_150": return "150 Credits"
        default:            return product.displayName
        }
    }

    private var productDescription: String {
        switch product.id {
        case "credits_10":  return "少量体验，适合先试试效果"
        case "credits_60":  return "最受欢迎的入门包"
        case "credits_150": return "最划算，适合长期创作"
        default:            return product.description
        }
    }
}

#Preview {
    PurchaseView()
        .environmentObject(AppSettings())
}
