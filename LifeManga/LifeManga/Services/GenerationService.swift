//
//  GenerationService.swift
//  LifeManga
//
//  调用 Supabase Edge Functions 进行图像/剧本生成
//

import Foundation
import UIKit
import Supabase

enum GenerationError: LocalizedError {
    case notAuthenticated
    case insufficientCredits(Int)
    case openAIFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "请先登录"
        case .insufficientCredits(let required):
            return "credits 不足，本次需要 \(required) 个 credits"
        case .openAIFailed(let msg):
            return "生成失败：\(msg)"
        case .invalidResponse:
            return "服务端返回异常"
        }
    }
}

struct GenerateImageResponse: Decodable {
    let success: Bool
    let urls: [String]
    let cost: Int
    let jobId: String?

    enum CodingKeys: String, CodingKey {
        case success
        case urls
        case cost
        case jobId = "job_id"
    }
}

struct GenerateStoryResponse: Decodable {
    let success: Bool
    let script: MangaStoryScript
    let cost: Int
    let jobId: String?

    enum CodingKeys: String, CodingKey {
        case success
        case script
        case cost
        case jobId = "job_id"
    }
}

@MainActor
final class GenerationService {
    static let shared = GenerationService()
    private init() {}

    // MARK: - 普通模式 / 故事模式渲染

    func generateImage(
        inputImages: [UIImage],
        previousPageImage: UIImage? = nil,
        characterReferenceImages: [UIImage] = [],
        characterDirective: String? = nil,
        stylePrompt: String,
        userPrompt: String? = nil,
        n: Int,
        size: String,
        quality: String,
        bubbleTextMode: String,
        storyScript: MangaStoryScript? = nil
    ) async throws -> GenerateImageResponse {

        guard SupabaseClientManager.shared.currentUser != nil else {
            throw GenerationError.notAuthenticated
        }

        let params: [String: Any] = [
            "images": inputImages.map { compressedBase64($0) },
            "stylePrompt": stylePrompt,
            "userPrompt": userPrompt as Any,
            "previousPageImage": previousPageImage.map { compressedBase64($0) } as Any,
            "characterReferenceImages": characterReferenceImages.map { compressedBase64($0) },
            "characterDirective": characterDirective as Any,
            "n": n,
            "size": size,
            "quality": quality,
            "bubbleTextMode": bubbleTextMode,
            "storyScript": storyScript.map { encodeScript($0) } as Any
        ]

        let body = try JSONSerialization.data(withJSONObject: params, options: [.withoutEscapingSlashes])

        let decoded: GenerateImageResponse = try await invokeFunction(
            "generate-image",
            body: body
        )

        if !decoded.success {
            throw GenerationError.openAIFailed("生成失败")
        }

        return decoded
    }

    // MARK: - 故事模式编剧

    func generateStory(
        inputImages: [UIImage],
        styleName: String,
        panelCount: Int,
        userHint: String?,
        scriptModel: String,
        isColor: Bool
    ) async throws -> GenerateStoryResponse {

        guard SupabaseClientManager.shared.currentUser != nil else {
            throw GenerationError.notAuthenticated
        }

        let params: [String: Any] = [
            "images": inputImages.map { compressedBase64($0) },
            "styleName": styleName,
            "panelCount": panelCount,
            "userHint": userHint as Any,
            "scriptModel": scriptModel,
            "isColor": isColor
        ]

        let body = try JSONSerialization.data(withJSONObject: params, options: [.withoutEscapingSlashes])

        let decoded: GenerateStoryResponse = try await invokeFunction(
            "generate-story",
            body: body
        )

        if !decoded.success {
            throw GenerationError.openAIFailed("剧本生成失败")
        }

        return decoded
    }

    // MARK: - 工具方法

    /// 调用 Edge Function 并统一处理 credits 不足 / 服务端错误
    private func invokeFunction<T: Decodable>(_ functionName: String, body: Data) async throws -> T {
        do {
            return try await SupabaseClientManager.shared.client.functions
                .invoke(
                    functionName,
                    options: FunctionInvokeOptions(body: body)
                )
        } catch let error as FunctionsError {
            switch error {
            case .httpError(_, let data):
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let err = json["error"] as? String,
                       err == "Insufficient credits",
                       let required = json["required"] as? Int {
                        throw GenerationError.insufficientCredits(required)
                    }
                    if let err = json["error"] as? String {
                        throw GenerationError.openAIFailed(err)
                    }
                }
                throw GenerationError.openAIFailed("服务端返回错误")
            default:
                throw GenerationError.openAIFailed(error.localizedDescription)
            }
        }
    }

    /// 压缩并转成 base64，控制在 OpenAI 可接受大小内
    private func compressedBase64(_ image: UIImage) -> String {
        let maxSize: CGFloat = 1024
        let scale = min(1.0, min(maxSize / image.size.width, maxSize / image.size.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: image.size.width * scale, height: image.size.height * scale),
            format: format
        )
        let renderSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: renderSize))
        }

        var quality: CGFloat = 0.85
        var data = resized.jpegData(compressionQuality: quality) ?? Data()
        while data.count > 500 * 1024 && quality > 0.4 {
            quality -= 0.1
            data = resized.jpegData(compressionQuality: quality) ?? data
        }

        return data.base64EncodedString()
    }

    private func encodeScript(_ script: MangaStoryScript) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(script),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return [:]
        }
        return json as? [String: Any] ?? [:]
    }

    // MARK: - 角色设定稿

    struct GenerateCharacterResponse: Decodable {
        let success: Bool
        let urls: [String]
        let cost: Int
        let jobId: String?

        enum CodingKeys: String, CodingKey {
            case success
            case urls
            case cost
            case jobId = "job_id"
        }
    }

    enum CharacterGenerationMode: String {
        case sheet = "sheet"
        case poseSheet = "pose_sheet"
    }

    /// 生成角色设定稿（sheet）或动作合集（pose_sheet）
    func generateCharacter(
        mode: CharacterGenerationMode,
        sourceImage: UIImage,
        name: String,
        bio: String?,
        artStyle: CharacterArtStyle? = nil,
        style: MangaStyle? = nil,
        poses: [OpenAIService.CharacterViewSpec]? = nil,
        size: String = "1024x1536",
        quality: String = "medium",
        isColor: Bool = false
    ) async throws -> GenerateCharacterResponse {

        guard SupabaseClientManager.shared.currentUser != nil else {
            throw GenerationError.notAuthenticated
        }

        var params: [String: Any] = [
            "mode": mode.rawValue,
            "sourceImage": compressedBase64(sourceImage),
            "name": name,
            "bio": bio as Any,
            "size": size,
            "quality": quality,
            "isColor": isColor
        ]

        if let artStyle = artStyle {
            params["artStyle"] = artStyle.prompt
        }
        if let style = style {
            params["stylePrompt"] = style.effectivePrompt(isColor: isColor)
        }
        if let poses = poses {
            params["poses"] = poses.map { ["label": $0.label, "prompt": $0.prompt] }
        }

        let body = try JSONSerialization.data(withJSONObject: params, options: [.withoutEscapingSlashes])

        let decoded: GenerateCharacterResponse = try await invokeFunction(
            "generate-character",
            body: body
        )

        if !decoded.success {
            throw GenerationError.openAIFailed("角色生成失败")
        }

        return decoded
    }
}
