//
//  MangaGeneratorViewModel.swift
//  LifeManga
//
//  状态机：
//      .idle  →  .generatingScript  →  .scriptReady  →  .generatingImage  →  .done
//
//  普通模式跳过 .scriptReady，直接 .idle → .generatingImage → .done
//

import Foundation
import SwiftUI
import UIKit

enum GenerationPhase: Equatable {
    case idle
    case generatingScript
    case scriptReady
    case generatingImage
    case done
}

@MainActor
final class MangaGeneratorViewModel: ObservableObject {

    /// 当前所属工程
    var projectId: UUID
    /// 工程名（仅用来发通知文案）
    var projectName: String

    init(projectId: UUID, projectName: String = "") {
        self.projectId = projectId
        self.projectName = projectName
    }

    // 用户选择的输入图
    @Published var selectedImages: [UIImage] = []
    // "前一张" 漫画图（用于风格延续）—— 可来自历史，也可外部上传
    @Published var previousPageImage: UIImage?
    /// 关联的来源 MangaItem（如果是从历史里选的）
    @Published var previousPageSourceId: UUID?
    // 载入的角色（来自角色库）—— 角色立绘会作为参考图随请求一起发
    @Published var loadedCharacters: [Character] = []
    // 当前风格
    @Published var style: MangaStyle = .shonenJump
    // 用户额外补充的描述
    @Published var userPrompt: String = ""
    // 故事模式开关
    @Published var storyMode: Bool = false
    // 故事模式分镜数
    @Published var panelCount: Int = 6
    // 彩色 / 黑白
    @Published var isColor: Bool = false
    // 气泡里文字 "chinese" / "japanese" / "english" / "empty" / "none"
    @Published var bubbleTextMode: String = "chinese"

    // 状态
    @Published var phase: GenerationPhase = .idle
    @Published var stageMessage: String = ""

    // 生成结果
    @Published var generatedImages: [UIImage] = []
    /// 当前剧本（可被用户编辑后再用于绘画）
    @Published var generatedScript: MangaStoryScript?

    // UI
    @Published var errorMessage: String?
    @Published var errorIsSafetyBlocked: Bool = false
    @Published var lastSaved: MangaItem?

    var isGenerating: Bool {
        phase == .generatingScript || phase == .generatingImage
    }

    // MARK: - 操作

    func addImage(_ img: UIImage) {
        selectedImages.append(img)
    }

    func removeImage(at index: Int) {
        guard selectedImages.indices.contains(index) else { return }
        selectedImages.remove(at: index)
    }

    func reset() {
        selectedImages = []
        previousPageImage = nil
        previousPageSourceId = nil
        loadedCharacters = []
        userPrompt = ""
        generatedImages = []
        generatedScript = nil
        stageMessage = ""
        lastSaved = nil
        phase = .idle
    }

    func clearPreviousPage() {
        previousPageImage = nil
        previousPageSourceId = nil
    }

    func loadCharacter(_ c: Character) {
        if !loadedCharacters.contains(where: { $0.id == c.id }) {
            loadedCharacters.append(c)
        }
    }

    func unloadCharacter(_ c: Character) {
        loadedCharacters.removeAll { $0.id == c.id }
    }

    /// 把所有载入角色的"正面"立绘（没有就退而求其次取第一张）作为参考图
    func characterReferenceImages() -> [UIImage] {
        var imgs: [UIImage] = []
        for c in loadedCharacters {
            let view = c.views.first(where: { $0.label == "正面" }) ?? c.views.first
            if let n = view?.imageName, let ui = CharacterStore.shared.image(named: n) {
                imgs.append(ui)
            } else if let n = c.sourcePhotoName,
                      let ui = CharacterStore.shared.image(named: n) {
                imgs.append(ui)
            }
        }
        return imgs
    }

    func charactersDirective() -> String? {
        guard !loadedCharacters.isEmpty else { return nil }
        let names = loadedCharacters.map { $0.name }.joined(separator: "、")
        return """
        CHARACTER REFERENCE:
        I have attached \(loadedCharacters.count) character reference image(s) at the end of \
        the input set. These represent the recurring characters that should appear in this \
        page (\(names)). Match their faces, hair, outfits and overall design EXACTLY as shown. \
        Do not redesign them.
        """
    }

    /// 抛弃当前剧本，回到空闲态（用于"重新构思剧情"的入口前）
    func discardScript() {
        generatedScript = nil
        phase = .idle
    }

