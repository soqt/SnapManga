//
//  MangaStorage.swift
//  LifeManga
//
//  本地持久化：
//   - 工程列表       → Documents/projects.json
//   - 全部生成历史    → Documents/manga_index.json
//   - 输入/输出图片  → Documents/MangaImages/<uuid>_in_*.png  /  _out_*.png
//

import Foundation
import UIKit

// MARK: - JobStore：任务管理（运行中 / 完成 / 失败）

enum JobKind: String, Codable {
    case simpleImage     // 普通模式：照片→单张漫画
    case storyScript     // 故事模式 第 1 步：编剧本（可选追踪）
    case storyRender     // 故事模式 第 2 步：分镜作画
    case characterViews  // 角色库：从真人照片生成多视图角色立绘
}

enum JobPhase: Codable, Equatable {
    case running                          // 上传 / OpenAI 处理中（统一标）
    case timeoutUnknown(message: String)  // 客户端超时，OpenAI 可能仍在跑，结果未知
    case done(itemId: UUID)
    case failed(message: String)

    var isRunning: Bool { if case .running = self { return true }; return false }
    var isDone:    Bool { if case .done    = self { return true }; return false }
    var isFailed:  Bool { if case .failed  = self { return true }; return false }
    var isTimeoutUnknown: Bool {
        if case .timeoutUnknown = self { return true }; return false
    }
    /// 终态（不会再变化）—— done / failed 算终态，timeoutUnknown 也算终态（不能自动重试）
    var isFinal: Bool { isDone || isFailed || isTimeoutUnknown }
}

struct Job: Identifiable, Codable, Equatable {
    let id: UUID
    /// 漫画任务对应的工程；角色任务为 nil
    let projectId: UUID?
    let projectName: String
    let style: MangaStyle
    let kind: JobKind
    let createdAt: Date
    var finishedAt: Date?
    var phase: JobPhase
    var stageMessage: String
    /// 副标题（比如剧本标题、或角色一句话设定）
    var subtitle: String?
    /// 角色任务专用：关联的角色 id / 名字
    var characterId: UUID?
    var characterName: String?
    /// 角色设定稿专用：使用的艺术风格（用于"重新生成"按钮还原参数）
    var artStyle: CharacterArtStyle?

    // MARK: - 漫画任务"重新生成"所需的输入快照
    // 这些字段都是可选的，老数据没有，不会破坏解码
    /// 输入图保存的文件名列表（位于 Documents/PendingJobInputs/<jobId>/）
    var inputImageFiles: [String]?
    /// "前一张"参考图保存的文件名（可选）
    var previousPageFile: String?
    /// 任务发起时载入的角色 id（重试时再用 CharacterStore 解析回 UIImage）
    var characterIds: [UUID]?
    /// 用户额外补充描述
    var userPromptText: String?
    /// 气泡文字模式 "chinese" / "japanese" / "english" / "empty" / "none"
    var bubbleMode: String?
    /// 是否彩色
    var wasColorOn: Bool?
    /// 一次生成几张
    var imageCount: Int?
    /// "1024x1536" 等
    var imageSizeStr: String?
    /// "low" / "medium" / "high" 等
    var imageQualityStr: String?

    // MARK: - 防重复请求 / 计费追踪
    /// 请求指纹（输入图 + prompt + 参数 hash），用于"60秒内同样请求拦截"
    var requestHash: String?
    /// 用户手动「重新生成」的次数（自动重试永远是 0，因为禁止）
    var manualRetryCount: Int = 0
    /// 错误代码（如 "URL_TIMEOUT" / "WALLCLOCK_TIMEOUT" / "HTTP_500" / "SAFETY"）
    var errorCode: String?
    /// 上传完成、OpenAI 开始 GPU 工作的大致时刻（用首字节延迟前的时间）
    var openaiStartedAt: Date?

