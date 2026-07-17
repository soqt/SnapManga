//
//  ContentView.swift
//  LifeManga
//
//  根视图：TabView 三大 Tab —— 工程 / 角色库 / 发布
//

import SwiftUI
import PhotosUI

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        TabView {
            NavigationStack {
                ProjectListView()
            }
            .tabItem { Label("工程", systemImage: "books.vertical.fill") }

            NavigationStack {
                CharacterLibraryView()
            }
            .tabItem { Label("角色库", systemImage: "person.crop.rectangle.stack.fill") }

            NavigationStack {
                PublishView()
            }
            .tabItem { Label("发布", systemImage: "paperplane.fill") }
        }
    }
}

// MARK: ───────────────────────────────────────── 工程 Tab ─────

struct ProjectListView: View {
    @ObservedObject private var store = ProjectStore.shared
    @ObservedObject private var storage = MangaStorage.shared
    @ObservedObject private var jobStore = JobStore.shared

    @State private var showNewSheet = false
    @State private var newName: String = ""
    @State private var renamingProject: MangaProject?
    @State private var renameInput: String = ""
    @State private var showSettings = false
    @State private var showTasks = false

    var body: some View {
        Group {
            if store.projects.isEmpty {
                emptyState
            } else {
                projectList
            }
        }
        .navigationTitle("漫画人生")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 14) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    Button { showTasks = true } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "tray.full")
                            if jobStore.runningCount > 0 {
                                Text("\(jobStore.runningCount)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color.red)
                                    .clipShape(Capsule())
                                    .offset(x: 8, y: -6)
                            }
                        }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { startNewProject() } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
            }
        }
        .alert("新建漫画工程", isPresented: $showNewSheet) {
            TextField("工程名（如：东京游记 / 我的猫的一天）", text: $newName)
            Button("创建") {
                store.create(name: newName.trimmingCharacters(in: .whitespaces))
                newName = ""
            }
            Button("取消", role: .cancel) { newName = "" }
        }
        .alert("重命名工程", isPresented: .init(
            get: { renamingProject != nil },
            set: { if !$0 { renamingProject = nil } })
        ) {
            TextField("新名称", text: $renameInput)
            Button("保存") {
                if let p = renamingProject {
                    store.rename(p, to: renameInput.trimmingCharacters(in: .whitespaces))
                }
                renamingProject = nil
            }
            Button("取消", role: .cancel) { renamingProject = nil }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showTasks) { TaskManagerView() }
        .navigationDestination(for: MangaProject.self) { project in
            ProjectShellView(project: project)
        }
    }

    private func startNewProject() {
        newName = ""
        showNewSheet = true
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical")
                .font(.system(size: 64))
                .foregroundStyle(.indigo.opacity(0.6))
            Text("还没有漫画工程")
                .font(.title3.weight(.semibold))
            Text("一个「工程」就是一本你的漫画。\n你可以在里面持续创作多张漫画页，并保持画风一致。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                startNewProject()
            } label: {
                Label("新建一个工程", systemImage: "plus.circle.fill")
                    .padding(.horizontal, 14).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var projectList: some View {
        List {
            ForEach(store.projects) { project in
                NavigationLink(value: project) {
                    ProjectRow(project: project)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.delete(project)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    Button {
                        renamingProject = project
                        renameInput = project.name
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    .tint(.indigo)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct ProjectRow: View {
    let project: MangaProject
    @ObservedObject private var storage = MangaStorage.shared

    private var itemCount: Int { storage.items(in: project.id).count }

    private var coverImage: UIImage? {
        let items = storage.items(in: project.id)
        let target = items.first { $0.id == project.coverItemId } ?? items.first
        guard let name = target?.outputImageNames.first else { return nil }
        return storage.image(named: name)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                if let img = coverImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "book.closed.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.headline)
                HStack(spacing: 8) {
                    Text("\(itemCount) 张")
                    Text("·")
                    Text(project.updatedAt.formatted(date: .abbreviated, time: .omitted))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: ─── 工程内壳：用 SegmentedPicker 替代嵌套 TabView ───

struct ProjectShellView: View {
    let project: MangaProject

    enum Section: String, CaseIterable, Identifiable {
        case create = "创作", history = "历史"
        var id: String { rawValue }
    }

    @State private var section: Section = .create

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)

            switch section {
            case .create:
                HomeView(project: project)
            case .history:
                HistoryView(project: project)
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: ──────────────────────────────────────── 任务管理 ─────

struct TaskManagerView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var jobStore = JobStore.shared
    @ObservedObject private var storage = MangaStorage.shared
    @ObservedObject private var characterStore = CharacterStore.shared
    @State private var detailItem: MangaItem?
    @State private var detailCharacter: Character?
    @State private var logViewJob: Job?
    @State private var showingError: String?
    /// 用户对 timeoutUnknown 任务点了「重新生成」时，先弹确认框防止重复扣费
    @State private var pendingRetryConfirm: Job?

    var body: some View {
        NavigationStack {
            Group {
                if jobStore.jobs.isEmpty {
                    ContentUnavailableView(
                        "还没有任何任务",
                        systemImage: "tray",
                        description: Text("生成漫画时会自动加入这里。\n你可以锁屏或切到别的 App，完成后会推送通知。")
                    )
                } else {
                    List {
                        ForEach(jobStore.jobs) { job in
                            JobRow(job: job)
                                .contentShape(Rectangle())
                                .onTapGesture { handleTap(job) }
                                .swipeActions(edge: .leading) {
                                    if job.canRetry {
                                        Button {
                                            // timeoutUnknown 状态先弹确认（避免重复扣费），失败状态直接走
                                            if job.phase.isTimeoutUnknown {
                                                pendingRetryConfirm = job
                                            } else {
                                                retryJob(job)
                                            }
                                        } label: {
                                            Label("重新生成", systemImage: "arrow.clockwise")
                                        }
                                        .tint(.green)
                                    }
                                    Button {
                                        logViewJob = job
                                    } label: {
                                        Label("日志", systemImage: "doc.text")
                                    }
                                    .tint(.indigo)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if job.phase.isRunning {
                                        // 第一个 = 最靠边 = 全划触发：终止（更安全，保留记录）
                                        Button {
                                            jobStore.cancel(job.id)
                                        } label: {
                                            Label("终止任务", systemImage: "stop.circle.fill")
                                        }
                                        .tint(.orange)
                                        // 第二个 = 内侧：删除（先终止再从列表移除）
                                        Button(role: .destructive) {
                                            jobStore.cancel(job.id)
                                            jobStore.remove(job)
                                        } label: {
                                            Label("删除任务", systemImage: "trash")
                                        }
                                    } else {
                                        Button(role: .destructive) {
                                            jobStore.remove(job)
                                        } label: {
                                            Label("删除任务", systemImage: "trash")
                                        }
                                    }
                                }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if jobStore.jobs.contains(where: { !$0.phase.isRunning }) {
                        Menu {
                            Button(role: .destructive) {
                                jobStore.clearFinished()
                            } label: {
                                Label("清除已完成 / 失败", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .sheet(item: $detailItem) { item in
                NavigationStack { MangaDetailView(item: item) }
            }
            .sheet(item: $detailCharacter) { c in
                NavigationStack { CharacterDetailView(character: c) }
            }
            .sheet(item: $logViewJob) { job in
                JobLogView(job: job)
            }
            .alert("失败原因", isPresented: .init(
                get: { showingError != nil },
                set: { if !$0 { showingError = nil } })
            ) {
                Button("好") { showingError = nil }
            } message: {
                Text(showingError ?? "")
            }
            .alert("确认重新生成？",
                   isPresented: .init(
                    get: { pendingRetryConfirm != nil },
                    set: { if !$0 { pendingRetryConfirm = nil } })
            ) {
                Button("取消", role: .cancel) { pendingRetryConfirm = nil }
                Button("重新生成", role: .destructive) {
                    if let j = pendingRetryConfirm { retryJob(j) }
                    pendingRetryConfirm = nil
                }
            } message: {
                Text("这个任务客户端没收到结果，OpenAI 端可能仍在生成或已经成功。" +
                     "现在「重新生成」会创建一个新的 OpenAI 任务，**可能再次扣费**。" +
                     "建议先去 OpenAI dashboard / 看任务列表看看上一个会不会陆续完成，再决定。")
            }
        }
    }

    private func handleTap(_ job: Job) {
        switch job.phase {
        case .running, .failed, .timeoutUnknown:
            // 跑中 / 失败 / 超时未知 → 打开日志查看实时进度 / 错误链
            logViewJob = job
        case .done(let resultId):
            if job.kind == .characterViews {
                if let c = characterStore.characters.first(where: { $0.id == resultId }) {
                    detailCharacter = c
                }
            } else {
                if let item = storage.allItems.first(where: { $0.id == resultId }) {
                    detailItem = item
                }
            }
        }
    }

    /// 重新生成失败的任务（角色设定稿 / 普通漫画）
    private func retryJob(_ job: Job) {
        guard job.canRetry else {
            showingError = "这个任务不支持自动重试"
            return
        }
        switch job.kind {
        case .characterViews:
            retryCharacterJob(job)
        case .simpleImage:
            retryMangaJob(job)
        default:
            showingError = "暂不支持重试这种任务（目前仅支持「角色设定稿」与「普通漫画」）"
        }
    }

    private func retryCharacterJob(_ job: Job) {
        guard let artStyle = job.artStyle,
              let cId = job.characterId,
              let c = characterStore.characters.first(where: { $0.id == cId }),
              let n = c.sourcePhotoName,
              let img = characterStore.image(named: n) else {
            showingError = "无法自动重试这个任务（缺少原始照片或参数）"
            return
        }

        let imgSize = "1024x1536"
        let imgQuality = "medium"
        let cName = c.name
        let bio = c.bio

        // 标签：算上之前已成功的同风格设定稿数量
        let existingSameStyle = c.views.filter { $0.label.hasPrefix(artStyle.displayName) }.count
        let label: String = existingSameStyle == 0
            ? artStyle.displayName
            : "\(artStyle.displayName) \(existingSameStyle + 1)"

        let newJobId = JobStore.shared.startJob(
            style: settings.defaultStyle,
            kind: .characterViews,
            stageMessage: "已加入后台队列…（重试）",
            subtitle: "\(artStyle.displayName)·\(cName)",
            characterId: cId,
            characterName: cName,
            artStyle: artStyle,
            manualRetryCount: job.manualRetryCount + 1
        )

        let task = Task {
            do {
                JobStore.shared.updateStage(newJobId, "正在重新生成「\(artStyle.displayName)」设定稿…")
                let result = try await GenerationService.shared.generateCharacter(
                    mode: .sheet,
                    sourceImage: img,
                    name: cName,
                    bio: bio,
                    artStyle: artStyle,
                    size: imgSize,
                    quality: imgQuality
                )
                guard let urlString = result.urls.first,
                      let url = URL(string: urlString) else {
                    throw GenerationError.invalidResponse
                }
                let (data, _) = try await URLSession.shared.data(from: url)

                if Task.isCancelled { return }
                CharacterStore.shared.addViews(to: cId, views: [(label, data)])
                JobStore.shared.complete(newJobId, with: cId)
                LocalNotifier.notifyDone(
                    title: "「\(artStyle.displayName)」设定稿完成",
                    body: cName
                )
            } catch GenerationError.insufficientCredits(let required) {
                JobStore.shared.fail(newJobId,
                    message: "credits 不足，本次需要 \(required) 个 credits。请前往设置购买。",
                    errorCode: "INSUFFICIENT_CREDITS")
            } catch {
                await resolveJobError(error, jobId: newJobId, label: artStyle.displayName)
            }
        }
        JobStore.shared.attachTask(task, to: newJobId)
    }

    /// 重新生成失败的"普通漫画"任务
    private func retryMangaJob(_ job: Job) {
        // 1. 还原输入图
        guard let files = job.inputImageFiles, !files.isEmpty else {
            showingError = "没找到输入图（任务被清理过），无法重试"
            return
        }
        let inputImages: [UIImage] = files.compactMap {
            JobStore.shared.loadPendingImage($0, jobId: job.id)
        }
        guard !inputImages.isEmpty else {
            showingError = "输入图已经丢失，无法重试"
            return
        }
        let prevImage: UIImage? = job.previousPageFile.flatMap {
            JobStore.shared.loadPendingImage($0, jobId: job.id)
        }
        // 2. 还原角色参考图
        let charImages: [UIImage] = (job.characterIds ?? []).compactMap { cid in
            guard let c = characterStore.characters.first(where: { $0.id == cid }) else {
                return nil
            }
            let v = c.views.first(where: { $0.label == "正面" }) ?? c.views.first
            if let n = v?.imageName, let ui = characterStore.image(named: n) {
                return ui
            }
            if let n = c.sourcePhotoName, let ui = characterStore.image(named: n) {
                return ui
            }
            return nil
        }
        let charDirective: String? = {
            let names = (job.characterIds ?? [])
                .compactMap { cid in characterStore.characters.first(where: { $0.id == cid })?.name }
            guard !names.isEmpty else { return nil }
            return """
            CHARACTER REFERENCE:
            I have attached \(names.count) character reference image(s) at the end of \
            the input set. These represent the recurring characters that should appear in this \
            page (\(names.joined(separator: "、"))). Match their faces, hair, outfits and overall \
            design EXACTLY as shown. Do not redesign them.
            """
        }()

        let isColor = job.wasColorOn ?? false
        let bubbleMode = job.bubbleMode ?? "chinese"
        let n = job.imageCount ?? 1
        let imgSize = job.imageSizeStr ?? "1024x1536"
        let imgQuality = job.imageQualityStr ?? "medium"
        let userPrompt = job.userPromptText
        let style = job.style
        let projectId = job.projectId
        let projectName = job.projectName

        let req = OpenAIImageRequest(
            inputImages: inputImages,
            previousPageImage: prevImage,
            characterReferenceImages: charImages,
            characterDirective: charDirective,
            stylePrompt: style.effectivePrompt(isColor: isColor),
            userPrompt: userPrompt,
            n: n,
            size: imgSize,
            quality: imgQuality,
            bubbleTextMode: bubbleMode
        )

        // 3. 起一个新的 jobId（保留旧的失败记录，方便用户对比）
        let newJobId = UUID()
        let pending = JobStore.shared.savePendingInputs(
            jobId: newJobId,
            inputs: inputImages,
            previousPage: prevImage
        )
        JobStore.shared.startJob(
            id: newJobId,
            projectId: projectId,
            projectName: projectName,
            style: style,
            kind: .simpleImage,
            stageMessage: "已加入后台队列…（重试）",
            inputImageFiles: pending.inputs,
            previousPageFile: pending.previous,
            characterIds: job.characterIds,
            userPromptText: userPrompt,
            bubbleMode: bubbleMode,
            wasColorOn: isColor,
            imageCount: n,
            imageSizeStr: imgSize,
            imageQualityStr: imgQuality,
            requestHash: req.fingerprint,
            manualRetryCount: job.manualRetryCount + 1
        )

        let task = Task {
            do {
                JobStore.shared.updateStage(newJobId, "正在重新生成漫画…")
                let result = try await GenerationService.shared.generateImage(
                    inputImages: inputImages,
                    previousPageImage: prevImage,
                    characterReferenceImages: charImages,
                    characterDirective: charDirective,
                    stylePrompt: style.effectivePrompt(isColor: isColor),
                    userPrompt: userPrompt,
                    n: n,
                    size: imgSize,
                    quality: imgQuality,
                    bubbleTextMode: bubbleMode
                )
                let datas = try await withThrowingTaskGroup(of: Data.self) { group in
                    for urlString in result.urls {
                        group.addTask {
                            guard let url = URL(string: urlString) else {
                                throw URLError(.badURL)
                            }
                            let (data, _) = try await URLSession.shared.data(from: url)
                            return data
                        }
                    }
                    var results: [Data] = []
                    for try await data in group { results.append(data) }
                    return results
                }

                if Task.isCancelled { return }
                let inputDatas = inputImages.compactMap { $0.pngData() }
                let pid = projectId ?? ProjectStore.shared.ensureDefaultProject().id
                let savedItem = MangaStorage.shared.add(
                    projectId: pid,
                    style: style,
                    inputs: inputDatas,
                    outputs: datas,
                    userPrompt: userPrompt,
                    storyScript: nil
                )
                JobStore.shared.complete(newJobId, with: savedItem.id)
                LocalNotifier.notifyDone(
                    title: "漫画生成完成",
                    body: "\(projectName)：\(style.displayName) · 共 \(savedItem.outputImageNames.count) 张"
                )
            } catch GenerationError.insufficientCredits(let required) {
                JobStore.shared.fail(newJobId,
                    message: "credits 不足，本次需要 \(required) 个 credits。请前往设置购买。",
                    errorCode: "INSUFFICIENT_CREDITS")
            } catch {
                await resolveJobError(error, jobId: newJobId)
            }
        }
        JobStore.shared.attachTask(task, to: newJobId)
    }
}

// MARK: - 任务日志视图

struct JobLogView: View {
    let job: Job

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var jobStore = JobStore.shared

    private var entries: [JobLogEntry] {
        jobStore.logs[job.id] ?? []
    }

    private var liveJob: Job {
        jobStore.jobs.first { $0.id == job.id } ?? job
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if entries.isEmpty {
                            Text("尚未产生日志")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding()
                        } else {
                            ForEach(entries) { e in
                                LogRow(entry: e)
                                    .id(e.id)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }
                .background(Color(.systemBackground))
                .onChange(of: entries.count) { _, _ in
                    if let last = entries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onAppear {
                    if let last = entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("任务日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    statusBadge
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .safeAreaInset(edge: .top) {
                headerCard
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        let p = liveJob.phase
        Text({
            if p.isRunning         { return "运行中" }
            if p.isDone            { return "已完成" }
            if p.isTimeoutUnknown  { return "结果未知" }
            return "失败"
        }())
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background({
                if p.isRunning         { return Color.indigo.opacity(0.15) }
                if p.isDone            { return Color.green.opacity(0.15) }
                if p.isTimeoutUnknown  { return Color.orange.opacity(0.15) }
                return Color.red.opacity(0.15)
            }())
            .foregroundStyle({ () -> Color in
                if p.isRunning         { return .indigo }
                if p.isDone            { return .green }
                if p.isTimeoutUnknown  { return .orange }
                return .red
            }())
            .clipShape(Capsule())
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(liveJob.displayName).font(.headline)
            if let sub = liveJob.subtitle, !sub.isEmpty {
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(liveJob.stageMessage).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if liveJob.phase.isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(elapsed(ctx.date))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func elapsed(_ now: Date) -> String {
        let secs = Int(now.timeIntervalSince(liveJob.createdAt))
        let m = secs / 60, s = secs % 60
        return m == 0 ? "\(s) 秒" : "\(m) 分 \(s) 秒"
    }
}

private struct LogRow: View {
    let entry: JobLogEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(size: 11).monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)

            Image(systemName: entry.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(swiftUIColor)
                .frame(width: 14, alignment: .center)
                .padding(.top, 2)

            Text(entry.message)
                .font(.system(size: 12).monospaced())
                .foregroundStyle(entry.level == .detail ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }

    private var swiftUIColor: Color {
        switch entry.color {
        case "green":  return .green
        case "orange": return .orange
        case "red":    return .red
        case "gray":   return .gray
        default:       return .blue
        }
    }
}

private struct JobRow: View {
    let job: Job
    @ObservedObject private var storage = MangaStorage.shared
    @ObservedObject private var characterStore = CharacterStore.shared

    var body: some View {
        HStack(spacing: 12) {
            iconBox
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if job.kind == .characterViews {
                        Image(systemName: "person.crop.rectangle.fill")
                            .font(.caption)
                            .foregroundStyle(.indigo)
                    } else {
                        StylePreviewIcon(style: job.style, size: 18)
                    }
                    Text(job.displayName).font(.subheadline.weight(.medium)).lineLimit(1)
                }
                if let sub = job.subtitle, !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(stateText).font(.caption2).foregroundStyle(stateColor).lineLimit(2)
                // 运行中实时显示已运行时长
                if job.phase.isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("已运行 \(elapsedString(ctx.date))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(timestamp).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 4)
    }

    private func elapsedString(_ now: Date) -> String {
        let secs = Int(now.timeIntervalSince(job.createdAt))
        let m = secs / 60
        let s = secs % 60
        if m == 0 { return "\(s) 秒" }
        return "\(m) 分 \(s) 秒"
    }

    @ViewBuilder
    private var iconBox: some View {
        switch job.phase {
        case .running:
            ZStack {
                Circle().fill(Color.indigo.opacity(0.15)).frame(width: 44, height: 44)
                ProgressView().controlSize(.small)
            }
        case .done(let resultId):
            ZStack {
                if job.kind == .characterViews {
                    if let c = characterStore.characters.first(where: { $0.id == resultId }),
                       let v = c.views.first(where: { $0.label == "正面" }) ?? c.views.first,
                       let img = characterStore.image(named: v.imageName) {
                        Image(uiImage: img)
                            .resizable().scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Circle().fill(Color.green.opacity(0.2)).frame(width: 44, height: 44)
                        Image(systemName: "person.fill").foregroundStyle(.green)
                    }
                } else if let item = storage.allItems.first(where: { $0.id == resultId }),
                          let name = item.outputImageNames.first,
                          let img = storage.image(named: name) {
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Circle().fill(Color.green.opacity(0.2)).frame(width: 44, height: 44)
                    Image(systemName: "checkmark").foregroundStyle(.green)
                }
            }
        case .failed:
            ZStack {
                Circle().fill(Color.red.opacity(0.15)).frame(width: 44, height: 44)
                Image(systemName: "xmark").foregroundStyle(.red)
            }
        case .timeoutUnknown:
            ZStack {
                Circle().fill(Color.orange.opacity(0.15)).frame(width: 44, height: 44)
                Image(systemName: "questionmark").foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch job.phase {
        case .running:        Image(systemName: "ellipsis").foregroundStyle(.tertiary)
        case .done:           Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        case .failed:         Image(systemName: "info.circle").foregroundStyle(.red)
        case .timeoutUnknown: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
        }
    }

    private var stateText: String {
        switch job.phase {
        case .running:                return job.stageMessage
        case .done:                   return "已完成 · 点击查看"
        case .failed(let m):          return m
        case .timeoutUnknown(let m):  return m
        }
    }

    private var stateColor: Color {
        switch job.phase {
        case .running:        return .indigo
        case .done:           return .green
        case .failed:         return .red
        case .timeoutUnknown: return .orange
        }
    }

    private var timestamp: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: job.createdAt)
    }
}

// MARK: ───────────────────────────────────────── 角色库 Tab ─────

struct CharacterLibraryView: View {
    @ObservedObject private var store = CharacterStore.shared
    @State private var showCreate = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        Group {
            if store.characters.isEmpty {
                empty
            } else {
                grid
            }
        }
        .navigationTitle("角色库")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: {
                    Image(systemName: "plus.circle.fill").font(.title3)
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            CharacterCreateView()
        }
        .navigationDestination(for: Character.self) { c in
            CharacterDetailView(character: c)
        }
    }

    private var empty: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.rectangle.stack")
                .font(.system(size: 56))
                .foregroundStyle(.indigo.opacity(0.6))
            Text("还没有角色").font(.title3.weight(.semibold))
            Text("用一张真人照片，让 AI 生成一张完整的角色设定稿（含主体姿势、表情研究、服装/配饰/物品全套），\n之后可以载入到任意工程里画进剧情。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button { showCreate = true } label: {
                Label("创建角色", systemImage: "plus.circle.fill")
                    .padding(.horizontal, 14).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(store.characters) { c in
                    NavigationLink(value: c) {
                        CharacterCardView(character: c)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
}

private struct CharacterCardView: View {
    let character: Character
    @ObservedObject private var store = CharacterStore.shared

    private var coverImage: UIImage? {
        if let v = character.views.first {
            return store.image(named: v.imageName)
        }
        if let n = character.sourcePhotoName {
            return store.image(named: n)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray5))
                if let img = coverImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(character.name).font(.subheadline.weight(.medium)).lineLimit(1)
            Text("\(character.views.count) 张立绘")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// 角色详情：网格展示该角色所有立绘
struct CharacterDetailView: View {
    let character: Character
    @ObservedObject private var store = CharacterStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showAddViews = false
    @State private var showPosePicker = false
    @State private var zoomingView: CharacterView?
    @State private var showRename = false
    @State private var renameInput = ""

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    /// 每次获取最新版本的角色（store 更新后跟进）
    private var current: Character {
        store.characters.first { $0.id == character.id } ?? character
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let bio = current.bio, !bio.isEmpty {
                    Text(bio).font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                // 操作按钮
                HStack(spacing: 10) {
                    Button {
                        showPosePicker = true
                    } label: {
                        Label("生成更多动作", systemImage: "figure.run")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        showAddViews = true
                    } label: {
                        Label("再生成一张设定稿", systemImage: "photo.badge.plus")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)

                if current.views.isEmpty {
                    Text("还没有立绘。设定稿生成中？去任务面板看看进度。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(current.views) { v in
                            Button {
                                zoomingView = v
                            } label: {
                                VStack(spacing: 6) {
                                    if let img = store.image(named: v.imageName) {
                                        Image(uiImage: img)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(maxHeight: 220)
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                    Text(v.label).font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.removeView(characterId: current.id, viewId: v.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameInput = current.name
                        showRename = true
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        store.delete(current)
                        dismiss()
                    } label: {
                        Label("删除角色", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("重命名角色", isPresented: $showRename) {
            TextField("名字", text: $renameInput)
            Button("保存") {
                let trimmed = renameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    store.rename(current, name: trimmed)
                }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showAddViews) {
            CharacterCreateView(existingCharacterId: current.id)
        }
        .sheet(isPresented: $showPosePicker) {
            PosePickerSheet(character: current)
        }
        .fullScreenCover(item: $zoomingView) { v in
            ZoomableImageView(
                image: store.image(named: v.imageName) ?? UIImage(),
                title: v.label
            )
        }
    }
}

// MARK: - 全屏可缩放图片查看器

struct ZoomableImageView: View {
    let image: UIImage
    let title: String?
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = max(1, min(lastScale * value, 6))
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale <= 1 {
                                    withAnimation(.spring()) {
                                        offset = .zero
                                        lastOffset = .zero
                                    }
                                }
                            },
                        DragGesture()
                            .onChanged { v in
                                guard scale > 1 else { return }
                                offset = CGSize(
                                    width:  lastOffset.width  + v.translation.width,
                                    height: lastOffset.height + v.translation.height
                                )
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring()) {
                        if scale > 1 {
                            scale = 1; lastScale = 1
                            offset = .zero; lastOffset = .zero
                        } else {
                            scale = 2.5; lastScale = 2.5
                        }
                    }
                }

            VStack {
                HStack {
                    if let t = title {
                        Text(t)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.black.opacity(0.4), in: Capsule())
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white, .black.opacity(0.5))
                    }
                }
                .padding()
                Spacer()
                Button {
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                } label: {
                    Label("保存到相册", systemImage: "square.and.arrow.down")
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.bottom, 30)
            }
        }
    }
}

// MARK: - 动作选择器（多选 + 批量后台生成）

struct PosePickerSheet: View {
    let character: Character
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settings: AppSettings
    @State private var selected: Set<String> = []  // 用 label 作为 key

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    private var allPoses: [(group: String, pose: OpenAIService.CharacterViewSpec)] {
        OpenAIService.extendedPoseGroups.flatMap { g in
            g.poses.map { (g.title, $0) }
        }
    }

    private var pickedSpecs: [OpenAIService.CharacterViewSpec] {
        allPoses.filter { selected.contains($0.pose.label) }.map { $0.pose }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("勾选要生成的动作 / 镜头，所有勾选的会被合成到一张图里。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    ForEach(OpenAIService.extendedPoseGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title).font(.subheadline.bold())
                                .padding(.horizontal)
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(group.poses, id: \.label) { p in
                                    PoseChip(label: p.label,
                                             selected: selected.contains(p.label)) {
                                        if selected.contains(p.label) {
                                            selected.remove(p.label)
                                        } else {
                                            selected.insert(p.label)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("生成更多动作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        submit()
                    } label: {
                        Text(selected.isEmpty ? "生成" : "合成 \(selected.count) 个")
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !selected.isEmpty {
                    HStack {
                        Image(systemName: "moon.zzz.fill")
                        Text("会立刻关闭，AI 在后台把 \(selected.count) 个动作合成到一张图（约 1~3 分钟）")
                            .font(.caption)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.indigo.opacity(0.15))
                }
            }
        }
    }

    private func submit() {
        let specs = pickedSpecs
        guard !specs.isEmpty else { return }

        let sourceImage: UIImage? = {
            if let n = character.sourcePhotoName,
               let img = CharacterStore.shared.image(named: n) { return img }
            if let v = character.views.first,
               let img = CharacterStore.shared.image(named: v.imageName) { return img }
            return nil
        }()
        guard let src = sourceImage else { return }

        let style = settings.defaultStyle
        let isColor = settings.isColor
        let cId = character.id
        let cName = character.name

        // 标签 - 第几张动作合集
        let existingCount = CharacterStore.shared.characters
            .first { $0.id == cId }?
            .views.filter { $0.label.hasPrefix("动作合集") }.count ?? 0
        let label: String = existingCount == 0
            ? "动作合集"
            : "动作合集 \(existingCount + 1)"

        let jobId = JobStore.shared.startJob(
            style: style,
            kind: .characterViews,
            stageMessage: "已加入后台队列…",
            subtitle: "\(specs.count) 个动作合集 · \(cName)",
            characterId: cId,
            characterName: cName
        )

        dismiss()

        let task = Task {
            do {
                JobStore.shared.updateStage(jobId, "正在生成动作合集…")
                let result = try await GenerationService.shared.generateCharacter(
                    mode: .poseSheet,
                    sourceImage: src,
                    name: cName,
                    bio: character.bio,
                    style: style,
                    poses: specs,
                    size: "1024x1536",
                    quality: "medium",
                    isColor: isColor
                )
                guard let urlString = result.urls.first,
                      let url = URL(string: urlString) else {
                    throw GenerationError.invalidResponse
                }
                let (data, _) = try await URLSession.shared.data(from: url)

                if Task.isCancelled { return }
                CharacterStore.shared.addViews(
                    to: cId,
                    views: [(label, data)]
                )
                JobStore.shared.complete(jobId, with: cId)
                LocalNotifier.notifyDone(
                    title: "动作合集完成",
                    body: "\(cName) · \(specs.count) 个动作"
                )
            } catch GenerationError.insufficientCredits(let required) {
                JobStore.shared.fail(jobId,
                    message: "credits 不足，本次需要 \(required) 个 credits。请前往设置购买。",
                    errorCode: "INSUFFICIENT_CREDITS")
            } catch {
                await resolveJobError(error, jobId: jobId, label: "动作合集")
            }
        }
        JobStore.shared.attachTask(task, to: jobId)
    }
}

private struct PoseChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(selected ? Color.accentColor.opacity(0.18) : Color(.systemGray6))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(selected ? Color.accentColor : Color.gray.opacity(0.2),
                                lineWidth: selected ? 2 : 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(selected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
}

// 创建 / 增加视图
struct CharacterCreateView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CharacterStore.shared

    /// 若非 nil，则是为已有角色追加视图（不会再创建新角色）
    var existingCharacterId: UUID?

    @State private var name = ""
    @State private var bio = ""
    @State private var photo: UIImage?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var selectedStyles: Set<CharacterArtStyle> = [.jpAnime]
    @State private var didAutoloadPhoto = false

    private var isAppending: Bool { existingCharacterId != nil }
    private let styleColumns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    private var existingCharacter: Character? {
        guard let id = existingCharacterId else { return nil }
        return store.characters.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isAppending {
                    Section("角色信息") {
                        TextField("名字（如：小明）", text: $name)
                        TextField("一句话设定（性格/身份）", text: $bio, axis: .vertical)
                            .lineLimit(2...4)
                    }
                }
                Section {
                    if let img = photo {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    if !isAppending {
                        // 新建角色：必须选照片
                        PhotosPicker(selection: $pickerItems,
                                     maxSelectionCount: 1,
                                     matching: .images) {
                            Label(photo == nil ? "选一张照片" : "更换照片",
                                  systemImage: "photo.on.rectangle")
                        }
                    } else {
                        // 已有角色追加：默认用原图
                        Text("正在使用这个角色最初的参考照（保持画面一致）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        PhotosPicker(selection: $pickerItems,
                                     maxSelectionCount: 1,
                                     matching: .images) {
                            Label("换张参考照", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption)
                        }
                    }
                } header: {
                    Text(isAppending ? "参考照片（用原照片）" : "参考照片（必选）")
                } footer: {
                    if !isAppending {
                        Text("📸 照片小贴士：\n• 必须是成年人 —— OpenAI 禁止用真人小孩照片\n• 半身或全身效果 > 大头自拍（V 字脸自拍角度容易被误判为儿童）\n• 正常表情 > 卖萌 / 鬼脸\n• 光线清楚、面部正面或 3/4 角度最好")
                            .font(.caption2)
                    }
                }
                Section("艺术风格（可多选，每选一个会单独生成一张设定稿）") {
                    LazyVGrid(columns: styleColumns, spacing: 8) {
                        ForEach(CharacterArtStyle.allCases) { s in
                            ArtStyleChip(
                                style: s,
                                selected: selectedStyles.contains(s)
                            ) {
                                if selectedStyles.contains(s) {
                                    selectedStyles.remove(s)
                                } else {
                                    selectedStyles.insert(s)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
                Section {
                    Label("点击「生成」立刻关闭窗口，AI 在后台并行生成 \(selectedStyles.count) 张设定稿（每张约 2~3 分钟，含主体/表情/服装/配饰/双语标注）。完成后会推送通知。",
                          systemImage: "moon.zzz.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(isAppending ? "追加视图" : "新建角色")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: pickerItems) { _, items in
                Task {
                    if let item = items.first,
                       let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        photo = img
                    }
                    pickerItems = []
                }
            }
            .onAppear {
                // isAppending 时自动加载该角色的原照片
                if !didAutoloadPhoto, isAppending, photo == nil,
                   let n = existingCharacter?.sourcePhotoName,
                   let img = CharacterStore.shared.image(named: n) {
                    photo = img
                    didAutoloadPhoto = true
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selectedStyles.count > 1 ? "生成 \(selectedStyles.count) 张" : "生成") {
                        submit()
                    }
                    .disabled(photo == nil || selectedStyles.isEmpty ||
                              (!isAppending && name.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
    }

    /// 把生成任务提交到后台，立即关闭弹窗。
    /// 多风格 → 串行执行（避免并发把自己堵死，也避免 OpenAI 把自己 key 限速）
    private func submit() {
        guard let img = photo else { return }
        guard !selectedStyles.isEmpty else { return }

        // 1. 先建好（或拿到）Character
        let characterId: UUID
        let characterName: String
        if let existing = existingCharacterId,
           let c = store.characters.first(where: { $0.id == existing }) {
            characterId = c.id
            characterName = c.name
        } else {
            let c = store.create(name: name,
                                 bio: bio.isEmpty ? nil : bio,
                                 sourcePhoto: img.pngData())
            characterId = c.id
            characterName = c.name
        }

        // 1024x1536 是 OpenAI 的"主路径"，单张反而比 1024x1024 便宜（$0.041 vs $0.053）
        // 推测处理也更快（更优化）。回到这个尺寸让 OpenAI 走它最熟悉的渲染管线
        let imgSize = "1024x1536"
        let imgQuality = "medium"
        let bioText = bio.isEmpty ? nil : bio
        let styles = Array(selectedStyles).sorted { $0.displayName < $1.displayName }

        // 2. 一次性把所有 Job 加入队列（用户立即能在任务面板看到全部排队）
        var jobInfos: [(jobId: UUID, artStyle: CharacterArtStyle, label: String)] = []
        for (idx, s) in styles.enumerated() {
            let existingSameStyle = store.characters.first { $0.id == characterId }?
                .views.filter { $0.label.hasPrefix(s.displayName) }.count ?? 0
            let label: String = existingSameStyle == 0
                ? s.displayName
                : "\(s.displayName) \(existingSameStyle + 1)"

            let queuePrefix = idx == 0 ? "即将开始…" : "排队中（前面还有 \(idx) 个）…"

            let jobId = JobStore.shared.startJob(
                style: settings.defaultStyle,   // 仅用作 JobRow 兜底图标
                kind: .characterViews,
                stageMessage: queuePrefix,
                subtitle: "\(s.displayName)·\(characterName)",
                characterId: characterId,
                characterName: characterName,
                artStyle: s
            )
            jobInfos.append((jobId, s, label))
        }

        // 3. 立刻关闭弹窗
        dismiss()

        // 4. 用一个外层 Task 串行跑 —— 一次只一个 OpenAI 请求
        let sessionTask = Task {
            for (idx, info) in jobInfos.enumerated() {
                if Task.isCancelled { break }
                // 后续任务把"排队中"提示更新一下
                if idx > 0 {
                    JobStore.shared.updateStage(info.jobId, "前一个完成，准备开始…")
                }
                await runOneSheet(
                    jobId: info.jobId,
                    characterId: characterId,
                    characterName: characterName,
                    bio: bioText,
                    photo: img,
                    artStyle: info.artStyle,
                    label: info.label,
                    size: imgSize,
                    quality: imgQuality
                )
                // 给后续 Job 更新排队序号
                let remaining = jobInfos.count - idx - 1
                if remaining > 0 {
                    for (j, next) in jobInfos.enumerated()
                    where j > idx && JobStore.shared.jobs.first(where: { $0.id == next.jobId })?.phase.isRunning == true {
                        let ahead = j - idx - 1
                        JobStore.shared.updateStage(
                            next.jobId,
                            ahead == 0 ? "即将开始…" : "排队中（前面还有 \(ahead) 个）…"
                        )
                    }
                }
            }
        }

        // 5. 把这个 sessionTask 注册到所有 Job —— 用户取消任意一个 = 取消整批
        for info in jobInfos {
            JobStore.shared.attachTask(sessionTask, to: info.jobId)
        }
    }

    private func runOneSheet(jobId: UUID,
                             characterId: UUID,
                             characterName: String,
                             bio: String?,
                             photo: UIImage,
                             artStyle: CharacterArtStyle,
                             label: String,
                             size: String,
                             quality: String) async {
        do {
            JobStore.shared.updateStage(jobId, "正在生成「\(artStyle.displayName)」设定稿…")
            let result = try await GenerationService.shared.generateCharacter(
                mode: .sheet,
                sourceImage: photo,
                name: characterName,
                bio: bio,
                artStyle: artStyle,
                size: size,
                quality: quality
            )
            guard let urlString = result.urls.first,
                  let url = URL(string: urlString) else {
                throw GenerationError.invalidResponse
            }
            let (data, _) = try await URLSession.shared.data(from: url)

            if Task.isCancelled { return }
            CharacterStore.shared.addViews(
                to: characterId,
                views: [(label, data)]
            )
            JobStore.shared.complete(jobId, with: characterId)
            LocalNotifier.notifyDone(
                title: "「\(artStyle.displayName)」设定稿完成",
                body: characterName
            )
        } catch GenerationError.insufficientCredits(let required) {
            JobStore.shared.fail(jobId,
                message: "credits 不足，本次需要 \(required) 个 credits。请前往设置购买。",
                errorCode: "INSUFFICIENT_CREDITS")
        } catch {
            await resolveJobError(error, jobId: jobId, label: artStyle.displayName)
        }
    }
}

// MARK: - 艺术风格选择卡

private struct ArtStyleChip: View {
    let style: CharacterArtStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(selected ? Color.accentColor.opacity(0.18) : Color(.systemGray6))
                    Image(systemName: style.symbolName)
                        .font(.title3)
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    if selected {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.white, .indigo)
                                    .padding(4)
                            }
                            Spacer()
                        }
                    }
                }
                .frame(height: 50)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(selected ? Color.accentColor : Color.gray.opacity(0.2),
                                lineWidth: selected ? 2 : 1)
                )

                Text(style.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(selected ? Color.accentColor : .primary)
                Text(style.subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: ──────────────────────────────────────── 发布 Tab ─────

struct PublishView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 64))
                .foregroundStyle(.indigo.opacity(0.5))
            Text("发布功能即将推出")
                .font(.title3.weight(.semibold))
            Text("未来可以把工程导出成 PDF 漫画书、生成长图、\n或一键发布到社交平台。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("发布")
    }
}
