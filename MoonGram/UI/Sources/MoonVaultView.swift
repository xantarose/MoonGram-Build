import AVKit
import Combine
import Foundation
import ImageIO
import MoonGramCore
import MoonGramVault
import SwiftUI
import UIKit

@available(iOS 16.0, *)
struct MoonVaultView: View {
    @ObservedObject var model: MoonViewModel
    var chatID: Int64? = nil
    @State private var openingMedia = false
    @State private var requestID: UUID?
    @State private var entries: [MoonVaultEntry] = []
    @State private var loading = false
    @State private var note: String?
    @State private var deleting: MoonVaultEntry?
    @State private var preview: MoonVaultPreview?

    var body: some View {
        List {
            Section {
                Toggle("История моих сообщений", isOn: Binding(get: { self.model.settings?.recordOwnMessages == true }, set: { value in
                    self.model.mutate { $0.recordOwnMessages = value }
                }))
                Toggle("Копии моих фото и видео", isOn: Binding(get: { self.model.settings?.keepOwnMedia == true }, set: { value in
                    self.model.mutate { $0.keepOwnMedia = value }
                }))
            } footer: {
                Text("Для личных чатов. История сохраняет увиденные на этом устройстве версии отправленного тобой текста и отмечает удаление. Медиа сохраняются, когда файл твоего сообщения доступен на устройстве.")
            }.tint(MoonAccent.control).disabled(self.model.busy)
            Section {
                Button("Обновить список", action: self.reload)
                if self.loading { ProgressView() }
                if let note = self.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                Text("Локально, с шифрованием. До 500 снимков, 1 ГиБ на аккаунт и 64 МиБ на медиа. Когда лимит достигнут, новые копии отклоняются.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if self.visibleEntries.isEmpty && !self.loading {
                    Text("Здесь появятся сохранённые сообщения и медиа.").foregroundStyle(.secondary)
                }
                ForEach(self.visibleEntries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(entry.deleted ? "Удалено в Telegram" : "Локальный снимок", systemImage: entry.deleted ? "trash" : "lock.doc")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(Date(timeIntervalSince1970: Double(entry.timestamp)), style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                        if !entry.text.isEmpty { Text(entry.text).textSelection(.enabled) }
                        if let versions = entry.priorTexts, !versions.isEmpty {
                            DisclosureGroup("Предыдущие версии · \(versions.count)") {
                                ForEach(Array(versions.indices.reversed()), id: \.self) { index in
                                    Text(versions[index]).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        if entry.mediaFile != nil {
                            Button(entry.kind == .video ? "Открыть сохранённое видео" : "Открыть сохранённое фото") {
                                guard self.requestID == nil else { return }
                                let request = UUID()
                                self.requestID = request
                                self.loading = true
                                MoonVault.shared.preview(accountID: self.model.accountID, entry: entry) { result in
                                    guard self.requestID == request else {
                                        if case let .success(url) = result { try? FileManager.default.removeItem(at: url) }
                                        return
                                    }
                                    self.requestID = nil
                                    self.loading = false
                                    switch result {
                                    case let .success(url):
                                        self.preview = MoonVaultPreview(url: url, kind: entry.kind)
                                        self.openingMedia = true
                                    case let .failure(error): self.model.error = error.localizedDescription
                                    }
                                }
                            }
                        }
                    }.padding(.vertical, 6)
                    .swipeActions { Button("Удалить копию", role: .destructive) { self.deleting = entry } }
                }
            } header: { Text("Архив") }
        }
        .navigationTitle("История сообщений")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: self.reload)
        .onDisappear { self.requestID = nil }
        .navigationDestination(isPresented: self.$openingMedia) {
            if let preview = self.preview { MoonVaultMediaView(preview: preview) }
        }
        .onChange(of: self.openingMedia) { open in
            if !open { self.preview = nil }
        }
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

    private var visibleEntries: [MoonVaultEntry] {
        guard let chatID = self.chatID else { return self.entries }
        return self.entries.filter { $0.peerID == chatID }
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

    @State private var failed = false

    var body: some View {
        Group {
            if self.failed { Text("Файл недоступен или повреждён.").foregroundStyle(.secondary) }
            else if let player = self.player { VideoPlayer(player: player) }
            else if let image = self.image { Image(uiImage: image).resizable().scaledToFit() }
            else { ProgressView("Открываю…") }
        }
        .navigationTitle(self.preview.kind == .video ? "Видео" : "Фото")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if self.preview.kind == .video {
                let asset = AVURLAsset(url: self.preview.url)
                do {
                    let playable = try await asset.load(.isPlayable)
                    guard !Task.isCancelled else { return }
                    if playable { self.player = AVPlayer(playerItem: AVPlayerItem(asset: asset)) }
                    else { self.failed = true }
                } catch { if !Task.isCancelled { self.failed = true } }
            } else {
                let url = self.preview.url
                let thumb = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
                    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048]
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                }.value
                guard !Task.isCancelled else { return }
                if let thumb { self.image = UIImage(cgImage: thumb) } else { self.failed = true }
            }
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
