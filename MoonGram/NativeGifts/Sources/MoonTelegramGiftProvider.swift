import AccountContext
import ComponentFlow
import Foundation
import GiftItemComponent
import MoonGramCore
import MoonGramUI
import SwiftSignalKit
import SwiftUI
import TelegramCore
import TelegramPresentationData
import UIKit

/// Reports cosmetic catalog entries without creating a Telegram gift reference or ownership record.
public func moonCatalogGifts(accountID: Int64, peerID: Int64) -> Signal<[MoonGift], NoError> {
    return Signal { subscriber in
        func emit() {
            let profile = MoonStore.shared.visibleProfile(accountID: accountID, peerID: peerID)
            subscriber.putNext(profile?.gifts.filter { $0.telegram != nil } ?? [])
        }
        let observer = NotificationCenter.default.addObserver(forName: .moonGramSettingsDidChange, object: nil, queue: .main) { change in
            if change.userInfo?["accountID"] as? Int64 == accountID { emit() }
        }
        emit()
        return ActionDisposable { NotificationCenter.default.removeObserver(observer) }
    } |> distinctUntilChanged
}

@available(iOS 16.0, *)
@MainActor
public final class MoonTelegramGiftProvider: MoonNativeGiftProvider {
    let context: AccountContext
    private struct CacheEntry {
        let attributes: [StarGift.UniqueGift.Attribute]
        let updated: TimeInterval
    }
    private var cache: [Int64: CacheEntry] = [:]
    private var requests: [Int64: MetaDisposable] = [:]
    private var deadlines: [Int64: Task<Void, Never>] = [:]
    private var observers: [Int64: [UUID: ([StarGift.UniqueGift.Attribute]?) -> Void]] = [:]

    public init(context: AccountContext) { self.context = context }
    deinit {
        for request in self.requests.values { request.dispose() }
        for deadline in self.deadlines.values { deadline.cancel() }
    }

    public func artwork(for gift: MoonGift) -> UIView {
        MoonTelegramGiftView(provider: self, gift: gift)
    }

    public func editor(for gift: MoonGift, completion: @escaping (MoonGift) -> Void) -> AnyView {
        AnyView(MoonTelegramGiftEditor(provider: self, gift: gift, completion: completion))
    }

    func attributes(baseGiftID: Int64, refresh: Bool = false, next: @escaping ([StarGift.UniqueGift.Attribute]?) -> Void) -> Disposable {
        let now = Date().timeIntervalSinceReferenceDate
        if let cached = self.cache[baseGiftID] {
            next(cached.attributes)
            if !refresh && now - cached.updated < 60 { return EmptyDisposable }
        }
        let observerID = UUID()
        self.observers[baseGiftID, default: [:]][observerID] = next
        if self.requests[baseGiftID] == nil {
            guard self.requests.count < 8 else {
                self.observers[baseGiftID]?.removeValue(forKey: observerID)
                next(nil)
                return EmptyDisposable
            }
            let request = MetaDisposable()
            self.requests[baseGiftID] = request
            self.deadlines[baseGiftID] = Task { @MainActor [weak self, weak request] in
                do { try await Task.sleep(nanoseconds: 20_000_000_000) }
                catch { return }
                guard let self, let request, self.requests[baseGiftID] === request else { return }
                let callbacks = self.observers[baseGiftID].map { Array($0.values) } ?? []
                let cached = self.cache[baseGiftID]?.attributes
                self.finishRequest(baseGiftID)
                for callback in callbacks { callback(cached) }
            }
            request.set((self.context.engine.payments.getStarGiftUpgradeAttributes(giftId: baseGiftID)
            |> deliverOnMainQueue).start(next: { [weak self] attributes in
                guard let self else { return }
                let accepted = attributes.flatMap { $0.count <= 4096 ? $0 : nil }
                if let accepted, !accepted.isEmpty {
                    self.cache[baseGiftID] = CacheEntry(attributes: accepted, updated: Date().timeIntervalSinceReferenceDate)
                    if self.cache.count > 32, let oldest = self.cache.min(by: { $0.value.updated < $1.value.updated })?.key {
                        self.cache.removeValue(forKey: oldest)
                    }
                }
                let value = accepted ?? self.cache[baseGiftID]?.attributes
                let observers = self.observers[baseGiftID].map { Array($0.values) } ?? []
                for observer in observers { observer(value) }
            }, completed: { [weak self] in
                self?.finishRequest(baseGiftID)
            }))
        }
        return ActionDisposable { [weak self] in
            DispatchQueue.main.async { self?.observers[baseGiftID]?.removeValue(forKey: observerID) }
        }
    }

