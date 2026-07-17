//
//  HistoryView.swift
//  LifeManga
//

import SwiftUI

struct HistoryView: View {
    let project: MangaProject

    @ObservedObject private var storage = MangaStorage.shared
    @State private var onlyFavorites = false

    private var displayedItems: [MangaItem] {
        let scoped = storage.items(in: project.id)
        return onlyFavorites ? scoped.filter { $0.isFavorite } : scoped
    }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        Group {
            if displayedItems.isEmpty {
                ContentUnavailableView(
                    onlyFavorites ? "还没有收藏" : "这个工程还没有作品",
                    systemImage: onlyFavorites ? "heart" : "book.closed",
                    description: Text("回创作页生成第一幅吧")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(displayedItems) { item in
                            NavigationLink(value: item) {
                                HistoryCell(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("", selection: $onlyFavorites) {
                    Text("全部").tag(false)
                    Text("收藏").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
        }
        .navigationDestination(for: MangaItem.self) { item in
            MangaDetailView(item: item)
        }
    }
}

private struct HistoryCell: View {
    let item: MangaItem
    @ObservedObject private var storage = MangaStorage.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                if let name = item.outputImageNames.first,
                   let img = storage.image(named: name) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 160)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.systemGray5))
                        .frame(height: 160)
                        .overlay(Image(systemName: "photo"))
                }
                if item.isFavorite {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(6)
                }
            }
            HStack(spacing: 5) {
                StylePreviewIcon(style: item.style, size: 18)
                Text(item.style.displayName)
                    .font(.caption)
                    .lineLimit(1)
            }
            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
