//
//  AuthView.swift
//  LifeManga
//
//  登录页：Sign in with Apple
//

import SwiftUI
import AuthenticationServices

struct AuthView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "book.closed.fill")
                .font(.system(size: 80))
                .foregroundStyle(.indigo)

            VStack(spacing: 12) {
                Text("漫画人生")
                    .font(.largeTitle.weight(.bold))
                Text("把生活照片变成日式漫画")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    Text("Sign in with Apple 安全登录")
                }
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .foregroundStyle(.green)
                    Text("你的照片保留在本地设备")
                }
                HStack(spacing: 8) {
                    Image(systemName: "creditcard.fill")
                        .foregroundStyle(.green)
                    Text("注册即送 10 个免费 credits")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Spacer()

            if let error = errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if isLoading {
                ProgressView("正在登录…")
            } else {
                SignInWithAppleButton(
                    .signIn,
                    onRequest: { _ in },
                    onCompletion: { result in
                        handleAppleSignIn(result)
                    }
                )
                .signInWithAppleButtonStyle(.black)
                .frame(height: 52)
                .cornerRadius(10)
                .padding(.horizontal, 32)
            }

            VStack(spacing: 6) {
                Text("登录即表示你同意我们的")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Link("服务条款", destination: URL(string: "https://lifemanga.app/terms")!)
                    Text("和")
                    Link("隐私政策", destination: URL(string: "https://lifemanga.app/privacy")!)
                }
                .font(.caption)
            }

            Spacer().frame(height: 40)
        }
        .padding()
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success:
            isLoading = true
            errorMessage = nil
            Task {
                do {
                    try await AuthService.shared.signInWithApple()
                    await settings.refreshSession()
                } catch {
                    errorMessage = error.localizedDescription
                }
                isLoading = false
            }
        }
    }
}

#Preview {
    AuthView()
        .environmentObject(AppSettings())
}