    private func finishRequest(_ id: Int64) {
        self.deadlines.removeValue(forKey: id)?.cancel()
        self.observers.removeValue(forKey: id)
        self.requests.removeValue(forKey: id)?.dispose()
    }
}

@available(iOS 16.0, *)
@MainActor
private final class MoonTelegramGiftView: UIView, UIContextMenuInteractionDelegate {
    private let provider: MoonTelegramGiftProvider
    private let gift: MoonGift
    private var attributes: [StarGift.UniqueGift.Attribute] = []
    private var host = ComponentView<Empty>()
    private var request: Disposable?
    private let status = UIButton(type: .system)
    private var lifecycle: [NSObjectProtocol] = []

    init(provider: MoonTelegramGiftProvider, gift: MoonGift) {
        self.provider = provider
        self.gift = gift
        super.init(frame: .zero)
        self.isAccessibilityElement = true
        self.accessibilityLabel = "\(gift.title), модель \(gift.modelName), оформление MoonGram"
        self.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Обновить оформление", target: self, selector: #selector(self.retry))]
        self.addInteraction(UIContextMenuInteraction(delegate: self))
        self.backgroundColor = .secondarySystemGroupedBackground
        self.status.titleLabel?.numberOfLines = 0
        self.status.titleLabel?.textAlignment = .center
        self.status.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        self.status.titleLabel?.adjustsFontForContentSizeCategory = true
        self.status.setTitle("Загружаем ресурсы Telegram…", for: .normal)
        self.status.addTarget(self, action: #selector(self.retry), for: .touchUpInside)
        self.addSubview(self.status)
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification] {
            self.lifecycle.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.resetRenderer()
                    self?.setNeedsLayout()
                }
            })
        }
        self.load(refresh: false)
    }

    required init?(coder: NSCoder) { fatalError("Use init(provider:gift:)") }
    deinit {
        self.request?.dispose()
        for observer in self.lifecycle { NotificationCenter.default.removeObserver(observer) }
    }

    @objc private func retry() { self.load(refresh: true) }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(title: "Обновить оформление", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                Task { @MainActor [weak self] in self?.retry() }
            }])
        }
    }
    private func load(refresh: Bool) {
        guard let selection = self.gift.telegram else { return }
        self.request?.dispose()
        self.request = self.provider.attributes(baseGiftID: selection.baseGiftID, refresh: refresh) { [weak self] values in
            guard let self else { return }
            let selected = (values ?? []).filter { attribute in
                switch attribute {
                case let .model(_, file, _, _): return file.fileId.id == selection.modelFileID
                case let .pattern(_, file, _): return file.fileId.id == selection.patternFileID
                case let .backdrop(_, id, _, _, _, _, _): return id == selection.backdropID
                default: return false
                }
            }
            if selected.count == 3 { self.attributes = selected }
            self.status.setTitle("Ресурсы недоступны. Нажмите, чтобы обновить", for: .normal)
            self.resetRenderer()
            self.setNeedsLayout()
        }
    }

    private func resetRenderer() {
        self.host.view?.removeFromSuperview()
        self.host = ComponentView<Empty>()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if self.window == nil { self.resetRenderer() }
        else { self.setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.status.frame = self.bounds.insetBy(dx: 8, dy: 8)
        self.status.isHidden = self.attributes.count == 3
        guard self.window != nil, UIApplication.shared.applicationState == .active, self.attributes.count == 3,
              self.bounds.width > 0, self.bounds.height > 0 else { return }
        let data = self.provider.context.sharedContext.currentPresentationData.with { $0 }
        let component = GiftItemComponent(context: self.provider.context, style: .glass, theme: data.theme, strings: data.strings,
            subject: .preview(attributes: self.attributes, rarity: nil),
            ribbon: GiftItemComponent.Ribbon(text: "#" + self.gift.number, font: .monospaced, color: .custom(Int32(self.gift.backdrop, radix: 16) ?? 0, Int32(self.gift.symbolColor, radix: 16) ?? 0)), mode: .profile,
            allowAnimations: !UIAccessibility.isReduceMotionEnabled, action: nil, contextAction: nil)
        let size = self.host.update(transition: .immediate, component: AnyComponent(component), environment: {}, containerSize: self.bounds.size)
        if let view = self.host.view {
            if view.superview !== self { self.addSubview(view) }
            view.frame = CGRect(origin: .zero, size: size)
            view.isAccessibilityElement = false
        }
    }
}

