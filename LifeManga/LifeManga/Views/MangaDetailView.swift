//
//  MangaDetailView.swift
//  LifeManga
//
//  详情页：浏览生成的漫画 + 输入图，可收藏 / 分享 / 保存到相册 / 删除
//

import SwiftUI
import UIKit

struct MangaDetailView: View {

    @State var item: MangaItem
    @ObservedObject private var storage = MangaStorage.shared
    @Environment(\.dismiss) private var dismiss

    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var showDeleteAlert = false
    @State private var savedToast = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // 输出图（漫画）
                Text("生成的漫画").font(.headline)
                ForEach(item.outputImageNames, id: \.self) { name in
                    if let img = storage.image(named: name) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .contextMenu {
                                Button {
                                    UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                                    savedToast = true
                                } label: {
                                    Label("保存到相册", systemImage: "square.and.arrow.down")
                                }
                                Button {
                                    shareItems = [img]
                                    showShare = true
                                } label: {
                                    Label("分享", systemImage: "square.and.arrow.up")
                                }
                            }
                    }
                }

                // 剧本（如果有）
                if let script = item.storyScript {
                    Divider()
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(script.synopsis)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            ForEach(Array(script.panels.enumerated()), id: \.offset) { idx, p in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("第 \(idx + 1) 格").font(.caption).bold()
                                        .foregroundStyle(.indigo)
                                    Text(p.description).font(.caption)
                                    if let d = p.dialogue, !d.isEmpty, d.lowercased() != "null" {
                                        Label(d, systemImage: "bubble.left.fill").font(.caption)
                                    }
                                    if let n = p.narration, !n.isEmpty, n.lowercased() != "null" {
                                        Label(n, systemImage: "text.alignleft").font(.caption).italic()
                                    }
                                    if let s = p.sfx, !s.isEmpty, s.lowercased() != "null" {
                                        Label(s, systemImage: "burst.fill")
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        HStack {
                            Image(systemName: "scroll.fill")
                                .foregroundStyle(.indigo)
                            Text(script.title).font(.headline)
                            Spacer()
                            Text("\(script.panels.count) 格")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                // 输入图
                if !item.inputImageNames.isEmpty {
                    Text("原始素材").font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(item.inputImageNames, id: \.self) { name in
                                if let img = storage.image(named: name) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 110, height: 110)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }
                }

                // 元数据
                VStack(alignment: .leading, spacing: 6) {
                    Label(item.style.displayName, systemImage: "paintpalette")
                    Label(item.createdAt.formatted(date: .long, time: .shortened),
                          systemImage: "calendar")
                    if let p = item.userPrompt, !p.isEmpty {
                        Label(p, systemImage: "text.bubble")
                            .font(.subheadline)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                // 按钮区
                HStack(spacing: 12) {
                    Button {
                        storage.toggleFavorite(item)
                        if let updated = storage.allItems.first(where: { $0.id == item.id }) {
                            item = updated
                        }
                    } label: {
                        Label(item.isFavorite ? "已收藏" : "收藏",
                              systemImage: item.isFavorite ? "heart.fill" : "heart")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.pink)

                    Button {
                        var items: [Any] = []
                        for n in item.outputImageNames {
                            if let img = storage.image(named: n) { items.append(img) }
                        }
                        shareItems = items
                        showShare = true
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(role: .destructive) {
                    showDeleteAlert = true
                } label: {
                    Label("删除这条记录", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationTitle("作品详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare) {
            ShareSheet(items: shareItems)
        }
        .alert("确认删除？", isPresented: $showDeleteAlert) {
            Button("删除", role: .destructive) {
                storage.delete(item)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会同时删除生成结果和原图。")
        }
        .overlay(alignment: .top) {
            if savedToast {
                Text("已保存到相册 ✓")
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation { savedToast = false }
                    }
            }
        }
    }
}

// MARK: - UIActivityViewController 包装

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
