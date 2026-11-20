import Foundation
import MoonGramCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@available(iOS 16.0, *)
struct MoonProfileEditor: View {
    @ObservedObject var model: MoonViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var profile: MoonProfile
    @State private var usernames: [MoonIdentityField]
    @State private var numbers: [MoonIdentityField]
    @State private var stars: String
    @State private var balance: String

    init(model: MoonViewModel) {
        self.model = model
        self._profile = State(initialValue: model.profile)
        self._usernames = State(initialValue: model.profile.usernames.map { MoonIdentityField(text: $0) })
        self._numbers = State(initialValue: model.profile.collectibleNumbers.map { MoonIdentityField(text: $0) })
        self._stars = State(initialValue: model.profile.stars.map(String.init) ?? "")
        self._balance = State(initialValue: model.profile.walletBalance?.text ?? "")
    }

    var body: some View {
        Form {
            Section("Профиль") {
                moonField("Имя", placeholder: "Имя из Telegram", value: self.$profile.displayName)
                Toggle("Внешний вид Premium", isOn: self.$profile.localPremium).tint(MoonAccent.control)
            }
            MoonIdentitySection(kind: .username, values: self.$usernames)
            MoonIdentitySection(kind: .number, values: self.$numbers)
            Section {
                moonField("Звёзды", placeholder: "Баланс Telegram", value: self.$stars).keyboardType(.numberPad)
                moonField("Кошелёк", placeholder: "Визуальный баланс", value: self.$balance).keyboardType(.decimalPad)
                moonField("Валюта", placeholder: "TON", value: self.$profile.walletCurrency).textInputAutocapitalization(.characters)
            } header: { Text("Визуальные балансы") } footer: {
                Text("Изменения относятся к оформлению. Операции используют фактический баланс Telegram.")
            }
        }
        .navigationTitle("Профиль и балансы")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .moonSaveAction(busy: self.model.busy, action: self.save)
    }

    private func save() {
        do {
            var profile = self.profile
            profile.setVisualIdentity(usernames: self.usernames.map(\.text), numbers: self.numbers.map(\.text))
            let stars = self.stars.trimmingCharacters(in: .whitespacesAndNewlines)
            if stars.isEmpty {
                profile.stars = nil
            } else {
                guard stars.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int64(stars) else {
                    throw MoonError.invalid("звёзды")
                }
                profile.stars = value
            }
            profile.walletBalance = self.balance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try MoonAmount(self.balance)
            if let amount = profile.walletBalance, amount.nanoUnits == nil { throw MoonError.invalid("баланс превышает диапазон кошелька Telegram") }
            try profile.validate()
            self.model.saveProfile(profile) { self.dismiss() }
        } catch { self.model.error = error.localizedDescription }
    }
}

private struct MoonIdentityField: Identifiable {
    let id = UUID()
    var text: String = ""
}

@available(iOS 16.0, *)
private struct MoonIdentitySection: View {
    enum Kind {
        case username, number

        var title: String { self == .username ? "Имена пользователя" : "Номера телефона" }
        var add: String { self == .username ? "Добавить юзернейм" : "Добавить номер" }
        var placeholder: String { self == .username ? "username" : "+888 0000 0000" }
        var symbol: String { self == .username ? "at" : "number" }
        var keyboard: UIKeyboardType { self == .username ? .asciiCapable : .phonePad }
    }

    let kind: Kind
    @Binding var values: [MoonIdentityField]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedID: UUID?

    var body: some View {
        Section(self.kind.title) {
            ForEach(self.$values) { $value in
                HStack(spacing: 10) {
                    Image(systemName: self.kind.symbol).foregroundStyle(MoonAccent.text).accessibilityHidden(true)
                    TextField(self.kind.placeholder, text: $value.text)
                        .font(.system(.body, design: .rounded))
                        .keyboardType(self.kind.keyboard)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel(self.kind.title)
                        .focused(self.$focusedID, equals: value.id)
                    Button {
                        let id = value.id
                        if self.focusedID == id { self.focusedID = nil }
                        withAnimation(self.reduceMotion ? nil : .easeOut(duration: 0.22)) {
                            self.values.removeAll { $0.id == id }
                        }
                    } label: {
                        Image(systemName: "minus.circle").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MoonAccent.text)
                    .accessibilityLabel("Удалить поле")
                }
                .padding(.leading, 12)
                .frame(minHeight: 46)
                .background(.background, in: RoundedRectangle(cornerRadius: 13))
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .strokeBorder(MoonAccent.control.opacity(self.focusedID == value.id ? 1 : 0.8))
                        .allowsHitTesting(false)
                }
                .listRowSeparator(.hidden)
            }
            Button {
                let row = MoonIdentityField()
                withAnimation(self.reduceMotion ? nil : .easeOut(duration: 0.22)) { self.values.append(row) }
                Task { @MainActor in self.focusedID = row.id }
            } label: {
                Label(self.kind.add, systemImage: "plus.circle").frame(minHeight: 44)
            }
        }
    }
}