    /// 给 UI 展示用：角色任务用角色名，其它用工程名
    var displayName: String {
        if let n = characterName, !n.isEmpty { return n }
        return projectName
    }

    /// 是否可以"重新生成"——只允许用户手动按按钮触发（绝不自动）。
    /// 失败 / 超时未知 都允许；done / running 不允许。
    var canRetry: Bool {
        switch phase {
        case .failed, .timeoutUnknown:
            break
        case .done, .running:
            return false
        }
        switch kind {
        case .characterViews:
            return artStyle != nil && characterId != nil
        case .simpleImage:
            return (inputImageFiles?.isEmpty == false)
        default:
            return false
        }
    }

    init(id: UUID = UUID(),
         projectId: UUID? = nil,
         projectName: String = "",
         style: MangaStyle,
         kind: JobKind,
         stageMessage: String = "排队中…",
         subtitle: String? = nil,
         characterId: UUID? = nil,
         characterName: String? = nil,
         artStyle: CharacterArtStyle? = nil,
         inputImageFiles: [String]? = nil,
         previousPageFile: String? = nil,
         characterIds: [UUID]? = nil,
         userPromptText: String? = nil,
         bubbleMode: String? = nil,
         wasColorOn: Bool? = nil,
         imageCount: Int? = nil,
         imageSizeStr: String? = nil,
         imageQualityStr: String? = nil,
         requestHash: String? = nil,
         manualRetryCount: Int = 0) {
        self.id = id
        self.projectId = projectId
        self.projectName = projectName
        self.style = style
        self.kind = kind
        self.createdAt = Date()
        self.phase = .running
        self.stageMessage = stageMessage
        self.subtitle = subtitle
        self.characterId = characterId
        self.characterName = characterName
        self.artStyle = artStyle
        self.inputImageFiles = inputImageFiles
        self.previousPageFile = previousPageFile
        self.characterIds = characterIds
        self.userPromptText = userPromptText
        self.bubbleMode = bubbleMode
        self.wasColorOn = wasColorOn
        self.imageCount = imageCount
        self.imageSizeStr = imageSizeStr
        self.imageQualityStr = imageQualityStr
        self.requestHash = requestHash
        self.manualRetryCount = manualRetryCount
    }
}

@MainActor
final class JobStore: ObservableObject {

    static let shared = JobStore()

    @Published private(set) var jobs: [Job] = []

    /// 任务日志（仅内存，不持久化）—— App 重启会清空
    @Published private(set) var logs: [UUID: [JobLogEntry]] = [:]

