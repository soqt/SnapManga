//
//  MangaItem.swift
//  LifeManga
//
//  数据模型：MangaProject（工程）+ MangaItem（一次生成结果）+ 剧本结构。
//

import Foundation

// MARK: - 工程

struct MangaProject: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    let createdAt: Date
    var updatedAt: Date
    /// 用作封面的 MangaItem.id（可选）
    var coverItemId: UUID?
    /// 备注 / 故事大纲（可选）
    var notes: String?

    init(id: UUID = UUID(),
         name: String,
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         coverItemId: UUID? = nil,
         notes: String? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.coverItemId = coverItemId
        self.notes = notes
    }
}

// MARK: - 故事模式：剧本结构

struct MangaPanel: Codable, Equatable, Hashable {
    var description: String
    var dialogue: String?
    var dialogueJa: String?
    var narration: String?
    var narrationJa: String?
    var sfx: String?
}

struct MangaStoryScript: Codable, Equatable, Hashable {
    var title: String
    var synopsis: String
    var panels: [MangaPanel]
}

// MARK: - 一次生成的结果

struct MangaItem: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    /// 所属工程（旧数据迁移后会回填此字段）
    var projectId: UUID
    let createdAt: Date
    var updatedAt: Date
    let style: MangaStyle
    let inputImageNames: [String]
    let outputImageNames: [String]
    let userPrompt: String?
    var storyScript: MangaStoryScript?
    var isFavorite: Bool

    init(id: UUID = UUID(),
         projectId: UUID,
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         style: MangaStyle,
         inputImageNames: [String],
         outputImageNames: [String],
         userPrompt: String? = nil,
         storyScript: MangaStoryScript? = nil,
         isFavorite: Bool = false) {
        self.id = id
        self.projectId = projectId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.style = style
        self.inputImageNames = inputImageNames
        self.outputImageNames = outputImageNames
        self.userPrompt = userPrompt
        self.storyScript = storyScript
        self.isFavorite = isFavorite
    }

    // 兼容旧数据：projectId / updatedAt 在旧版本里不存在
    enum CodingKeys: String, CodingKey {
        case id, projectId, createdAt, updatedAt, style, inputImageNames,
             outputImageNames, userPrompt, storyScript, isFavorite
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        // 旧数据兼容：缺 projectId 时用一个 sentinel UUID
        self.projectId = (try? c.decode(UUID.self, forKey: .projectId))
            ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? self.createdAt
        self.style = try c.decode(MangaStyle.self, forKey: .style)
        self.inputImageNames = try c.decode([String].self, forKey: .inputImageNames)
        self.outputImageNames = try c.decode([String].self, forKey: .outputImageNames)
        self.userPrompt = try? c.decode(String.self, forKey: .userPrompt)
        self.storyScript = try? c.decode(MangaStoryScript.self, forKey: .storyScript)
        self.isFavorite = (try? c.decode(Bool.self, forKey: .isFavorite)) ?? false
    }
}

extension MangaItem {
    static let orphanProjectId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

// MARK: - 任务日志（仅内存）

struct JobLogEntry: Identifiable, Equatable {
    let id: UUID = UUID()
    let timestamp: Date
    let level: Level
    let message: String

    enum Level: String {
        case info     // ℹ
        case success  // ✓
        case warning  // ⚠
        case error    // ✗
        case detail   // ·  (低强度细节)
    }

    init(level: Level = .info, message: String) {
        self.timestamp = Date()
        self.level = level
        self.message = message
    }

    var symbolName: String {
        switch level {
        case .info:    return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        case .detail:  return "circle.fill"
        }
    }