@available(iOS 16.0, *)
private func moonField(_ title: String, placeholder: String, value: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        TextField(placeholder, text: value).font(.system(.body, design: .rounded)).accessibilityLabel(title)
    }
    .padding(.vertical, 4)
}

@available(iOS 16.0, *)
struct MoonPresetsView: View {
    @ObservedObject var model: MoonViewModel
    @State private var name = ""
    @State private var deleting: MoonPreset?

    var body: some View {
        List {
            Section {
                ForEach(self.model.settings?.presets ?? []) { preset in
                    HStack {
                        Button(preset.name) { self.model.mutate { $0.activePresetID = preset.id } }.foregroundStyle(.primary)
                        Spacer()
                        if self.model.settings?.activePresetID == preset.id {
                            Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Выбран")
                        }
                    }
                    .swipeActions {
                        if self.model.settings?.presets.count ?? 0 > 1 {
                            Button("Удалить", role: .destructive) { self.deleting = preset }
                        }
                    }
                }
            } footer: { Text("Выбор пресета не удаляет остальные оформления.") }
            Section("Новый пресет") {
                TextField("Название", text: self.$name)
                Button("Создать копию текущего") {
                    self.model.mutate {
                        guard $0.presets.count < 8 else { throw MoonError.invalid("не более 8 пресетов") }
                        let preset = MoonPreset(name: self.name, profile: $0.activeProfile)
                        $0.presets.append(preset)
                        $0.activePresetID = preset.id
                    } completion: { self.name = "" }
                }.disabled(self.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("Пресеты")
        .disabled(self.model.busy)
        .confirmationDialog("Удалить пресет?", isPresented: Binding(get: { self.deleting != nil }, set: { if !$0 { self.deleting = nil } }), titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                guard let id = self.deleting?.id else { return }
                self.model.mutate {
                    guard $0.presets.count > 1 else { throw MoonError.invalid("последний пресет") }
                    $0.presets.removeAll { $0.id == id }
                    if $0.activePresetID == id, let first = $0.presets.first { $0.activePresetID = first.id }
                }
                self.deleting = nil
            }
        }
    }
}

@available(iOS 16.0, *)
struct MoonGiftsView: View {
    @ObservedObject var model: MoonViewModel
    @State private var search = ""
    @State private var collection: String?

    var body: some View {
        List {
            if self.model.profile.gifts.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "gift").font(.largeTitle).accessibilityHidden(true)
                        Text("Подарков пока нет").font(.headline)
                        Text("Нажми плюс, чтобы выбрать подарок из каталога Telegram.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            }
            if self.collections.count > 1 {
                Picker("Коллекция", selection: self.$collection) {
                    Text("Все подарки").tag(String?.none)
                    ForEach(self.collections, id: \.self) { name in Text(name.isEmpty ? "Без коллекции" : name).tag(Optional(name)) }
                }
            }
            if !self.model.profile.gifts.isEmpty && self.visibleGifts.isEmpty {
                Section { Text("Подарки не найдены").foregroundStyle(.secondary) }
            }
            ForEach(Array(Set(self.visibleGifts.map(\.collection))).sorted(), id: \.self) { collection in
                Section(collection.isEmpty ? "Без коллекции" : collection) {
                    ForEach(self.visibleGifts.filter { $0.collection == collection }) { gift in
                        NavigationLink { MoonGiftEditor(model: self.model, gift: gift) } label: {
                            HStack(spacing: 12) {
                                MoonGiftArtwork(gift: gift, nativeGifts: self.model.nativeGifts).frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(gift.title).font(.headline)
                                    Text("#\(gift.number) · \(gift.modelName)").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .navigationTitle("Коллекции")
        .searchable(text: self.$search, prompt: "Название или номер")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { MoonGiftEditor(model: self.model, gift: MoonGift()) } label: {
                    Label("Добавить подарок", systemImage: "plus")
                }.disabled(self.model.profile.gifts.count >= 128)
            }
        }
        .onChange(of: self.collections) { names in
            if let selection = self.collection, !names.contains(selection) { self.collection = nil }
        }
    }

    private var visibleGifts: [MoonGift] {
        let query = self.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return self.model.profile.gifts.filter { gift in
            (self.collection == nil || self.collection == gift.collection) && (query.isEmpty ||
                [gift.title, gift.number, gift.modelName, gift.collection].contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    private var collections: [String] { Array(Set(self.model.profile.gifts.map(\.collection))).sorted() }
}

@available(iOS 16.0, *)
struct MoonGiftEditor: View {
    @ObservedObject var model: MoonViewModel
    @Environment(\.dismiss) private var dismiss
    @State var gift: MoonGift
    var focusTitleForQA = false
    @FocusState private var titleFocused: Bool
    @State private var importingArtwork = false
    @State private var confirmDelete = false
    @State private var choosingTelegramGift = false

    var body: some View {
        Form {
            if self.model.nativeGifts != nil {
                Section {
                    Button { self.choosingTelegramGift = true } label: {
                        Label(self.gift.telegram == nil ? "Выбрать из каталога Telegram" : "Изменить модель, фон и узор", systemImage: "gift")
                    }
                }

            }
            if self.showsDetails {
                Section {
                    MoonGiftArtwork(gift: self.gift, nativeGifts: self.model.nativeGifts).frame(height: 144).clipShape(RoundedRectangle(cornerRadius: 16))
                }
                Section("Коллекционный предмет") {
                    moonField("Название", placeholder: "Название подарка", value: self.$gift.title).focused(self.$titleFocused)
                    moonField("Номер", placeholder: "1", value: self.$gift.number)
                    moonField("Коллекция", placeholder: "Без коллекции", value: self.$gift.collection)
                    if self.gift.telegram == nil {
                        TextField("Название модели", text: self.$gift.modelName)
                        Picker("Модель", selection: self.$gift.model) {
                            ForEach(MoonModel.allCases, id: \.self) { model in Label(model.rawValue, systemImage: model.symbol).tag(model) }
                        }
                        Button("Загрузить свою модель") { self.importingArtwork = true }
                        if self.gift.artwork != nil { Button("Убрать изображение", role: .destructive) { self.gift.artwork = nil } }
                    } else {
                        LabeledContent("Модель", value: self.gift.modelName)
                    }
                }
                if self.gift.telegram == nil { Section {
                    Picker("Узор", selection: self.$gift.pattern) {
                        ForEach(MoonPattern.allCases, id: \.self) { pattern in Text(pattern.title).tag(pattern) }
                    }
                    ColorPicker("Фон", selection: Binding(get: { Color(moonHex: self.gift.backdrop) }, set: { self.gift.backdrop = $0.moonHex }), supportsOpacity: false)
                    ColorPicker("Цвет модели и узора", selection: Binding(get: { Color(moonHex: self.gift.symbolColor) }, set: { self.gift.symbolColor = $0.moonHex }), supportsOpacity: false)
                } header: { Text("Оформление") } footer: { Text("Это предмет оформления MoonGram. Выпуск NFT и операции с настоящими подарками здесь не выполняются.") } }
            }
            if self.model.profile.gifts.contains(where: { $0.id == self.gift.id }) {
                Section { Button("Удалить подарок", role: .destructive) { self.confirmDelete = true } }
            }
        }
        .navigationTitle(self.showsDetails ? self.gift.title : "Новый подарок")
        .navigationDestination(isPresented: self.$choosingTelegramGift) {
            if let provider = self.model.nativeGifts {
                provider.editor(for: self.gift) { selected in
                    self.gift = selected
                    self.choosingTelegramGift = false
                }
            }
        }
        .task {
            if self.focusTitleForQA { self.titleFocused = true }
        }
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .moonSaveAction(busy: self.model.busy, enabled: self.showsDetails) {
            var profile = self.model.profile
            if let index = profile.gifts.firstIndex(where: { $0.id == self.gift.id }) {
                profile.gifts[index] = self.gift
            } else {
                profile.gifts.append(self.gift)
            }
            self.model.saveProfile(profile) { self.dismiss() }
        }
        .fileImporter(isPresented: self.$importingArtwork, allowedContentTypes: [.png, .jpeg], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                self.gift.artwork = try MoonRaster.normalized(moonReadFile(url, maximumBytes: 8_388_608))
            } catch { self.model.error = error.localizedDescription }
        }
        .confirmationDialog("Удалить подарок?", isPresented: self.$confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                var profile = self.model.profile
                profile.gifts.removeAll { $0.id == self.gift.id }
                self.model.saveProfile(profile) { self.dismiss() }
            }
        }
    }

    private var showsDetails: Bool {
        self.gift.telegram != nil || self.model.nativeGifts == nil || self.model.profile.gifts.contains { $0.id == self.gift.id }
    }
}
