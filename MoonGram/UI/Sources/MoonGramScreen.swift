#if canImport(Display) && canImport(AsyncDisplayKit)
import AsyncDisplayKit
import Display
#endif
import Combine
import Foundation
import MoonGramCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

#if canImport(Display) && canImport(AsyncDisplayKit)
@available(iOS 16.0, *)
public final class MoonGramScreen: ViewController {
    private let accountID: Int64
    private let peerID: Int64?
    private let nativeGifts: MoonNativeGiftProvider?
    private let streak: Bool
    private let transport: MoonTransportControls?
    private var host: UIHostingController<AnyView>?

    public init(accountID: Int64, peerID: Int64? = nil, nativeGifts: MoonNativeGiftProvider? = nil, transport: MoonTransportControls? = nil, streak: Bool = false) {
        self.accountID = accountID
        self.peerID = peerID
        self.nativeGifts = nativeGifts
        self.streak = streak
        self.transport = transport
        super.init(navigationBarPresentationData: nil)
        self.navigationPresentation = .modal
    }

    required public init(coder: NSCoder) { fatalError("Use init(accountID:peerID:)") }

    public override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = .systemGroupedBackground
        super.displayNodeDidLoad()
        let root = MoonRootView(accountID: self.accountID, peerID: self.peerID, nativeGifts: self.nativeGifts, transport: self.transport, streak: self.streak, close: { [weak self] in
            self?.dismiss()
        })
        let host = UIHostingController(rootView: AnyView(root))
        self.addChild(host)
        self.displayNode.view.addSubview(host.view)
        host.didMove(toParent: self)
        self.host = host
    }

    public override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.host?.view.frame = CGRect(origin: .zero, size: layout.size)
    }
}
#endif

/// Used only by the isolated iOS QA app; it has a separate app container and no Telegram session.
@available(iOS 16.0, *)
@MainActor
public func makeMoonGramQAView() -> AnyView {
    var profile = MoonProfile()
    profile.displayName = "MoonGram"
    profile.username = "moon_user"
    profile.localPremium = true
    profile.stars = 999_999_999
    profile.walletBalance = try? MoonAmount("123456.789")
    profile.collectibleNumber = "+888 1234 5678"
    profile.gifts = [MoonGift(title: "Лунный подарок", number: "888", model: .moon), MoonGift(title: "Северная звезда", number: "7", model: .star, backdrop: "284A38", symbolColor: "D5E8CE")]
    if ProcessInfo.processInfo.arguments.contains("--preview") {
        return AnyView(NavigationStack { MoonProfilePreview(profile: profile) })
    }
    var settings = MoonSettings()
    settings.enabled = true
    settings.displayMode = .both
    try? settings.setActiveProfile(profile)
    try? MoonStore.shared.save(settings, accountID: 1)
    if ProcessInfo.processInfo.arguments.contains("--privacy") {
        return AnyView(NavigationStack { MoonPrivacyView(model: MoonViewModel(accountID: 1)) })
    }
    return AnyView(MoonRootView(accountID: 1, peerID: nil, close: {}))
}

@available(iOS 16.0, *)
@MainActor
final class MoonViewModel: ObservableObject {
    let accountID: Int64
    let store: MoonStore
    let nativeGifts: MoonNativeGiftProvider?
    @Published private(set) var settings: MoonSettings?
    @Published private(set) var busy = false
    @Published var error: String?
    private var settingsObservation: AnyCancellable?

    init(accountID: Int64, store: MoonStore = .shared, nativeGifts: MoonNativeGiftProvider? = nil) {
        self.accountID = accountID
        self.store = store
        self.nativeGifts = nativeGifts
        self.reload()
        self.settingsObservation = NotificationCenter.default.publisher(for: .moonGramSettingsDidChange).sink { [weak self] notification in
            let changedAccountID = notification.userInfo?["accountID"] as? Int64
            Task { @MainActor [weak self] in
                guard let self, changedAccountID == self.accountID else { return }
                self.reload()
            }
        }
    }

    var profile: MoonProfile { self.settings?.activeProfile ?? MoonProfile() }

    func reload() {
        do { self.settings = try self.store.settings(accountID: self.accountID) }
        catch { self.error = "Настройки не прочитаны. Отправка сигналов гостевого режима приостановлена. Файл сохранён без изменений. \(error.localizedDescription)" }
    }

