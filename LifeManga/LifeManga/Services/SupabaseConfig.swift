//
//  SupabaseConfig.swift
//  LifeManga
//
//  Supabase 项目配置。上线前把这里的值换成你自己的 Supabase 项目。
//

import Foundation

enum SupabaseConfig {
    /// Supabase Project URL
    /// 本地开发：http://127.0.0.1:54321
    /// 生产环境：https://<your-project>.supabase.co
    static let supabaseURL = URL(string: "http://127.0.0.1:54321")!

    /// Supabase publishable (anon) key
    /// 本地开发默认值：sb_publishable_...
    /// 生产环境：从 Supabase Dashboard → Project Settings → API 复制 anon public key
    static let supabaseKey = "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH"
}
