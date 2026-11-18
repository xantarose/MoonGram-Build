import Foundation
import MoonGramCore
import Security
import SwiftUI

private enum MoonKeychain {
    private static func query(accountID: Int64) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "org.moongram.sync",
         kSecAttrAccount as String: String(accountID)]
    }

    static func token(accountID: Int64) -> String {
        var query = self.query(accountID: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ token: String, accountID: Int64) throws {
        let query = self.query(accountID: accountID)
        let values: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            for (key, value) in values { item[key] = value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw MoonError.invalid("сохранение токена в Keychain") }
        } else if status != errSecSuccess { throw MoonError.invalid("доступ к Keychain") }
    }
}

private final class MoonNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct MoonSyncClient: Sendable {
    let baseURL: URL
    let token: String

    init(address: String, token: String) throws {
        guard let components = URLComponents(string: address), components.scheme == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/", let url = components.url else {
            throw MoonError.invalid("HTTPS-адрес сервиса без пути, логина и параметров")
        }
        guard token.count == 64, token.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }) else {
            throw MoonError.invalid("токен приглашения")
        }
        self.baseURL = url
        self.token = token
    }

    func fetch(peerID: Int64) async throws -> (MoonArchive, String?)? {
        let (data, response) = try await self.request(method: "GET", peerID: peerID)
        if response.statusCode == 404 { return nil }
        try self.check(response)
        return (try MoonArchive.decode(data), response.value(forHTTPHeaderField: "ETag"))
    }

    func publish(accountID: Int64, profile: MoonProfile) async throws {
        let existing = try await self.fetch(peerID: accountID)
        var headers = ["Content-Type": "application/json"]
        if let etag = existing?.1 { headers["If-Match"] = etag }
        else { headers["If-None-Match"] = "*" }
        let (_, response) = try await self.request(method: "PUT", peerID: accountID,
                                                   data: MoonArchive(profile: profile).encoded(), headers: headers)
        try self.check(response)
    }

    func unpublish(accountID: Int64) async throws {
        let (_, response) = try await self.request(method: "DELETE", peerID: accountID)
        try self.check(response)
    }

    private func request(method: String, peerID: Int64, data: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard peerID > 0 else { throw MoonError.invalid("ID аккаунта") }
        var request = URLRequest(url: self.baseURL.appendingPathComponent("v1/profiles/\(peerID)"))
        request.httpMethod = method
        request.httpBody = data
        request.timeoutInterval = 20
        request.setValue("Bearer \(self.token)", forHTTPHeaderField: "Authorization")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: MoonNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse else { throw MoonError.invalid("ответ сервиса") }
        guard response.expectedContentLength <= Int64(MoonArchive.maximumBytes) else { throw MoonError.tooLarge }
        var result = Data()
        for try await byte in bytes {
            guard result.count < MoonArchive.maximumBytes else { throw MoonError.tooLarge }
            result.append(byte)
        }
        return (result, response)
    }

    private func check(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200...299: return
        case 401, 403: throw MoonError.invalid("приглашение или привязка к вашему Telegram ID")
        case 412: throw MoonError.invalid("оформление изменилось; повторите публикацию")
        case 413: throw MoonError.tooLarge
        case 429: throw MoonError.invalid("слишком много запросов; подождите минуту")
        default: throw MoonError.invalid("сервис вернул HTTP \(response.statusCode)")
        }
    }
}

private actor MoonRefreshGate {
    static let shared = MoonRefreshGate()
    private var refreshed: [String: Date] = [:]

    func claim(accountID: Int64, peerID: Int64) -> Bool {
        let key = "\(accountID):\(peerID)"
        let now = Date()
        if let previous = self.refreshed[key], now.timeIntervalSince(previous) < 60 { return false }
        if self.refreshed.count >= 256 { self.refreshed = self.refreshed.filter { now.timeIntervalSince($0.value) < 60 } }
        guard self.refreshed.count < 256 else { return false }
        self.refreshed[key] = now
        return true
    }
}

/// Refresh only the opened profile. Failure preserves the bounded local cache for offline use.
@available(iOS 16.0, *)
public func moonRefreshFriendProfile(accountID: Int64, peerID: Int64) {
    guard accountID != peerID, peerID > 0,
          let settings = try? MoonStore.shared.settings(accountID: accountID), settings.enabled, settings.showFriends,
          let address = UserDefaults.standard.string(forKey: "MoonGram.syncURL.\(accountID)"),
          let client = try? MoonSyncClient(address: address, token: MoonKeychain.token(accountID: accountID)) else { return }
    Task {
        guard await MoonRefreshGate.shared.claim(accountID: accountID, peerID: peerID) else { return }
        do {
            let fetched = try await client.fetch(peerID: peerID)
            try await Task.detached(priority: .utility) {
                if let archive = fetched?.0 { try MoonStore.shared.importFriend(archive, accountID: accountID, peerID: peerID, synced: true) }
                else { try MoonStore.shared.removeFriend(accountID: accountID, peerID: peerID, synced: true) }
            }.value
        } catch {
            // No Telegram operations or cache deletion on an unavailable profile service.
        }
    }
}

@available(iOS 16.0, *)
@MainActor
final class MoonAutoPublish: ObservableObject {
    static let shared = MoonAutoPublish()
    @Published private(set) var status: [Int64: String] = [:]
    private var pending: Set<Int64> = []
    private var active: Set<Int64> = []