    /// 主入口：根据当前 phase + storyMode 决定下一步
    func generate(settings: AppSettings) async {
        guard !selectedImages.isEmpty else {
            errorMessage = "请先至少选择一张图片"
            return
        }
        errorIsSafetyBlocked = false

        // 故事模式下，如果剧本已就绪则进入第 2 步；否则先编剧
        if storyMode {
            switch phase {
            case .scriptReady:
                await runStoryMode_renderImage(settings: settings)
            default:
                await runStoryMode_writeScript(settings: settings)
            }
        } else {
            await runSimpleMode(settings: settings)
        }
    }

    /// 重新构思剧情（保留所有其他设置，只把剧本扔掉重写）
    func regenerateScript(settings: AppSettings) async {
        generatedScript = nil
        await runStoryMode_writeScript(settings: settings)
    }

    // MARK: - 普通模式

    private func runSimpleMode(settings: AppSettings) async {
        phase = .generatingImage
        stageMessage = "AI 正在绘制中…"

        let n = max(1, min(settings.imageCount, 4))
        let size = settings.imageSize
        let quality = settings.imageQuality

        let req = OpenAIImageRequest(
            inputImages: selectedImages,
            previousPageImage: previousPageImage,
            characterReferenceImages: characterReferenceImages(),
            characterDirective: charactersDirective(),
            stylePrompt: style.effectivePrompt(isColor: isColor),
            userPrompt: userPrompt.isEmpty ? nil : userPrompt,
            n: n,
            size: size,
            quality: quality,
            bubbleTextMode: bubbleTextMode
        )

        // ── 防重复请求 ──
        let hash = req.fingerprint
        if let dup = JobStore.shared.recentJob(matchingHash: hash, withinSeconds: 60) {
            self.errorMessage = "60 秒内有相同请求（任务 \(dup.id.uuidString.prefix(8))），" +
                                "为避免重复扣费已拦截。请稍后再试或在任务列表查看上一个。"
            self.errorIsSafetyBlocked = false
            phase = .idle
            return
        }

        // 先预分配 jobId，把输入图存到磁盘（用于"重新生成"按钮）
        let jobId = UUID()
        let pending = JobStore.shared.savePendingInputs(
            jobId: jobId,
            inputs: selectedImages,
            previousPage: previousPageImage
        )

        JobStore.shared.startJob(
            id: jobId,
            projectId: projectId,
            projectName: projectName,
            style: style,
            kind: .simpleImage,
            stageMessage: "已提交服务器，生成可能需要 1~5 分钟…",
            inputImageFiles: pending.inputs,
            previousPageFile: pending.previous,
            characterIds: loadedCharacters.map { $0.id },
            userPromptText: userPrompt.isEmpty ? nil : userPrompt,
            bubbleMode: bubbleTextMode,
            wasColorOn: isColor,
            imageCount: n,
            imageSizeStr: size,
            imageQualityStr: quality,
            requestHash: hash
        )
        do {
            let result = try await GenerationService.shared.generateImage(
                inputImages: selectedImages,
                previousPageImage: previousPageImage,
                characterReferenceImages: characterReferenceImages(),
                characterDirective: charactersDirective(),
                stylePrompt: style.effectivePrompt(isColor: isColor),
                userPrompt: userPrompt.isEmpty ? nil : userPrompt,
                n: n,
                size: size,
                quality: quality,
                bubbleTextMode: bubbleTextMode
            )

            // 下载生成的图片
            let datas = try await downloadImages(from: result.urls)
            self.generatedImages = datas.compactMap { UIImage(data: $0) }

            let inputDatas = selectedImages.compactMap { $0.pngData() }
            let savedItem = MangaStorage.shared.add(
                projectId: projectId,
                style: style,
                inputs: inputDatas,
                outputs: datas,
                userPrompt: userPrompt.isEmpty ? nil : userPrompt,
                storyScript: nil
            )
            self.lastSaved = savedItem
            phase = .done
            JobStore.shared.complete(jobId, with: savedItem.id)
            LocalNotifier.notifyDone(
                title: "漫画生成完成",
                body: "\(projectName)：\(style.displayName) · 共 \(savedItem.outputImageNames.count) 张"
            )
        } catch GenerationError.insufficientCredits(let required) {
            self.errorMessage = "credits 不足，本次需要 \(required) 个 credits。请前往设置购买。"
            phase = .idle
            JobStore.shared.fail(jobId, message: "credits 不足", errorCode: "INSUFFICIENT_CREDITS")
        } catch {
            self.handleError(error)
            phase = .idle
            resolveJobError(error, jobId: jobId)
        }
        stageMessage = ""
    }

    // MARK: - 故事模式 第 1 步：编剧

