//
//  CreditService.swift
//  LifeManga
//
//  Credits 余额查询与刷新
//

import Foundation
import Supabase

struct CreditsInfo: Codable {
    let total: Int
    let purchased: Int
    let subscription: Int
    let tier: String
    let totalGenerated: Int

    enum CodingKeys: String, CodingKey {
        case total
        case purchased
        case subscription
        case tier
        case totalGenerated = "total_generated"
    }
}

@MainActor
final class CreditService {
    static let shared = CreditService()
    private init() {}

    /// 从服务端获取当前用户 credits 余额
    func fetchCredits() async throws -> CreditsInfo {
        let info: CreditsInfo = try await SupabaseClientManager.shared.client.functions
            .invoke("get-credits")
        return info
    }

    enum CreditError: Error {
        case emptyResponse
    }
}
