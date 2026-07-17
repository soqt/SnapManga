//
//  SyncService.swift
//  LifeManga
//
//  把工程、作品、角色库的元数据同步到 Supabase。
//  图片仍然只存本地，云端只保存文件名与关系。
//

import Foundation
import Supabase

enum SyncError: Error {
    case notAuthenticated
}

@MainActor
final class SyncService {
    static let shared = SyncService()

    private var isSyncing = false

    private init() {}

    /// 在登录状态下执行一次全量双向同步（登录成功时调用）
    func syncAllIfLoggedIn() {
        guard SupabaseClientManager.shared.currentUser != nil else { return }
        Task {
            try? await syncAll()
        }
    }

    /// 删除云端工程（本地删除后调用）
    func deleteProject(id: UUID) {
        Task {
            try? await SupabaseClientManager.shared.client
                .from("projects")
                .delete()
                .eq("id", value: id)
                .execute()
        }
    }

    /// 删除云端作品（本地删除后调用）
    func deleteItem(id: UUID) {
        Task {
            try? await SupabaseClientManager.shared.client
                .from("item_images")
                .delete()
                .eq("item_id", value: id)
                .execute()
            try? await SupabaseClientManager.shared.client
                .from("items")
                .delete()
                .eq("id", value: id)
                .execute()
        }
    }

    /// 删除云端角色（本地删除后调用）
    func deleteCharacter(id: UUID) {
        Task {
            try? await SupabaseClientManager.shared.client
                .from("character_views")
                .delete()
                .eq("character_id", value: id)
                .execute()
            try? await SupabaseClientManager.shared.client
                .from("characters")
                .delete()
                .eq("id", value: id)
                .execute()
        }
    }

    /// 全量双向同步：拉取云端 → 合并 → 写回本地 → 推送本地（合并后）状态到云端
    func syncAll() async throws {
        guard let userId = SupabaseClientManager.shared.currentUser?.id else {
            throw SyncError.notAuthenticated
        }
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        // 1. 拉取云端
        let remoteProjects = try await fetchRemoteProjects()
        let remoteItems = try await fetchRemoteItems()
        let remoteCharacters = try await fetchRemoteCharacters()

        // 2. 合并：以 updated_at 较新的为准
        let mergedProjects = mergeProjects(local: ProjectStore.shared.projects, remote: remoteProjects)
        let mergedItems = mergeItems(local: MangaStorage.shared.allItems, remote: remoteItems)
        let mergedCharacters = mergeCharacters(local: CharacterStore.shared.characters, remote: remoteCharacters)

        // 3. 写回本地（replaceSynced 不会再次触发同步）
        ProjectStore.shared.replaceSynced(mergedProjects)
        MangaStorage.shared.replaceSynced(mergedItems)
        CharacterStore.shared.replaceSynced(mergedCharacters)

        // 4. 推送合并后的状态到云端
        try await pushProjects(mergedProjects, userId: userId)
        try await pushItems(mergedItems, userId: userId)
        try await pushCharacters(mergedCharacters, userId: userId)
    }
}

// MARK: - 远程数据结构

private struct RemoteProject: Decodable {
    let id: UUID
    let name: String
    let notes: String?
    let coverItemId: UUID?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, notes
        case coverItemId = "cover_item_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct RemoteItem: Decodable {
    let id: UUID
    let projectId: UUID
    let style: String
    let userPrompt: String?
    let storyScript: MangaStoryScript?
    let isFavorite: Bool
    let createdAt: Date
    let updatedAt: Date
    let images: [RemoteItemImage]?

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case style
        case userPrompt = "user_prompt"
        case storyScript = "story_script"
        case isFavorite = "is_favorite"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case images = "item_images"
    }
}

private struct RemoteItemImage: Decodable {
    let id: UUID
    let kind: String
    let filename: String
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, kind, filename
        case createdAt = "created_at"
    }
}

private struct RemoteCharacter: Decodable {
    let id: UUID
    let name: String
    let bio: String?
    let sourcePhotoFilename: String?
    let createdAt: Date
    let updatedAt: Date
    let views: [RemoteCharacterView]?

