//
//  AuthService.swift
//  LifeManga
//
//  Sign in with Apple + Supabase Auth 封装
//

import Foundation
import AuthenticationServices
import Supabase

enum AuthError: LocalizedError {
    case missingCredential
    case invalidToken
    case signInFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "无法获取 Apple 登录凭证"
        case .invalidToken:
            return "Apple ID Token 无效"
        case .signInFailed(let msg):
            return "登录失败：\(msg)"
        }
    }
}

@MainActor
final class AuthService: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {

    static let shared = AuthService()

    private var continuation: CheckedContinuation<Void, Error>?

    private override init() {}

    // MARK: - 登录入口

    func signInWithApple() async throws {
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont

            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.fullName, .email]

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    // MARK: - 登出

    func signOut() async throws {
        try await SupabaseClientManager.shared.client.auth.signOut()
    }

    // MARK: - 删除账号

    func deleteAccount() async throws {
        // 先调 Edge Function 删除账号（使用 service_role 清理云端数据）
        let session = try await SupabaseClientManager.shared.client.auth.session
        _ = try await SupabaseClientManager.shared.client.functions
            .invoke(
                "delete-account",
                options: FunctionInvokeOptions(
                    headers: ["Authorization": "Bearer \(session.accessToken)"]
                )
            )

        // 再清理本地登录状态
        try await SupabaseClientManager.shared.client.auth.signOut()
    }

    // MARK: - ASAuthorizationControllerDelegate

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityTokenData = credential.identityToken,
              let identityToken = String(data: identityTokenData, encoding: .utf8) else {
            continuation?.resume(throwing: AuthError.invalidToken)
            continuation = nil
            return
        }

        Task {
            do {
                try await SupabaseClientManager.shared.client.auth
                    .signInWithIdToken(
                        credentials: .init(
                            provider: .apple,
                            idToken: identityToken
                        )
                    )

                // 更新 profile 显示名（Apple 只在首次登录返回 fullName）
                if let fullName = credential.fullName {
                    let displayName = [fullName.givenName, fullName.familyName]
                        .compactMap { $0 }
                        .joined(separator: " ")
                    if !displayName.isEmpty {
                        try? await updateDisplayName(displayName)
                    }
                }

                continuation?.resume()
                continuation = nil
            } catch {
                continuation?.resume(throwing: AuthError.signInFailed(error.localizedDescription))
                continuation = nil
            }
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    // MARK: - ASAuthorizationControllerPresentationContextProviding

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // 返回应用当前 key window
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows
            .first { $0.isKeyWindow } ?? UIWindow()
    }

    // MARK: - 私有方法

    private func updateDisplayName(_ name: String) async throws {
        let userId = try await SupabaseClientManager.shared.client.auth.session.user.id
        try await SupabaseClientManager.shared.client
            .from("profiles")
            .update(["display_name": name, "updated_at": ISO8601DateFormatter().string(from: Date())])
            .eq("id", value: userId)
            .execute()
    }
}