    /// 运行中任务的 Swift Task 引用 —— 用于支持取消
    /// 注意：这些不持久化；App 重启后所有任务都被 sweep 成失败
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    private let fileManager = FileManager.default
    private var documents: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    private var indexURL: URL { documents.appendingPathComponent("jobs.json") }
    /// 用于保存"未完成任务的输入图"，给重试用
    private var pendingInputsRoot: URL {
        let dir = documents.appendingPathComponent("PendingJobInputs", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private init() {
        load()
        // 把"启动前残留为 running"的任务标为失败（因为它们其实早死了）
        sweepStaleRunningJobs()
    }

    // MARK: - 计算属性

    var runningCount: Int { jobs.filter { $0.phase.isRunning }.count }
    var hasAny: Bool { !jobs.isEmpty }

    // MARK: - 增改

    @discardableResult
    func startJob(id: UUID = UUID(),
                  projectId: UUID? = nil,
                  projectName: String = "",
                  style: MangaStyle,
                  kind: JobKind,
                  stageMessage: String = "已开始…",
                  subtitle: String? = nil,
                  characterId: UUID? = nil,
                  characterName: String? = nil,
                  artStyle: CharacterArtStyle? = nil,
                  inputImageFiles: [String]? = nil,
                  previousPageFile: String? = nil,
                  characterIds: [UUID]? = nil,
                  userPromptText: String? = nil,
                  bubbleMode: String? = nil,
                  wasColorOn: Bool? = nil,
                  imageCount: Int? = nil,
                  imageSizeStr: String? = nil,
                  imageQualityStr: String? = nil,
                  requestHash: String? = nil,
                  manualRetryCount: Int = 0) -> UUID {
        let job = Job(id: id,
                      projectId: projectId,
                      projectName: projectName,
                      style: style,
                      kind: kind,
                      stageMessage: stageMessage,
                      subtitle: subtitle,
                      characterId: characterId,
                      characterName: characterName,
                      artStyle: artStyle,
                      inputImageFiles: inputImageFiles,
                      previousPageFile: previousPageFile,
                      characterIds: characterIds,
                      userPromptText: userPromptText,
                      bubbleMode: bubbleMode,
                      wasColorOn: wasColorOn,
                      imageCount: imageCount,
                      imageSizeStr: imageSizeStr,
                      imageQualityStr: imageQualityStr,
                      requestHash: requestHash,
                      manualRetryCount: manualRetryCount)
        jobs.insert(job, at: 0)
        save()
        return job.id
    }

    // MARK: - 防重复请求

    /// 找出最近 N 秒内同 hash 且仍未完结 / 刚完成的任务（避免重复扣费）
    func recentJob(matchingHash hash: String, withinSeconds: TimeInterval = 60) -> Job? {
        let cutoff = Date().addingTimeInterval(-withinSeconds)
        return jobs.first { j in
            guard j.requestHash == hash else { return false }
            // 仍在跑 → 拦截
            if j.phase.isRunning { return true }
            // 终态但发生时间很近 → 也拦截
            return (j.finishedAt ?? j.createdAt) > cutoff
        }
    }

    // MARK: - 终态转移：超时未知（OpenAI 可能仍在处理 → 不允许自动重试）

    func markTimeoutUnknown(_ jobId: UUID, message: String, errorCode: String? = nil) {
        guard let i = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[i].phase = .timeoutUnknown(message: message)
        jobs[i].finishedAt = Date()
        jobs[i].stageMessage = "⏳ 客户端超时（OpenAI 可能仍在生成）"
        jobs[i].errorCode = errorCode
        activeTasks.removeValue(forKey: jobId)
        // 注意：故意不清 PendingJobInputs，让用户能手动重试
        save()
    }

    /// 标记 OpenAI 已经开始处理（从首字节日志触发）
    func markOpenAIStarted(_ jobId: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        if jobs[i].openaiStartedAt == nil {
            jobs[i].openaiStartedAt = Date()
            save()
        }
    }

    // MARK: - 重试用：把任务输入图临时存到磁盘

    /// 给指定 jobId 的目录（需要时自动创建）
    private func pendingDir(_ jobId: UUID) -> URL {
        let dir = pendingInputsRoot.appendingPathComponent(jobId.uuidString, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 把一组输入图 + 可选的"前一张"图保存到 jobId 对应目录。
    /// 返回相对文件名列表，用来塞到 Job 里。
    @discardableResult
    func savePendingInputs(jobId: UUID,
                           inputs: [UIImage],
                           previousPage: UIImage?) -> (inputs: [String], previous: String?) {
        let dir = pendingDir(jobId)
        var inputNames: [String] = []
        for (i, img) in inputs.enumerated() {
            let name = "in_\(i).jpg"
            if let data = img.jpegData(compressionQuality: 0.85) {
                try? data.write(to: dir.appendingPathComponent(name))
                inputNames.append(name)
            }
        }
        var prevName: String? = nil
        if let p = previousPage, let data = p.jpegData(compressionQuality: 0.85) {
            let name = "prev.jpg"
            try? data.write(to: dir.appendingPathComponent(name))
            prevName = name
        }
        return (inputNames, prevName)
    }

    /// 重试时根据 Job 里保存的文件名读回原图
    func loadPendingImage(_ filename: String, jobId: UUID) -> UIImage? {
        let url = pendingDir(jobId).appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// 任务彻底用不到了再清掉（done / 用户手动 remove）
    func clearPendingInputs(jobId: UUID) {
        let dir = pendingInputsRoot.appendingPathComponent(jobId.uuidString, isDirectory: true)
        try? fileManager.removeItem(at: dir)
    }

    func updateStage(_ jobId: UUID, _ message: String) {
        guard let i = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[i].stageMessage = message
        save()
    }

    func updateSubtitle(_ jobId: UUID, _ subtitle: String) {
        guard let i = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[i].subtitle = subtitle
        save()
    }

    func complete(_ jobId: UUID, with itemId: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[i].phase = .done(itemId: itemId)
        jobs[i].finishedAt = Date()
        jobs[i].stageMessage = "已完成"
        activeTasks.removeValue(forKey: jobId)
        // 任务已成功，重试用的临时输入图可以清掉
        clearPendingInputs(jobId: jobId)
        save()
    }

    func fail(_ jobId: UUID, message: String, errorCode: String? = nil) {
        guard let i = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[i].phase = .failed(message: message)
        jobs[i].finishedAt = Date()
        jobs[i].stageMessage = "失败"
        jobs[i].errorCode = errorCode
        activeTasks.removeValue(forKey: jobId)
        save()
    }

    /// 注册 Task 引用，让任务可被外部取消
    func attachTask(_ task: Task<Void, Never>, to jobId: UUID) {
        activeTasks[jobId] = task
    }

    // MARK: - 日志

    /// 给某个任务追加一条日志（限制最近 200 条避免无限增长）
    func log(_ jobId: UUID, _ message: String, level: JobLogEntry.Level = .info) {
        var arr = logs[jobId] ?? []
        arr.append(JobLogEntry(level: level, message: message))
        if arr.count > 200 { arr.removeFirst(arr.count - 200) }
        logs[jobId] = arr
    }

    /// 跨 actor 安全调用版本
    nonisolated static func log(_ jobId: UUID?,
                                _ message: String,
                                level: JobLogEntry.Level = .info) {
        guard let id = jobId else { return }
        Task { @MainActor in
            JobStore.shared.log(id, message, level: level)
        }
    }

    func entries(for jobId: UUID) -> [JobLogEntry] {
        logs[jobId] ?? []
    }

    func clearLogs(for jobId: UUID) {
        logs.removeValue(forKey: jobId)
    }

    /// 取消运行中的任务
    func cancel(_ jobId: UUID) {
        activeTasks[jobId]?.cancel()
        activeTasks.removeValue(forKey: jobId)
        // Task 自己 catch 到 cancellation 后会调 fail()，所以这里不用直接改状态
        // 但万一 Task 没及时响应取消，给个兜底
        if let i = jobs.firstIndex(where: { $0.id == jobId && $0.phase.isRunning }) {
            jobs[i].phase = .failed(message: "已取消")
            jobs[i].finishedAt = Date()
            jobs[i].stageMessage = "已取消"
            save()
        }
    }

    // MARK: - 删除

    func remove(_ job: Job) {
        jobs.removeAll { $0.id == job.id }
        logs.removeValue(forKey: job.id)
        clearPendingInputs(jobId: job.id)
        save()
    }

    func clearFinished() {
        let toRemove = jobs.filter { $0.phase.isRunning == false }
        for j in toRemove { clearPendingInputs(jobId: j.id) }
        jobs.removeAll { $0.phase.isRunning == false }
        save()
    }

    func clearAll() {
        for job in jobs { clearPendingInputs(jobId: job.id) }
        jobs.removeAll()
        logs.removeAll()
        save()
    }

    // MARK: - 启动期清理

    /// App 上次运行时还在 .running，但 App 重启意味着客户端进程已经死了。
    /// 此时**不能**判定 OpenAI 端是否完成 / 仍在跑 / 失败，所以归到 timeoutUnknown，
    /// 让用户自己决定是否手动重试，避免无脑自动重发导致重复扣费。
    private func sweepStaleRunningJobs() {
        var changed = false
        for i in jobs.indices where jobs[i].phase.isRunning {
            jobs[i].phase = .timeoutUnknown(
                message: "App 重启时任务还在跑。OpenAI 端可能已生成（图片在后台 dashboard 可查），" +
                         "也可能因为客户端断开被中止。如要再次生成，请确认账户没有重复扣费后手动点「重新生成」。"
            )
            jobs[i].finishedAt = Date()
            jobs[i].stageMessage = "⏳ 客户端中断（结果未知）"
            jobs[i].errorCode = "APP_RESTART"
            changed = true
        }
        if changed { save() }
    }

    // MARK: - 持久化

    private func save() {
        do {
            let data = try JSONEncoder().encode(jobs)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("⚠️ JobStore save error:", error)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Job].self, from: data) else {
            return
        }
        self.jobs = decoded
    }
}

// MARK: - CharacterStore：角色库

@MainActor
final class CharacterStore: ObservableObject {

    static let shared = CharacterStore()

    @Published private(set) var characters: [Character] = []

    private let fileManager = FileManager.default

    private var documents: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    private var indexURL: URL { documents.appendingPathComponent("characters.json") }
    private var imagesDir: URL {
        let dir = documents.appendingPathComponent("CharacterImages", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private init() { load() }

    // MARK: 公共方法

    @discardableResult
    func create(name: String,
                bio: String?,
                sourcePhoto: Data?) -> Character {
        var sourcePhotoName: String? = nil
        let id = UUID()
        if let data = sourcePhoto {
            let n = "\(id.uuidString)_source.png"
            try? data.write(to: imagesDir.appendingPathComponent(n))
            sourcePhotoName = n
        }
        let c = Character(id: id,
                          name: name.isEmpty ? "未命名角色" : name,
                          bio: bio,
                          sourcePhotoName: sourcePhotoName,
                          views: [])
        characters.insert(c, at: 0)
        save()
        SyncService.shared.syncAllIfLoggedIn()
        return c
    }

    func delete(_ character: Character) {
        // 清掉关联图片
        if let n = character.sourcePhotoName {
            try? fileManager.removeItem(at: imagesDir.appendingPathComponent(n))
        }
        for v in character.views {
            try? fileManager.removeItem(at: imagesDir.appendingPathComponent(v.imageName))
        }
        characters.removeAll { $0.id == character.id }
        save()
        SyncService.shared.deleteCharacter(id: character.id)
    }

    func deleteAll() {
        for character in characters {
            if let n = character.sourcePhotoName {
                try? fileManager.removeItem(at: imagesDir.appendingPathComponent(n))
            }
            for v in character.views {
                try? fileManager.removeItem(at: imagesDir.appendingPathComponent(v.imageName))
            }
        }
        characters.removeAll()
        save()
    }

    /// 用云端合并后的数据替换本地角色列表（同步专用，不触发再次同步）
    func replaceSynced(_ characters: [Character]) {
        self.characters = characters
        save()
    }

    func rename(_ character: Character, name: String) {
        guard let i = characters.firstIndex(where: { $0.id == character.id }) else { return }
        characters[i].name = name
        characters[i].updatedAt = Date()
        save()
        SyncService.shared.syncAllIfLoggedIn()
    }

    /// 添加（或附加）若干个新视图到角色
    func addViews(to characterId: UUID, views: [(label: String, imageData: Data)]) {
        guard let i = characters.firstIndex(where: { $0.id == characterId }) else { return }
        for v in views {
            let name = "\(UUID().uuidString)_view.png"
            try? v.imageData.write(to: imagesDir.appendingPathComponent(name))
            characters[i].views.append(CharacterView(label: v.label, imageName: name))
        }
        characters[i].updatedAt = Date()
        save()
        SyncService.shared.syncAllIfLoggedIn()
    }

    func removeView(characterId: UUID, viewId: UUID) {
        guard let i = characters.firstIndex(where: { $0.id == characterId }) else { return }
        if let vi = characters[i].views.firstIndex(where: { $0.id == viewId }) {
            let name = characters[i].views[vi].imageName
            try? fileManager.removeItem(at: imagesDir.appendingPathComponent(name))
            characters[i].views.remove(at: vi)
        }
        characters[i].updatedAt = Date()
        save()
        SyncService.shared.syncAllIfLoggedIn()
    }

    func image(named name: String) -> UIImage? {
        let url = imagesDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    // MARK: 持久化

    private func save() {
        do {
            let data = try JSONEncoder().encode(characters)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("⚠️ CharacterStore save error:", error)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Character].self, from: data) else {
            return
        }
        self.characters = decoded
    }
}

// MARK: - ProjectStore

@MainActor
final class ProjectStore: ObservableObject {

    static let shared = ProjectStore()

    @Published private(set) var projects: [MangaProject] = []

    private let fileManager = FileManager.default
    private var documents: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    private var indexURL: URL { documents.appendingPathComponent("projects.json") }

    private init() {
        load()
        // 启动期迁移：把没有工程的旧数据归到"原有作品"工程
        MangaStorage.shared.migrateOrphansIfNeeded(into: ensureDefaultProject())
    }

    // MARK: - 增删改

    @discardableResult
    func create(name: String) -> MangaProject {
        let p = MangaProject(name: name.isEmpty ? "未命名工程" : name)
        projects.insert(p, at: 0)
        save()
        SyncService.shared.syncAllIfLoggedIn()
        return p
    }

    func rename(_ project: MangaProject, to newName: String) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx].name = newName.isEmpty ? "未命名工程" : newName
        projects[idx].updatedAt = Date()
        save()
        SyncService.shared.syncAllIfLoggedIn()
    }

    func delete(_ project: MangaProject) {
        // 删除工程下的所有作品
        let items = MangaStorage.shared.items(in: project.id)
        for it in items { MangaStorage.shared.delete(it) }
        projects.removeAll { $0.id == project.id }
        save()
        SyncService.shared.deleteProject(id: project.id)
    }

    func deleteAll() {
        projects.removeAll()
        save()
    }

    /// 用云端合并后的数据替换本地工程列表（同步专用，不触发再次同步）
    func replaceSynced(_ projects: [MangaProject]) {
        self.projects = projects
        save()
    }

    func touch(_ projectId: UUID, coverItemId: UUID? = nil) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].updatedAt = Date()
        if let cover = coverItemId {
            projects[idx].coverItemId = cover
        }
        save()
        SyncService.shared.syncAllIfLoggedIn()
    }

    // MARK: - 默认工程（用于迁移和"用户没建工程就来到首页"的兜底）

    @discardableResult
    func ensureDefaultProject() -> MangaProject {
        if let existing = projects.first(where: { $0.name == "原有作品" }) {
            return existing
        }
        // 仅当根本没有任何工程时，才需要兜底
        if projects.isEmpty {
            return create(name: "我的第一个漫画")
        }
        // 否则，如果有任何 orphan 数据，建一个"原有作品"
        let hasOrphans = MangaStorage.shared.items(in: MangaItem.orphanProjectId).isEmpty == false
        if hasOrphans {
            let p = MangaProject(name: "原有作品")
            projects.append(p)
            save()
            return p
        }
        return projects[0]
    }

    // MARK: - 持久化

    private func save() {
        do {
            let data = try JSONEncoder().encode(projects)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("⚠️ ProjectStore save error:", error)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([MangaProject].self, from: data) else {
            return
        }
        self.projects = decoded
    }
}

// MARK: - MangaStorage（已升级为按工程过滤）

@MainActor
final class MangaStorage: ObservableObject {

    static let shared = MangaStorage()

    @Published private(set) var allItems: [MangaItem] = []

    private let fileManager = FileManager.default
    private init() { load() }

    private var documents: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    private var indexURL: URL { documents.appendingPathComponent("manga_index.json") }
    private var imagesDir: URL {
        let dir = documents.appendingPathComponent("MangaImages", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - 查询

    /// 当前工程下所有作品（按时间倒序）
    func items(in projectId: UUID) -> [MangaItem] {
        allItems.filter { $0.projectId == projectId }
    }

    func image(named name: String) -> UIImage? {
        let url = imagesDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func imageURL(named name: String) -> URL {
        imagesDir.appendingPathComponent(name)
    }

    // MARK: - 增删改

    @discardableResult
    func add(projectId: UUID,
             style: MangaStyle,
             inputs: [Data],
             outputs: [Data],
             userPrompt: String?,
             storyScript: MangaStoryScript? = nil) -> MangaItem {

        let id = UUID()
        var inputNames: [String] = []
        var outputNames: [String] = []

        for (i, d) in inputs.enumerated() {
            let name = "\(id.uuidString)_in_\(i).png"
            try? d.write(to: imagesDir.appendingPathComponent(name))
            inputNames.append(name)
        }
        for (i, d) in outputs.enumerated() {
            let name = "\(id.uuidString)_out_\(i).png"
            try? d.write(to: imagesDir.appendingPathComponent(name))
            outputNames.append(name)
        }

        let item = MangaItem(id: id,
                             projectId: projectId,
                             createdAt: Date(),
                             updatedAt: Date(),
                             style: style,
                             inputImageNames: inputNames,
                             outputImageNames: outputNames,
                             userPrompt: userPrompt,
                             storyScript: storyScript,
                             isFavorite: false)
        allItems.insert(item, at: 0)
        save()
        // 同时刷新工程的 updatedAt 和封面（首张作品自动作为封面）
        ProjectStore.shared.touch(projectId, coverItemId: item.id)
        SyncService.shared.syncAllIfLoggedIn()
        return item
    }

    func toggleFavorite(_ item: MangaItem) {
        guard let idx = allItems.firstIndex(where: { $0.id == item.id }) else { return }
        allItems[idx].isFavorite.toggle()
        allItems[idx].updatedAt = Date()
        save()
        SyncService.shared.syncAllIfLoggedIn()
    }

    func delete(_ item: MangaItem) {
        guard let idx = allItems.firstIndex(where: { $0.id == item.id }) else { return }
        for n in allItems[idx].inputImageNames + allItems[idx].outputImageNames {
            try? fileManager.removeItem(at: imagesDir.appendingPathComponent(n))
        }
        allItems.remove(at: idx)
        save()
        SyncService.shared.deleteItem(id: item.id)
    }

    func deleteAll() {
        for item in allItems {
            for n in item.inputImageNames + item.outputImageNames {
                try? fileManager.removeItem(at: imagesDir.appendingPathComponent(n))
            }
        }
        allItems.removeAll()
        save()
    }

    /// 用云端合并后的数据替换本地作品列表（同步专用，不触发再次同步）
    func replaceSynced(_ items: [MangaItem]) {
        self.allItems = items
        save()
    }

    // MARK: - 旧数据迁移

    /// 把没有 projectId 的旧记录绑定到指定工程
    func migrateOrphansIfNeeded(into project: MangaProject) {
        var changed = false
        for i in allItems.indices where allItems[i].projectId == MangaItem.orphanProjectId {
            allItems[i].projectId = project.id
            changed = true
        }
        if changed { save() }
    }

    // MARK: - 持久化

    private func save() {
        do {
            let data = try JSONEncoder().encode(allItems)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("⚠️ MangaStorage save error:", error)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([MangaItem].self, from: data) else {
            return
        }
        self.allItems = decoded
    }
}