    enum CodingKeys: String, CodingKey {
        case id, name, bio
        case sourcePhotoFilename = "source_photo_filename"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case views = "character_views"
    }
}

private struct RemoteCharacterView: Decodable {
    let id: UUID
    let label: String
    let filename: String
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, label, filename
        case createdAt = "created_at"
    }
}

// MARK: - 拉取

private extension SyncService {
    func fetchRemoteProjects() async throws -> [RemoteProject] {
        try await SupabaseClientManager.shared.client
            .from("projects")
            .select()
            .order("updated_at", ascending: false)
            .execute()
            .value
    }

    func fetchRemoteItems() async throws -> [RemoteItem] {
        try await SupabaseClientManager.shared.client
            .from("items")
            .select("*, item_images(*)")
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func fetchRemoteCharacters() async throws -> [RemoteCharacter] {
        try await SupabaseClientManager.shared.client
            .from("characters")
            .select("*, character_views(*)")
            .order("updated_at", ascending: false)
            .execute()
            .value
    }
}

// MARK: - 合并

private extension SyncService {
    func mergeProjects(local: [MangaProject], remote: [RemoteProject]) -> [MangaProject] {
        var map = [UUID: MangaProject]()
        for p in local { map[p.id] = p }
        for r in remote {
            let remoteProject = MangaProject(
                id: r.id,
                name: r.name,
                createdAt: r.createdAt,
                updatedAt: r.updatedAt,
                coverItemId: r.coverItemId,
                notes: r.notes
            )
            if let local = map[r.id] {
                map[r.id] = r.updatedAt > local.updatedAt ? remoteProject : local
            } else {
                map[r.id] = remoteProject
            }
        }
        return Array(map.values).sorted { $0.updatedAt > $1.updatedAt }
    }

    func mergeItems(local: [MangaItem], remote: [RemoteItem]) -> [MangaItem] {
        var map = [UUID: MangaItem]()
        for i in local { map[i.id] = i }
        for r in remote {
            let inputs = filenames(from: r.images, kind: "input")
            let outputs = filenames(from: r.images, kind: "output")
            let remoteItem = MangaItem(
                id: r.id,
                projectId: r.projectId,
                createdAt: r.createdAt,
                updatedAt: r.updatedAt,
                style: MangaStyle(rawValue: r.style) ?? .shonenJump,
                inputImageNames: inputs,
                outputImageNames: outputs,
                userPrompt: r.userPrompt,
                storyScript: r.storyScript,
                isFavorite: r.isFavorite
            )
            if let local = map[r.id] {
                map[r.id] = r.updatedAt > local.updatedAt ? remoteItem : local
            } else {
                map[r.id] = remoteItem
            }
        }
        return Array(map.values).sorted { $0.createdAt > $1.createdAt }
    }

    func mergeCharacters(local: [Character], remote: [RemoteCharacter]) -> [Character] {
        var map = [UUID: Character]()
        for c in local { map[c.id] = c }
        for r in remote {
            let views = (r.views ?? []).map {
                CharacterView(id: $0.id, label: $0.label, imageName: $0.filename, createdAt: $0.createdAt ?? Date())
            }
            let remoteCharacter = Character(
                id: r.id,
                name: r.name,
                bio: r.bio,
                sourcePhotoName: r.sourcePhotoFilename,
                views: views,
                createdAt: r.createdAt,
                updatedAt: r.updatedAt
            )
            if let local = map[r.id] {
                map[r.id] = r.updatedAt > local.updatedAt ? remoteCharacter : local
            } else {
                map[r.id] = remoteCharacter
            }
        }
        return Array(map.values).sorted { $0.updatedAt > $1.updatedAt }
    }

    func filenames(from images: [RemoteItemImage]?, kind: String) -> [String] {
        guard let images = images else { return [] }
        return images
            .filter { $0.kind == kind }
            .sorted {
                ($0.createdAt ?? Date.distantPast) < ($1.createdAt ?? Date.distantPast)
            }
            .map { $0.filename }
    }
}

// MARK: - 推送

private extension SyncService {
    struct ProjectPayload: Encodable {
        let id: UUID
        let user_id: UUID
        let name: String
        let notes: String?
        let cover_item_id: UUID?
        let created_at: Date
        let updated_at: Date
    }

