//
//  StoreManager.swift
//  LifeManga
//
//  StoreKit 2 内购管理
//

import Foundation
import StoreKit
import Supabase

@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()

    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoading = false
    @Published private(set) var purchaseError: String?
    @Published private(set) var pendingProductId: String?

    private let productIds = ["credits_10", "credits_60", "credits_150"]

    private init() {}

    // MARK: - 加载商品

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: Set(productIds))
            products.sort { (a, b) in
                // 按价格升序
                a.price < b.price
            }
        } catch {
            purchaseError = "加载商品失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 购买

    func purchase(_ product: Product) async -> Bool {
        pendingProductId = product.id
        defer { pendingProductId = nil }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()

                // 把 receipt 发给服务端验证并充值
                let receipt = try await fetchReceipt()
                let verified = try await verifyPurchase(
                    receipt: receipt,
                    productId: product.id
                )
                return verified

            case .userCancelled:
                return false
            case .pending:
                purchaseError = "购买正在等待家长批准…"
                return false
            @unknown default:
                purchaseError = "未知购买结果"
                return false
            }
        } catch {
            purchaseError = "购买失败：\(error.localizedDescription)"
            return false
        }
    }

    // MARK: - 恢复购买

    func restorePurchases() async {
        do {
            try await AppStore.sync()
        } catch {
            purchaseError = "恢复购买失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 私有方法

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.unverified
        case .verified(let safe):
            return safe
        }
    }

    private func fetchReceipt() async throws -> String {
        // 获取 App Store receipt（Base64）
        guard let appStoreReceiptURL = Bundle.main.appStoreReceiptURL,
              FileManager.default.fileExists(atPath: appStoreReceiptURL.path),
              let data = try? Data(contentsOf: appStoreReceiptURL) else {
            throw StoreError.noReceipt
        }
        return data.base64EncodedString()
    }

    private func verifyPurchase(receipt: String, productId: String) async throws -> Bool {
        let session = try await SupabaseClientManager.shared.client.auth.session
        let body: [String: Any] = [
            "receipt_data": receipt,
            "product_id": productId,
            "is_sandbox": useSandbox(),
        ]

        let data: Data = try await SupabaseClientManager.shared.client.functions
            .invoke(
                "verify-purchase",
                options: FunctionInvokeOptions(
                    body: try JSONSerialization.data(withJSONObject: body)
                ),
                decode: { data, _ in data }
            )

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["success"] as? Bool == true
    }

    private func useSandbox() -> Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    enum StoreError: Error {
        case unverified
        case noReceipt
        case invalidResponse
    }
}