    var color: String {
        switch level {
        case .info:    return "blue"
        case .success: return "green"
        case .warning: return "orange"
        case .error:   return "red"
        case .detail:  return "gray"
        }
    }
}

// MARK: - 角色设定稿艺术风格

enum CharacterArtStyle: String, CaseIterable, Codable, Identifiable, Hashable {
    case jpAnime
    case usComics
    case krManhwa
    case kawaii
    case chibi
    case render3D
    case semiReal
    case watercolor
    case pixelArt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jpAnime:    return "日漫风"
        case .usComics:   return "美漫风"
        case .krManhwa:   return "韩漫风"
        case .kawaii:     return "可爱风"
        case .chibi:      return "Q 版"
        case .render3D:   return "3D 渲染"
        case .semiReal:   return "半写实"
        case .watercolor: return "水彩风"
        case .pixelArt:   return "像素风"
        }
    }

    var subtitle: String {
        switch self {
        case .jpAnime:    return "京阿尼 / 新海诚 现代动画风"
        case .usComics:   return "Marvel / DC 美式漫画"
        case .krManhwa:   return "顶级 webtoon · 精致细腻"
        case .kawaii:     return "粉嫩、大眼、软萌"
        case .chibi:      return "2~3 头身 SD 缩小可爱"
        case .render3D:   return "皮克斯 / 平行宇宙 3D 渲染"
        case .semiReal:   return "半写实插画感"
        case .watercolor: return "水彩晕染 + 纸纹"
        case .pixelArt:   return "16-bit JRPG / 复古游戏立绘"
        }
    }

    var symbolName: String {
        switch self {
        case .jpAnime:    return "sparkles"
        case .usComics:   return "bolt.fill"
        case .krManhwa:   return "crown.fill"
        case .kawaii:     return "heart.fill"
        case .chibi:      return "face.smiling.fill"
        case .render3D:   return "cube.fill"
        case .semiReal:   return "person.fill"
        case .watercolor: return "drop.fill"
        case .pixelArt:   return "square.grid.3x3.fill"
        }
    }

    /// 给 gpt-image-2 的英文风格 prompt
    /// 注意：避免提及具体品牌（Marvel/DC）、武打作品（镖人）、儿童相关词汇等可能触发安全系统的词
    var prompt: String {
        switch self {
        case .jpAnime:
            return """
            Modern Japanese anime/manga character illustration style. Clean cel-shaded \
            coloring with crisp confident lineart. Large expressive anime eyes with \
            highlights, stylized hair with shine, vibrant clean color palette. \
            Polished modern TV-anime production aesthetic.
            """
        case .usComics:
            return """
            Modern American graphic-novel character illustration style. Bold confident \
            inking with strong line-weight variation. Realistic body proportions with \
            slightly stylized features. Strong cel-shading with dramatic but tasteful \
            shadows. Polished, painterly, professional comic illustration aesthetic. \
            (No specific franchise; original character design.)
            """
        case .krManhwa:
            return """
            Modern Korean webtoon character illustration style — polished glossy digital \
            illustration with clean painterly cel-shading. Realistic body proportions \
            with softly anime-influenced features, beautifully detailed expressive eyes, \
            sharp confident lineart, vibrant modern color palette, smooth gradient \
            shading on skin and hair. High-production-value webtoon aesthetic with \
            cinematic lighting and dramatic poses. Original character design.
            """
        case .kawaii:
            return """
            Soft kawaii illustration style with a pastel palette (pinks, peaches, \
            lavenders, mint). Large sparkly round eyes, simplified soft features, \
            gentle rounded shapes, dreamy peaceful atmosphere. Cute mascot-friendly \
            aesthetic. (Adult character; cute style only — keep adult facial structure \
            and proportions.)
            """
        case .chibi:
            return """
            Stylized chibi / super-deformed cartoon ART STYLE applied to an ADULT \
            character — playfully exaggerated proportions (about 3-4 heads tall), \
            simplified rounded body, large expressive eyes, simplified hands. \
            IMPORTANT: this is an adult character rendered in chibi STYLE (like an \
            adult mascot or comedic short-form animation spinoff). NOT a depiction of a \
            child, baby, or minor — keep the adult outfit, adult bearing, and any adult \
            props (work bag, glasses, etc) visible. Cute, comedic cartoon aesthetic.
            """
        case .render3D:
            return """
            Modern 3D-animated film character illustration style — soft realistic \
            lighting with subtle sub-surface skin scattering, painterly fabric textures, \
            stylized but rendered look, gentle depth of field. Polished feature-film CG \
            aesthetic. Original character design (no specific franchise).
            """
        case .semiReal:
            return """
            Semi-realistic illustration style halfway between anime and realism. \
            Realistic shading and proportions with softly anime-influenced features. \
            Smooth realistic skin shading, detailed expressive eyes, stylized hair. \
            Polished modern webtoon / character-portrait illustration aesthetic.
            """
        case .watercolor:
            return """
            Traditional watercolor illustration style. Soft loose washes of color, \
            organic blooming edges, visible paper texture, painterly imperfection. \
            Controlled detail in the face with looser strokes elsewhere. Romantic, \
            gentle, hand-painted feel. Studio-Ghibli-inspired concept-art aesthetic.
            """
        case .pixelArt:
            return """
            16-bit JRPG pixel-art character illustration style. Clean visible square \
            pixels, limited vivid retro color palette, color blocking with deliberate \
            dithering for shading. Distinct chunky pixel shapes for hair, eyes, and \
            clothing. SNES / Game Boy Advance era role-playing game character portrait \
            aesthetic. Render every element (character, callouts, expressions, items) \
            in pixel-art form with a clearly visible pixel grid. Do NOT smooth the \
            pixels into a normal illustration.
            """
        }
    }
}

// MARK: - 角色库

/// 一个角度 / 动作下的角色立绘
struct CharacterView: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    /// 视图类型描述（"正面 / 背面 / 侧面 / 战斗姿势" 等）
    var label: String
    /// 本地存储的图片文件名
    var imageName: String
    let createdAt: Date

    init(id: UUID = UUID(),
         label: String,
         imageName: String,
         createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.imageName = imageName
        self.createdAt = createdAt
    }
}

/// 一个角色（含多视图）
struct Character: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var bio: String?         // 性格 / 背景设定
    /// 用户上传的真人参考照片（仅用于生成；不会被打包到漫画里）
    var sourcePhotoName: String?
    /// 多角度立绘集合
    var views: [CharacterView]
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String,
         bio: String? = nil,
         sourcePhotoName: String? = nil,
         views: [CharacterView] = [],
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.bio = bio
        self.sourcePhotoName = sourcePhotoName
        self.views = views
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
