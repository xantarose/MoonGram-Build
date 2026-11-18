import AVKit
import Combine
import Foundation
import MoonGramCore
import MoonGramVault
import SwiftUI
import UIKit

@available(iOS 16.0, *)
struct MoonVaultView: View {
    @ObservedObject var model: MoonViewModel
    @State private var peerID = ""
    @State private var saveMessages = false
    @State private var saveMedia = false
    @State private var entries: [MoonVaultEntry] = []
    @State private var loading = false
    @State private var note: String?
    @State private var deleting: MoonVaultEntry?
    @State private var preview: MoonVaultPreview?

    var body: some View {
        List {
            Section {
                TextField("Telegram ID друга", text: self.$peerID).keyboardType(.numberPad)
                Toggle("Копии загруженных входящих сообщений", isOn: self.$saveMessages).tint(MoonAccent.control)
                Toggle("Копии открытых одноразовых фото и видео", isOn: self.$saveMedia).tint(MoonAccent.control)
                Button("Сохранить настройки") {
                    self.model.mutate {
                        let experiments = MoonExperiments(testPeerID: Int64(self.peerID), saveLoadedMessages: self.saveMessages, saveViewOnceMedia: self.saveMedia)
                        try experiments.validate()
                        $0.experiments = experiments
                    }
                }
            } header: { Text("Эксперимент с согласившимся другом") } footer: {
                Text("Только указанный личный облачный чат и входящие данные. Настройки выключены по умолчанию. Обычные события просмотра и таймеры Telegram продолжают работать. Это нарушает ожидаемое исчезновение копии и ограничивается вашим согласованным экспериментом.")
            }
            Section {
                Button("Обновить список", action: self.reload)
                if self.loading { ProgressView() }
                if let note = self.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                Text("Локально, с шифрованием. До 500 снимков, 1 ГиБ на аккаунт и 64 МиБ на медиа. Когда лимит достигнут, новые копии отклоняются.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if self.entries.isEmpty && !self.loading {
                    Text("Снимков пока нет. Включите эксперимент для друга, затем откройте тестовый чат или медиа.").foregroundStyle(.secondary)
                }
                ForEach(self.entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(entry.deleted ? "Удалено в Telegram" : "Локальный снимок", systemImage: entry.deleted ? "trash" : "lock.doc")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(Date(timeIntervalSince1970: Double(entry.timestamp)), style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                        if !entry.text.isEmpty { Text(entry.text).textSelection(.enabled) }
                        if entry.mediaFile != nil {
                            Button(entry.kind == .video ? "Открыть сохранённое видео" : "Открыть сохранённое фото") {
                                self.loading = true
                                MoonVault.shared.preview(accountID: self.model.accountID, entry: entry) { result in
                                    self.loading = false
                                    switch result {
                                    case let .success(url): self.preview = MoonVaultPreview(url: url, kind: entry.kind)
                                    case let .failure(error): self.model.error = error.localizedDescription
                                    }
                                }
                            }
                        }
                    }.padding(.vertical, 6)
                    .swipeActions { Button("Удалить копию", role: .destructive) { self.deleting = entry } }
                }
            } header: { Text("Сохранённые снимки") } footer: { Text("Сохраняется только уже полученное содержимое. Удалённое до загрузки сообщение восстановить нельзя; захват медиа при медленной сети может не успеть завершиться.") }
        }
        .navigationTitle("Локальные копии")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let experiments = self.model.settings?.experiments ?? MoonExperiments()
            self.peerID = experiments.testPeerID.map(String.init) ?? ""
            self.saveMessages = experiments.saveLoadedMessages
            self.saveMedia = experiments.saveViewOnceMedia
            self.reload()
        }
        .sheet(item: self.$preview) { preview in MoonVaultMediaView(preview: preview) }
        .confirmationDialog("Удалить эту локальную копию?", isPresented: Binding(get: { self.deleting != nil }, set: { if !$0 { self.deleting = nil } }), titleVisibility: .visible) {
            Button("Удалить копию", role: .destructive) {
                guard let entry = self.deleting else { return }
                MoonVault.shared.delete(accountID: self.model.accountID, entry: entry) { error in
                    if let error = error { self.model.error = error.localizedDescription }
                    self.deleting = nil
                    self.reload()
                }
            }
        }
    }

    private func reload() {
        self.loading = true
        MoonVault.shared.entries(accountID: self.model.accountID) { entries, note in
            self.entries = entries
            self.note = note
            self.loading = false
        }
    }
}

private struct MoonVaultPreview: Identifiable {
    let id = UUID()
    let url: URL
    let kind: MoonVaultKind
}

@available(iOS 16.0, *)
private struct MoonVaultMediaView: View {
    let preview: MoonVaultPreview
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            Group {
                if self.preview.kind == .video { VideoPlayer(player: self.player) }
                else if let image = self.image { Image(uiImage: image).resizable().scaledToFit() }
                else { ProgressView() }
            }
            .navigationTitle("Локальная копия")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { self.dismiss() } } }
        }
        .onAppear {
            if self.preview.kind == .video { self.player = AVPlayer(url: self.preview.url) }
            else { self.image = UIImage(contentsOfFile: self.preview.url.path) }
        }
        .onDisappear {
            self.player?.pause()
            self.player = nil
            self.image = nil
            try? FileManager.default.removeItem(at: self.preview.url)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            self.player?.pause()
            try? FileManager.default.removeItem(at: self.preview.url)
            self.dismiss()
        }
    }
}
