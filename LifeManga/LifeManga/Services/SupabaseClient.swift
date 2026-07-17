//
//  SupabaseClient.swift
//  LifeManga
//
//  Supabase 客户端单例。
//

import Foundation
import Supabase

@MainActor
final class SupabaseClientManager {
    static let shared = SupabaseClientManager()

    let client: SupabaseClient

    private init() {
        self.client = SupabaseClient(
            supabaseURL: SupabaseConfig.supabaseURL,
            supabaseKey: SupabaseConfig.supabaseKey
        )
    }

    /// 当前登录用户（只读）
    var currentUser: User? {
        client.auth.currentUser
    }

    /// 监听登录状态变化
    var authStateChanges: AsyncStream<(event: AuthChangeEvent, session: Session?)> {
        client.auth.authStateChanges
    }
}
