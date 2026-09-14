import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: LiveTranslateViewModel

    var body: some View {
        List {
            if model.history.isEmpty {
                ContentUnavailableView(
                    "还没有历史记录",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("在同传页面保存一次会话后会出现在这里。")
                )
            } else {
                ForEach(model.history) { item in
                    NavigationLink {
                        HistoryDetailView(item: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(item.sourceLanguage.name) ↔︎ \(item.targetLanguage.name)")
                                .font(.headline)
                            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(item.segments.count) 段 · \(item.mode?.rawValue ?? "同传")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            model.deleteHistory(item.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("历史记录")
        .task { await model.refreshHistory() }
    }
}

private struct HistoryDetailView: View {
    let item: SavedConversation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(item.segments) { segment in
                    VStack(alignment: .leading, spacing: 5) {
                        if let speaker = segment.speaker {
                            Text(speaker == .me ? "我" : "对方")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }
                        Text(segment.sourceText)
                        if !segment.translatedText.isEmpty {
                            Text(segment.translatedText)
                                .fontWeight(.medium)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }

                if let summary = item.summary, !summary.isEmpty {
                    Divider()
                    Label("总结", systemImage: "sparkles")
                        .font(.headline)
                    Text(summary).textSelection(.enabled)
                }
            }
            .padding()
        }
        .navigationTitle(item.createdAt.formatted(date: .abbreviated, time: .omitted))
        .toolbar {
            ShareLink(item: item.exportText) {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }
}