    func pushProjects(_ projects: [MangaProject], userId: UUID) async throws {
        guard !projects.isEmpty else { return }
        let payloads = projects.map {
            ProjectPayload(
                id: $0.id,
                user_id: userId,
                name: $0.name,
                notes: $0.notes,
                cover_item_id: $0.coverItemId,
                created_at: $0.createdAt,
                updated_at: $0.updatedAt
            )
        }
        try await SupabaseClientManager.shared.client
            .from("projects")
            .upsert(payloads)
            .execute()
    }

    struct ItemPayload: Encodable {
        let id: UUID
        let user_id: UUID
        let project_id: UUID
        let style: String
        let user_prompt: String?
        let story_script: MangaStoryScript?
        let is_favorite: Bool
        let created_at: Date
        let updated_at: Date
    }

    struct ItemImagePayload: Encodable {
        let id: UUID
        let item_id: UUID
        let kind: String
        let filename: String
        let created_at: Date
    }

    func pushItems(_ items: [MangaItem], userId: UUID) async throws {
        guard !items.isEmpty else { return }
        let payloads = items.map {
            ItemPayload(
                id: $0.id,
                user_id: userId,
                project_id: $0.projectId,
                style: $0.style.rawValue,
                user_prompt: $0.userPrompt,
                story_script: $0.storyScript,
                is_favorite: $0.isFavorite,
                created_at: $0.createdAt,
                updated_at: $0.updatedAt
            )
        }
        try await SupabaseClientManager.shared.client
            .from("items")
            .upsert(payloads)
            .execute()

        // 同步 item_images：先删后插，保证本地文件名是最终状态
        let itemIds = items.map { $0.id }
        try await SupabaseClientManager.shared.client
            .from("item_images")
            .delete()
            .in("item_id", values: itemIds)
            .execute()

        var imagePayloads: [ItemImagePayload] = []
        for item in items {
            for name in item.inputImageNames {
                imagePayloads.append(ItemImagePayload(
                    id: UUID(),
                    item_id: item.id,
                    kind: "input",
                    filename: name,
                    created_at: item.createdAt
                ))
            }
            for name in item.outputImageNames {
                imagePayloads.append(ItemImagePayload(
                    id: UUID(),
                    item_id: item.id,
                    kind: "output",
                    filename: name,
                    created_at: item.createdAt
                ))
            }
        }

        if !imagePayloads.isEmpty {
            try await SupabaseClientManager.shared.client
                .from("item_images")
                .insert(imagePayloads)
                .execute()
        }
    }

    struct CharacterPayload: Encodable {
        let id: UUID
        let user_id: UUID
        let name: String
        let bio: String?
        let source_photo_filename: String?
        let created_at: Date
        let updated_at: Date
    }

    struct CharacterViewPayload: Encodable {
        let id: UUID
        let character_id: UUID
        let label: String
        let filename: String
        let created_at: Date
    }

    func pushCharacters(_ characters: [Character], userId: UUID) async throws {
        guard !characters.isEmpty else { return }
        let payloads = characters.map {
            CharacterPayload(
                id: $0.id,
                user_id: userId,
                name: $0.name,
                bio: $0.bio,
                source_photo_filename: $0.sourcePhotoName,
                created_at: $0.createdAt,
                updated_at: $0.updatedAt
            )
        }
        try await SupabaseClientManager.shared.client
            .from("characters")
            .upsert(payloads)
            .execute()

        // 同步角色视图：本地视图 id 稳定，直接 upsert
        let viewPayloads: [CharacterViewPayload] = characters.flatMap { c in
            c.views.map {
                CharacterViewPayload(
                    id: $0.id,
                    character_id: c.id,
                    label: $0.label,
                    filename: $0.imageName,
                    created_at: $0.createdAt
                )
            }
        }
        if !viewPayloads.isEmpty {
            try await SupabaseClientManager.shared.client
                .from("character_views")
                .upsert(viewPayloads)
                .execute()
        }
    }
}