@available(iOS 16.0, *)
@MainActor
private final class MoonTelegramGiftCatalog: ObservableObject {
    struct FileChoice: Identifiable { let id: Int64; let name: String }
    struct BackdropChoice: Identifiable { let id: Int32; let name: String; let outerColor: Int32; let patternColor: Int32 }
    @Published private(set) var gifts: [StarGift.Gift] = []
    @Published private(set) var loading = true
    @Published private(set) var catalogLoaded = false
    @Published private(set) var revision = 0
    @Published private(set) var attributes: [StarGift.UniqueGift.Attribute] = []
    @Published var baseGiftID: Int64 = 0
    @Published var modelFileID: Int64 = 0
    @Published var patternFileID: Int64 = 0
    @Published var backdropID: Int32? = nil
    private let provider: MoonTelegramGiftProvider
    private var listRequest: Disposable?
    private var updateRequest: Disposable?
    private var attributeRequest: Disposable?

    init(provider: MoonTelegramGiftProvider, gift: MoonGift) {
        self.provider = provider
        if let selection = gift.telegram {
            self.baseGiftID = selection.baseGiftID
            self.modelFileID = selection.modelFileID
            self.patternFileID = selection.patternFileID
            self.backdropID = selection.backdropID
            self.loadAttributes()
        }
        self.refreshCatalog()
    }

    func refreshCatalog() {
        self.catalogLoaded = false
        self.listRequest?.dispose()
        self.updateRequest?.dispose()
        self.listRequest = (self.provider.context.engine.payments.cachedStarGifts()
        |> filter { $0 != nil }
        |> timeout(15, queue: Queue.mainQueue(), alternate: .single([]))
        |> deliverOnMainQueue).start(next: { [weak self] gifts in
            guard let self, let gifts else { return }
            self.gifts = gifts.compactMap { gift -> StarGift.Gift? in
                if case let .generic(value) = gift, let title = value.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   value.upgradeStars != nil || (value.upgradeVariantsCount ?? 0) > 0 { return value }
                return nil
            }
            self.catalogLoaded = true
        })
        self.updateRequest = self.provider.context.engine.payments.keepStarGiftsUpdated().start()
    }

    deinit { self.listRequest?.dispose(); self.updateRequest?.dispose(); self.attributeRequest?.dispose() }

    var models: [FileChoice] {
        self.attributes.compactMap {
            if case let .model(name, file, _, crafted) = $0 { return FileChoice(id: file.fileId.id, name: name + (crafted ? " · Crafted" : "")) }
            return nil
        }
    }
    var patterns: [FileChoice] {
        self.attributes.compactMap {
            if case let .pattern(name, file, _) = $0 { return FileChoice(id: file.fileId.id, name: name) }
            return nil
        }
    }
    var backdrops: [BackdropChoice] {
        self.attributes.compactMap {
            if case let .backdrop(name, id, _, outerColor, patternColor, _, _) = $0 {
                return BackdropChoice(id: id, name: name, outerColor: outerColor, patternColor: patternColor)
            }
            return nil
        }
    }

    func selectGift(_ id: Int64) {
        guard id != self.baseGiftID else { return }
        self.baseGiftID = id
        self.modelFileID = 0
        self.patternFileID = 0
        self.backdropID = nil
        self.attributes = []
        self.loadAttributes()
    }

    func loadAttributes(refresh: Bool = false) {
        guard self.baseGiftID != 0 else { return }
        self.loading = true
        self.attributeRequest?.dispose()
        let id = self.baseGiftID
        self.attributeRequest = self.provider.attributes(baseGiftID: id, refresh: refresh) { [weak self] attributes in
            guard let self, id == self.baseGiftID else { return }
            self.loading = false
            guard let attributes else { return }
            self.attributes = attributes
            self.revision += 1
            if self.modelFileID == 0 { self.modelFileID = self.models.first?.id ?? 0 }
            if self.patternFileID == 0 { self.patternFileID = self.patterns.first?.id ?? 0 }
            if self.backdropID == nil { self.backdropID = self.backdrops.first?.id }
        }
    }

    func applying(to original: MoonGift) -> MoonGift? {
        guard self.models.contains(where: { $0.id == self.modelFileID }), self.patterns.contains(where: { $0.id == self.patternFileID }),
              let backdrop = self.backdrops.first(where: { $0.id == self.backdropID }) else { return nil }
        var gift = original
        gift.telegram = MoonTelegramGift(baseGiftID: self.baseGiftID, modelFileID: self.modelFileID, patternFileID: self.patternFileID, backdropID: backdrop.id)
        if let name = self.gifts.first(where: { $0.id == self.baseGiftID })?.title { gift.title = String(name.prefix(64)) }
        gift.modelName = String((self.models.first(where: { $0.id == self.modelFileID })?.name ?? "Telegram").prefix(64))
        gift.backdrop = String(format: "%06X", UInt32(bitPattern: backdrop.outerColor) & 0xFFFFFF)
        gift.symbolColor = String(format: "%06X", UInt32(bitPattern: backdrop.patternColor) & 0xFFFFFF)
        gift.artwork = nil
        return gift
    }
}

