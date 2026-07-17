//
//  LifeMangaApp.swift
//  LifeManga
//
//  应用入口
//

import SwiftUI

@main
struct LifeMangaApp: App {

    @StateObject private var settings = AppSettings()

    init() {
        // 提前 init 后台 URLSession（让它登记到系统）
        _ = BackgroundTaskRunner.shared
        // 申请本地通知权限（首次会弹一次系统弹窗）
        LocalNotifier.requestAuthorizationIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if settings.isLoadingUser {
                    ProgressView("加载中…")
                } else if settings.isLoggedIn {
                    ContentView()
                } else {
                    AuthView()
                }
            }
            .environmentObject(settings)
            .tint(.indigo)
        }
    }
}