    private func runStoryMode_writeScript(settings: AppSettings) async {
        phase = .generatingScript
        do {
            let result = try await GenerationService.shared.generateStory(
                inputImages: selectedImages,
                styleName: style.displayName,
                panelCount: max(2, min(panelCount, 9)),
                userHint: userPrompt.isEmpty ? nil : userPrompt,
                scriptModel: settings.scriptModel,
                isColor: isColor
            )
            self.generatedScript = result.script
            phase = .scriptReady
        } catch GenerationError.insufficientCredits(let required) {
            self.errorMessage = "credits 不足，本次需要 \(required) 个 credits。请前往设置购买。"
            phase = .idle
        } catch {
            self.handleError(error)
            phase = .idle
        }
        stageMessage = ""
    }

    // MARK: - 故事模式 第 2 步：绘画（用户可能已经编辑过 generatedScript）

    private func runStoryMode_renderImage(settings: AppSettings) async {
        guard let script = generatedScript else {
            errorMessage = "没有可用的剧本"
            return
        }
        phase = .generatingImage
        let jobId = JobStore.shared.startJob(
            projectId: projectId,
            projectName: projectName,
            style: style,
            kind: .storyRender,
            stageMessage: "AI 正在分镜作画…",
            subtitle: script.title
        )
        do {
            let result = try await GenerationService.shared.generateImage(
                inputImages: selectedImages,
                previousPageImage: previousPageImage,
                characterReferenceImages: characterReferenceImages(),
                characterDirective: charactersDirective(),
                stylePrompt: style.effectivePrompt(isColor: isColor),
                userPrompt: userPrompt.isEmpty ? nil : userPrompt,
                n: 1,
                size: settings.imageSize,
                quality: settings.imageQuality,
                bubbleTextMode: bubbleTextMode,
                storyScript: script
            )

            let datas = try await downloadImages(from: result.urls)
            self.generatedImages = datas.compactMap { UIImage(data: $0) }

            let inputDatas = selectedImages.compactMap { $0.pngData() }
            let saved = MangaStorage.shared.add(
                projectId: projectId,
                style: style,
                inputs: inputDatas,
                outputs: datas,
                userPrompt: userPrompt.isEmpty ? nil : userPrompt,
                storyScript: script
            )
            self.lastSaved = saved
            phase = .done
            JobStore.shared.complete(jobId, with: saved.id)
            LocalNotifier.notifyDone(
                title: "漫画生成完成",
                body: "\(projectName)：\(script.title)"
            )
        } catch GenerationError.insufficientCredits(let required) {
            self.errorMessage = "credits 不足，本次需要 \(required) 个 credits。请前往设置购买。"
            phase = .scriptReady
            JobStore.shared.fail(jobId, message: "credits 不足", errorCode: "INSUFFICIENT_CREDITS")
        } catch {
            self.handleError(error)
            // 失败后回到 scriptReady，让用户可以再次尝试
            phase = .scriptReady
            resolveJobError(error, jobId: jobId)
        }
        stageMessage = ""
    }

    // MARK: - 工具

    /// 从 URL 数组并行下载图片
    private func downloadImages(from urls: [String]) async throws -> [Data] {
        try await withThrowingTaskGroup(of: Data.self) { group in
            for urlString in urls {
                group.addTask {
                    guard let url = URL(string: urlString) else {
                        throw URLError(.badURL)
                    }
                    let (data, _) = try await URLSession.shared.data(from: url)
                    return data
                }
            }

            var results: [Data] = []
            for try await data in group {
                results.append(data)
            }
            return results
        }
    }

    private func currentStoryRequest(settings: AppSettings) -> OpenAIStoryRequest {
        OpenAIStoryRequest(
            inputImages: selectedImages,
            previousPageImage: previousPageImage,
            characterReferenceImages: characterReferenceImages(),
            characterDirective: charactersDirective(),
            style: style,
            userHint: userPrompt.isEmpty ? nil : userPrompt,
            panelCount: max(2, min(panelCount, 9)),
            scriptModel: settings.scriptModel,
            size: settings.imageSize,
            quality: settings.imageQuality,
            bubbleTextMode: bubbleTextMode,
            isColor: isColor
        )
    }

    private func handleError(_ error: Error) {
        self.errorMessage = error.localizedDescription
        if let oa = error as? OpenAIError {
            self.errorIsSafetyBlocked = oa.isSafetyBlocked
        } else {
            self.errorIsSafetyBlocked = false
        }
    }
}

// 顶层引用（withDeadline / TaskTimeoutError 在 OpenAIService.swift 里定义）
// 这里不需要再 import 任何东西，全部在同一 module 内