@available(iOS 16.0, *)
private struct MoonTelegramGiftEditor: View {
    let provider: MoonTelegramGiftProvider
    let gift: MoonGift
    let completion: (MoonGift) -> Void
    @StateObject private var catalog: MoonTelegramGiftCatalog

    init(provider: MoonTelegramGiftProvider, gift: MoonGift, completion: @escaping (MoonGift) -> Void) {
        self.provider = provider
        self.gift = gift
        self.completion = completion
        self._catalog = StateObject(wrappedValue: MoonTelegramGiftCatalog(provider: provider, gift: gift))
    }

    var body: some View {
        Form {
            if let selected = self.catalog.applying(to: self.gift) {
                Section { MoonTelegramNativePreview(provider: self.provider, gift: selected).id(selected.telegram).id(self.catalog.revision).frame(height: 240) }
            }
            Section {
                if !self.catalog.catalogLoaded { ProgressView("Загружаем каталог Telegram…") }
                if self.catalog.catalogLoaded && self.catalog.gifts.isEmpty {
                    Text("Коллекционные подарки с вариантами оформления пока недоступны.").foregroundStyle(.secondary)
                    Button("Загрузить каталог снова") { self.catalog.refreshCatalog() }
                }
                NavigationLink {
                    MoonCatalogSearch(gifts: self.catalog.gifts, selected: self.catalog.baseGiftID, select: self.catalog.selectGift)
                } label: {
                    LabeledContent("Подарок", value: self.catalog.gifts.first(where: { $0.id == self.catalog.baseGiftID })?.title ?? "Выбрать")
                }
                if self.catalog.baseGiftID != 0 {
                    if self.catalog.loading { ProgressView("Загружаем модели…") }
                    Picker("Модель", selection: self.$catalog.modelFileID) {
                        ForEach(self.catalog.models) { Text($0.name).tag($0.id) }
                    }
                    Picker("Узор", selection: self.$catalog.patternFileID) {
                        ForEach(self.catalog.patterns) { Text($0.name).tag($0.id) }
                    }
                    Picker("Фон", selection: self.$catalog.backdropID) {
                        ForEach(self.catalog.backdrops) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if !self.catalog.loading && self.catalog.models.isEmpty { Text("Для этого подарка варианты не получены.").foregroundStyle(.secondary) }
                    Button("Обновить варианты") { self.catalog.loadAttributes(refresh: true) }
                }
            } footer: {
                Text("Выбирается только оформление из каталога Telegram. Покупка, выпуск NFT и изменение настоящих подарков здесь не выполняются.")
            }
        }
        .navigationTitle("Подарок Telegram")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Выбрать") { if let gift = self.catalog.applying(to: self.gift) { self.completion(gift) } }
                    .disabled(self.catalog.applying(to: self.gift) == nil)
            }
        }
    }
}

@available(iOS 16.0, *)
private struct MoonCatalogSearch: View {
    let gifts: [StarGift.Gift]
    let selected: Int64
    let select: (Int64) -> Void
    @State private var search = ""
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            let filtered = self.gifts.filter { self.search.isEmpty || ($0.title ?? "").localizedCaseInsensitiveContains(self.search) }
                .sorted { ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending }
            if filtered.isEmpty { Text("Подарки не найдены").foregroundStyle(.secondary) }
            ForEach(filtered, id: \.id) { gift in
                Button {
                    self.select(gift.id)
                    self.dismiss()
                } label: {
                    HStack {
                        Text(gift.title ?? "").foregroundStyle(.primary)
                        Spacer()
                        if self.selected == gift.id { Image(systemName: "checkmark") }
                    }
                }
            }
        }
        .navigationTitle("Каталог Telegram")
        .searchable(text: self.$search, prompt: "Название подарка")
    }
}

@available(iOS 16.0, *)
private struct MoonTelegramNativePreview: UIViewRepresentable {
    let provider: MoonTelegramGiftProvider
    let gift: MoonGift
    func makeUIView(context: Context) -> UIView { self.provider.artwork(for: self.gift) }
    func updateUIView(_ view: UIView, context: Context) {
        view.accessibilityLabel = "\(self.gift.title), модель \(self.gift.modelName), оформление MoonGram"
    }
}