    func mutate(_ transform: (inout MoonSettings) throws -> Void, completion: (() -> Void)? = nil) {
        guard !self.busy, var candidate = self.settings else { return }
        let previous = candidate
        do {
            try transform(&candidate)
            try candidate.validate()
        } catch { self.error = error.localizedDescription; return }
        self.busy = true
        let snapshot = candidate
        let store = self.store
        let accountID = self.accountID
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try store.save(snapshot, accountID: accountID) }.value
                self.settings = snapshot
                self.busy = false
                if snapshot.autoPublishStyle == true && (previous.autoPublishStyle != true || previous.activeProfile != snapshot.activeProfile) {
                    MoonAutoPublish.shared.schedule(accountID: accountID)
                }
                completion?()
            } catch {
                self.busy = false
                self.error = error.localizedDescription
            }
        }
    }

    func saveProfile(_ profile: MoonProfile, completion: (() -> Void)? = nil) {
        self.mutate({ try $0.setActiveProfile(profile) }, completion: completion)
    }

    func importData(_ data: Data, friendID: Int64?) {
        do {
            let archive = try MoonArchive.decode(data)
            if let friendID = friendID {
                try self.store.importFriend(archive, accountID: self.accountID, peerID: friendID)
                self.objectWillChange.send()
            } else {
                self.mutate {
                    guard $0.presets.count < 8 else { throw MoonError.invalid("не более 8 пресетов") }
                    let preset = MoonPreset(name: "Импорт", profile: archive.profile)
                    $0.presets.append(preset)
                    $0.activePresetID = preset.id
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}

@available(iOS 16.0, *)
struct MoonRootView: View {
    @StateObject private var model: MoonViewModel
    private let peerID: Int64?
    private let close: () -> Void
    private let streak: Bool
    private let transport: MoonTransportControls?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var includeBalances = false
    @State private var friendID = ""
    @State private var importForFriend = false
    @State private var document = MoonDocument(data: Data())

    init(accountID: Int64, peerID: Int64?, nativeGifts: MoonNativeGiftProvider? = nil, transport: MoonTransportControls? = nil, streak: Bool = false, close: @escaping () -> Void) {
        self._model = StateObject(wrappedValue: MoonViewModel(accountID: accountID, nativeGifts: nativeGifts))
        self.peerID = peerID
        self.close = close
        self.streak = streak
        self.transport = transport
    }

    var body: some View {
        NavigationStack {
            Group {
                if let peerID = self.peerID, self.streak {
                    MoonStreakView(accountID: self.model.accountID, peerID: peerID)
                } else if let peerID = self.peerID {
                    MoonProfilePreview(profile: self.model.store.visibleProfile(accountID: self.model.accountID, peerID: peerID), nativeGifts: self.model.nativeGifts)
                } else {
                    self.settingsList
                }
            }
            .navigationTitle(self.streak ? "Стрик" : "MoonGram")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Готово", action: self.close) }
            }
        }
        .tint(MoonAccent.text)
        .alert("MoonGram", isPresented: Binding(get: { self.model.error != nil }, set: { if !$0 { self.model.error = nil } })) {
            Button("Понятно", role: .cancel) { self.model.error = nil }
        } message: { Text(self.model.error ?? "") }
        .fileImporter(isPresented: self.$showImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try moonReadFile(url, maximumBytes: MoonArchive.maximumBytes)
                let peerID: Int64?
                if self.importForFriend {
                    guard let value = Int64(self.friendID), value > 0, value != self.model.accountID else {
                        throw MoonError.invalid("числовой ID друга")
                    }
                    peerID = value
                } else { peerID = nil }
                self.model.importData(data, friendID: peerID)
            } catch { self.model.error = error.localizedDescription }
        }
        .fileExporter(isPresented: self.$showExporter, document: self.document, contentType: .json, defaultFilename: "MoonGram-profile") { result in
            if case let .failure(error) = result { self.model.error = error.localizedDescription }
        }
    }

    private var settingsList: some View {
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Твой Telegram. Твоё оформление.").font(.headline)
                        Text("Визуалы хранятся отдельно от аккаунта.").font(.subheadline).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "moon.stars.fill").font(.title).accessibilityHidden(true) }
                .padding(.vertical, 8)
                Toggle("Визуалы", isOn: Binding(get: { self.model.settings?.enabled ?? false }, set: { enabled in
                    self.model.mutate { $0.enabled = enabled }
                })).tint(MoonAccent.control)
                Toggle("Оформления друзей", isOn: Binding(get: { self.model.settings?.showFriends ?? true }, set: { enabled in
                    self.model.mutate { $0.showFriends = enabled }
                })).tint(MoonAccent.control)
                Picker("Показывать", selection: Binding(get: { self.model.settings?.effectiveDisplayMode ?? .original }, set: { mode in
                    self.model.mutate {
                        if mode == .original { $0.enabled = false }
                        else { $0.enabled = true; $0.displayMode = mode }
                    }
                })) {
                    ForEach(MoonDisplayMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
            } footer: {
                Text("Выключение возвращает реальные данные. Подарки, модели и пресеты сохраняются.")
            }
            Section("Приватность") {
                NavigationLink { MoonPrivacyView(model: self.model) } label: { Label("Гостевой режим", systemImage: "eye.slash") }
            }
            Section("Моё оформление") {
                NavigationLink { MoonProfileEditor(model: self.model) } label: { Label("Профиль и балансы", systemImage: "person.crop.circle") }
                NavigationLink { MoonGiftsView(model: self.model) } label: {
                    Label("Коллекции · \(self.model.profile.gifts.count)", systemImage: "gift")
                }
                NavigationLink { MoonPresetsView(model: self.model) } label: { Label("Пресеты", systemImage: "square.stack") }
                NavigationLink { MoonProfilePreview(profile: self.model.profile, nativeGifts: self.model.nativeGifts) } label: { Label("Предпросмотр", systemImage: "eye") }
            }
            Section {
                Toggle("Включить балансы в экспорт", isOn: self.$includeBalances).tint(MoonAccent.control)
                Button {
                    do {
                        self.document = MoonDocument(data: try MoonArchive(profile: self.model.profile.shared(includingBalances: self.includeBalances)).encoded())
                        self.showExporter = true
                    } catch { self.model.error = error.localizedDescription }
                } label: { Label("Экспортировать", systemImage: "square.and.arrow.up") }
                Button { self.importForFriend = false; self.showImporter = true } label: { Label("Импортировать как пресет", systemImage: "square.and.arrow.down") }
            } header: { Text("Передать оформление") } footer: { Text("Экспорт содержит только оформление. Данные входа и переписки в него не попадают.") }
            Section {
                TextField("Числовой Telegram ID друга", text: self.$friendID).keyboardType(.numberPad)
                Button { self.importForFriend = true; self.showImporter = true } label: { Label("Импортировать для этого профиля", systemImage: "person.badge.plus") }
                Button("Убрать импортированное оформление", role: .destructive) {
                    do {
                        guard let id = Int64(self.friendID), id > 0 else { throw MoonError.invalid("ID друга") }
                        try self.model.store.removeFriend(accountID: self.model.accountID, peerID: id)
                    } catch { self.model.error = error.localizedDescription }
                }
            } header: { Text("Оформление друга") } footer: { Text("Сверьте ID с другом. Файл оформления сам по себе не подтверждает владельца аккаунта.") }
            if let transport = self.transport {
                Section {
                    NavigationLink { MoonTransportView(controls: transport) } label: { Label("Подключение", systemImage: "network") }
                }
            }
            Section {
                Toggle("Показывать стрики в личных чатах", isOn: Binding(get: {
                    self.model.settings?.streaksEnabled == true
                }, set: { enabled in
                    self.model.mutate { $0.streaksEnabled = enabled }
                })).tint(MoonAccent.control)
            } footer: {
                Text("Когда включено, счётчик появляется в карточке собеседника.")
            }
            Section("Обмен с друзьями") {
                NavigationLink { MoonSyncView(model: self.model) } label: { Label("Синхронизация", systemImage: "arrow.triangle.2.circlepath") }
            }
            Section("Эксперимент с другом") {
                NavigationLink { MoonVaultView(model: self.model) } label: { Label("Локальные копии", systemImage: "lock.doc") }
            }
            Section {
                Text("MoonGram — неофициальный клиент на основе Telegram.").font(.footnote).foregroundStyle(.secondary)
                Text("Визуальные Stars, Premium и коллекционные предметы не меняют настоящий баланс, подписку и владение активами.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .disabled(self.model.busy || self.model.settings == nil)
        .overlay { if self.model.busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
    }
}