    func schedule(accountID: Int64) {
        self.pending.insert(accountID)
        guard self.active.insert(accountID).inserted else { return }
        Task { @MainActor in
            defer { self.active.remove(accountID) }
            while self.pending.remove(accountID) != nil {
                await self.publish(accountID: accountID)
            }
        }
    }

    private func publish(accountID: Int64) async {
        guard let settings = try? MoonStore.shared.settings(accountID: accountID), settings.autoPublishStyle == true else {
            self.status[accountID] = nil
            return
        }
        guard let address = UserDefaults.standard.string(forKey: "MoonGram.syncURL.\(accountID)"),
              let client = try? MoonSyncClient(address: address, token: MoonKeychain.token(accountID: accountID)) else {
            self.status[accountID] = "Сохрани адрес и приглашение для обмена."
            return
        }
        self.status[accountID] = "Обновляю оформление для друзей…"
        do {
            try await client.publish(accountID: accountID, profile: settings.activeProfile.shared(includingBalances: false))
            self.status[accountID] = "Оформление обновлено."
        } catch {
            self.status[accountID] = "Сейчас обновить оформление не удалось. Сохранившиеся данные можно опубликовать вручную."
        }
    }
}

@available(iOS 16.0, *)
struct MoonSyncView: View {
    @ObservedObject var model: MoonViewModel
    @ObservedObject private var autoPublish = MoonAutoPublish.shared
    @State private var address = ""
    @State private var token = ""
    @State private var friendID = ""
    @State private var includeBalances = false
    @State private var working = false
    @State private var status = ""
    @State private var confirmUnpublish = false

    var body: some View {
        Form {
            Section {
                Text("Мой Telegram ID: \(self.model.accountID)").textSelection(.enabled)
                TextField("https://адрес-сервиса", text: self.$address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Токен приглашения", text: self.$token).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Сохранить подключение") {
                    do {
                        _ = try self.client()
                        try MoonKeychain.save(self.token, accountID: self.model.accountID)
                        UserDefaults.standard.set(self.address, forKey: "MoonGram.syncURL.\(self.model.accountID)")
                        self.status = "Подключение сохранено."
                        if self.model.settings?.autoPublishStyle == true {
                            self.autoPublish.schedule(accountID: self.model.accountID)
                        }
                    } catch { self.model.error = error.localizedDescription }
                }
            } header: { Text("Подключение") } footer: { Text("Приглашение выдаёт владелец вашего сервиса. Токен хранится в Keychain и не входит в экспорт оформления.") }
            Section {
                Toggle("Автоматически обновлять оформление", isOn: Binding(get: {
                    self.model.settings?.autoPublishStyle == true
                }, set: { enabled in
                    self.model.mutate { $0.autoPublishStyle = enabled }
                })).tint(MoonAccent.control)
                if let status = self.autoPublish.status[self.model.accountID] { Text(status).foregroundStyle(.secondary) }
                Toggle("Публиковать балансы вручную", isOn: self.$includeBalances).tint(MoonAccent.control)
                Button("Опубликовать текущее оформление") {
                    self.perform {
                        try await self.client().publish(accountID: self.model.accountID, profile: self.model.profile.shared(includingBalances: self.includeBalances))
                        return "Оформление опубликовано."
                    }
                }
                Button("Снять публикацию", role: .destructive) { self.confirmUnpublish = true }
            } header: { Text("Моя публикация") } footer: { Text("Автоматическая публикация обновляет оформление при смене пресета или его редактировании. Только ручная публикация может включать балансы. Выключатель визуалов действует на этом устройстве. Публикация снимается отдельно. Уже импортированная другом копия хранится на его устройстве до обновления или удаления.") }
            Section("Получить оформление друга") {
                TextField("Telegram ID друга", text: self.$friendID).keyboardType(.numberPad)
                Button("Обновить оформление") {
                    self.perform {
                        guard let id = Int64(self.friendID), id > 0, id != self.model.accountID else { throw MoonError.invalid("ID друга") }
                        guard let (archive, _) = try await self.client().fetch(peerID: id) else {
                            try self.model.store.removeFriend(accountID: self.model.accountID, peerID: id, synced: true)
                            return "Публикации нет. Сохранённая копия удалена."
                        }
                        try self.model.store.importFriend(archive, accountID: self.model.accountID, peerID: id, synced: true)
                        return "Оформление друга обновлено."
                    }
                }
            }
            if self.working { ProgressView("Обмен оформлением…") }
            if !self.status.isEmpty { Section { Text(self.status).foregroundStyle(.secondary) } }
        }
        .navigationTitle("Синхронизация")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(self.working)
        .onAppear {
            self.address = UserDefaults.standard.string(forKey: "MoonGram.syncURL.\(self.model.accountID)") ?? ""
            self.token = MoonKeychain.token(accountID: self.model.accountID)
        }
        .confirmationDialog("Снять опубликованное оформление?", isPresented: self.$confirmUnpublish, titleVisibility: .visible) {
            Button("Снять публикацию", role: .destructive) {
                self.perform { try await self.client().unpublish(accountID: self.model.accountID); return "Публикация снята. Локальный пресет сохранён." }
            }
        }
    }

    private func client() throws -> MoonSyncClient { try MoonSyncClient(address: self.address, token: self.token) }

    private func perform(_ action: @escaping @MainActor () async throws -> String) {
        self.working = true
        self.status = ""
        Task { @MainActor in
            do { self.status = try await action() }
            catch { self.model.error = error.localizedDescription }
            self.working = false
        }
    }
}
