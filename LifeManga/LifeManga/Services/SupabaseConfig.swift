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
    static let supabaseURL = URL(string: "https://ehhnovnmzxobdyoytjht.supabase.co")!

    /// Supabase publishable (anon) key
    /// 本地开发默认值：sb_publishable_...
    /// 生产环境：从 Supabase Dashboard → Project Settings → API 复制 anon public key
    static let supabaseKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVoaG5vdm5tenhvYmR5b3l0amh0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQyNzk5OTIsImV4cCI6MjA5OTg1NTk5Mn0.VjWc8oO6OhHrwiNRG0GATxy4PPnk06gNSYfo4kesMM8"
}
