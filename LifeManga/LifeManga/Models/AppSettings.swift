//
//  AppSettings.swift
//  LifeManga
//
//  全局可观察的应用设置。API Key 不在这里 —— 它存在 Keychain。
//

import Foundation
import SwiftUI
import Supabase

@MainActor
final class AppSettings: ObservableObject {
    // MARK: - 用户偏好（持久化到 UserDefaults）

    @AppStorage("defaultStyle")    private var defaultStyleRaw: String = MangaStyle.shonenJump.rawValue
    @AppStorage("imageCount")      var imageCount: Int = 1
    @AppStorage("imageSize")       var imageSize: String = "1024x1536"
    @AppStorage("imageQuality")    var imageQuality: String = "medium"
    /// 故事模式开关
    @AppStorage("storyModeOn")     var storyModeOn: Bool = false
    /// 故事模式分镜格数
    @AppStorage("panelCount")      var panelCount: Int = 6
    /// 故事模式使用的视觉/编剧模型（GPT-5 系列，2026 年最新）
    @AppStorage("scriptModel")     var scriptModel: String = "gpt-5.4-mini"
    /// 气泡内文字渲染模式: "chinese" / "japanese" / "english" / "empty" / "none"
    /// gpt-image-2 已经能很好地渲染中文，所以默认用 "chinese"
    @AppStorage("bubbleTextMode")  var bubbleTextMode: String = "chinese"
    /// 全局色彩开关：true 彩色 / false 黑白
    @AppStorage("colorMode")       var isColor: Bool = false

    static let bubbleTextModes: [(id: String, label: String, hint: String)] = [
        ("chinese",  "中文",      "气泡里画中文台词（推荐）"),
        ("japanese", "日文假名",   "气泡里画日文假名，怀旧 manga 感"),
        ("english",  "英文",      "气泡里画英文台词（最稳，海外漫画感）"),
        ("empty",    "留空",      "气泡画出来但里面不写字"),
        ("none",     "无对话框",   "完全不画对话框，纯视觉漫画")
    ]

    // MARK: - 登录状态与 Credits

    @Published var currentUser: User?
    @Published var credits: Int = 0
    @Published var isLoadingUser: Bool = true

    var isLoggedIn: Bool { currentUser != nil }

    var defaultStyle: MangaStyle {
        get { MangaStyle(rawValue: defaultStyleRaw) ?? .shonenJump }
        set { defaultStyleRaw = newValue.rawValue }
    }

    /// gpt-image-2 支持的常用尺寸
    static let availableSizes = [
        "1024x1024",   // 1:1 标准
        "1024x1536",   // 2:3 漫画页（推荐）
        "1536x1024",   // 3:2 横幅
        "2048x2048",   // 2K 方形
        "2160x3840",   // 4K 漫画页（实验性）
        "3840x2160",   // 4K 横幅（实验性）
        "auto"
    ]
    static let availableQualities = ["low", "medium", "high", "auto"]

    init() {
        Task {
            await refreshSession()
        }
    }

    /// 刷新当前会话与 credits
    func refreshSession() async {
        isLoadingUser = true
        defer { isLoadingUser = false }

        do {
            let session = try await SupabaseClientManager.shared.client.auth.session
            currentUser = session.user
            if currentUser != nil {
                await refreshCredits()
                SyncService.shared.syncAllIfLoggedIn()
            }
        } catch {
            currentUser = nil
            credits = 0
        }
    }

    /// 刷新 credits 余额
    func refreshCredits() async {
        do {
            let info = try await CreditService.shared.fetchCredits()
            credits = info.total
        } catch {
            print("刷新 credits 失败:", error)
        }
    }

    /// 登出
    func signOut() async {
        do {
            try await AuthService.shared.signOut()
            currentUser = nil
            credits = 0
        } catch {
            print("登出失败:", error)
        }
    }
}
