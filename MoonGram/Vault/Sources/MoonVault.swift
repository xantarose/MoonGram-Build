import CryptoKit
import Foundation
import MoonGramCore
import Security

public enum MoonVaultKind: String, Codable, Sendable { case text, photo, video }

public struct MoonVaultDeletion: Sendable {
    public let peerID: Int64?
    public let messageID: Int32
    public init(peerID: Int64?, messageID: Int32) { self.peerID = peerID; self.messageID = messageID }
}

private final class MoonPinnedFile: @unchecked Sendable {
    let handle: FileHandle
    init(path: String) throws { self.handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)) }
    deinit { try? self.handle.close() }
}

public struct MoonVaultEntry: Codable, Identifiable, Sendable {
    public var id: String
    public var peerID: Int64
    public var namespace: Int32
    public var messageID: Int32
    public var timestamp: Int32
    public var text: String
    public var kind: MoonVaultKind
    public var deleted: Bool
    public var mediaFile: String?

    public init(peerID: Int64, namespace: Int32, messageID: Int32, timestamp: Int32, text: String,
                kind: MoonVaultKind = .text) {
        self.id = "\(peerID):\(namespace):\(messageID)"
        self.peerID = peerID
        self.namespace = namespace
        self.messageID = messageID
        self.timestamp = timestamp
        self.text = text
        self.kind = kind
        self.deleted = false
        self.mediaFile = nil
    }
}

public enum MoonVaultError: Error, LocalizedError {
    case full, tooLarge, unavailable, invalidFile
    public var errorDescription: String? {
        switch self {
        case .full: return "Хранилище заполнено. Удалите ненужные копии."
        case .tooLarge: return "Для эксперимента поддерживаются медиа до 64 МиБ."
        case .unavailable: return "Ключ хранилища недоступен. Разблокируйте устройство."
        case .invalidFile: return "Копия повреждена или ресурс уже недоступен."
        }
    }
}

/// Apple-only encrypted local vault. No data here is part of cosmetic export or sync.
public final class MoonVault: @unchecked Sendable {
    public static let shared = MoonVault()
    private let queue = DispatchQueue(label: "org.moongram.vault", qos: .utility)
    private let directory: URL
    private var seenText: Set<String> = []
    private var deletions: [Int64: Set<String>] = [:]
    private var errors: [Int64: String] = [:]
    private let maximumMediaBytes = 67_108_864
    private let maximumAccountBytes = 1_073_741_824

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        self.directory = support.appendingPathComponent("MoonGramVault", isDirectory: true)
        // Temporary decrypted previews from a previous process never survive the next vault launch.
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("MoonGramVaultPreview", isDirectory: true))
    }

    public func capture(_ entry: MoonVaultEntry, accountID: Int64, mediaPath: String? = nil) {
        let media = mediaPath != nil
        guard self.allowed(accountID: accountID, peerID: entry.peerID, media: media), entry.text.utf8.count <= 65_536 else { return }
        let pinned: MoonPinnedFile?
        do { pinned = try mediaPath.map { try MoonPinnedFile(path: $0) } }
        catch { self.queue.async { self.errors[accountID] = MoonVaultError.invalidFile.localizedDescription }; return }
        self.queue.async {
            guard self.allowed(accountID: accountID, peerID: entry.peerID, media: media) else { return }
            do {
                let key = try self.key(accountID: accountID)
                let name = self.fileName(entry.id)
                let root = self.accountDirectory(accountID)
                let file = root.appendingPathComponent(name + ".mgv")
                let seenKey = "\(accountID):\(name)"
                if !media, self.seenText.contains(seenKey) { return }
                var value = entry
                let existed = FileManager.default.fileExists(atPath: file.path)
                if existed {
                    let old = try self.readEntry(file, accountID: accountID, key: key)
                    if !media { self.seenText.insert(seenKey); return }
                    if old.mediaFile != nil { return }
                    value.deleted = old.deleted
                    value.text = old.text
                }
                if self.deletions[accountID]?.contains("0:\(entry.messageID)") == true ||
                    self.deletions[accountID]?.contains("\(entry.peerID):\(entry.messageID)") == true { value.deleted = true }
                var writtenMedia: URL?
                do {
                    if let pinned = pinned {
                        let end = try pinned.handle.seekToEnd()
                        guard end <= UInt64(self.maximumMediaBytes) else { throw MoonVaultError.tooLarge }
                        let size = Int(end)
                        try pinned.handle.seek(toOffset: 0)
                        try self.capacity(accountID: accountID, additional: size + 524_288, replacingEntry: existed)
                        guard let data = try pinned.handle.read(upToCount: self.maximumMediaBytes + 1), data.count == size else { throw MoonVaultError.invalidFile }
                        guard self.allowed(accountID: accountID, peerID: entry.peerID, media: true) else { return }
                        let mediaName = name + ".media"
                        let mediaURL = root.appendingPathComponent(mediaName)
                        try self.writeEncrypted(data, to: mediaURL, accountID: accountID, key: key)
                        writtenMedia = mediaURL
                        value.mediaFile = mediaName
                    } else {
                        try self.capacity(accountID: accountID, additional: 524_288, replacingEntry: existed)
                    }
                    let encoded = try JSONEncoder().encode(value)
                    guard encoded.count <= 524_200 else { throw MoonVaultError.tooLarge }
                    try self.writeEncrypted(encoded, to: file, accountID: accountID, key: key)
                    self.seenText.insert(seenKey)
                    if self.seenText.count > 4096 { self.seenText.removeAll(keepingCapacity: true) }
                } catch {
                    if let writtenMedia = writtenMedia { try? FileManager.default.removeItem(at: writtenMedia) }
                    throw error
                }
            } catch { self.errors[accountID] = error.localizedDescription }
        }
    }

    public func markDeleted(accountID: Int64, ids: [MoonVaultDeletion]) {
        self.queue.async {
            do {
                var deleted = self.deletions[accountID] ?? []
                if deleted.count + ids.count > 4096 { deleted.removeAll(keepingCapacity: true) }
                for id in ids.prefix(4096) { deleted.insert("\(id.peerID ?? 0):\(id.messageID)") }
                self.deletions[accountID] = deleted
                let files = try self.entryFiles(accountID: accountID)
                if files.isEmpty { return }
                let key = try self.key(accountID: accountID)
                for file in files {
                    var entry = try self.readEntry(file, accountID: accountID, key: key)
                    if !entry.deleted && (deleted.contains("0:\(entry.messageID)") || deleted.contains("\(entry.peerID):\(entry.messageID)")) {
                        entry.deleted = true
                        try self.writeEncrypted(JSONEncoder().encode(entry), to: file, accountID: accountID, key: key)
                    }
                }
            } catch { self.errors[accountID] = error.localizedDescription }
        }
    }

    public func entries(accountID: Int64, completion: @escaping ([MoonVaultEntry], String?) -> Void) {
        self.queue.async {
            do {
                let files = try self.entryFiles(accountID: accountID)
                if files.isEmpty {
                    let error = self.errors[accountID]
                    DispatchQueue.main.async { completion([], error) }
                    return
                }
                let key = try self.key(accountID: accountID)
                let entries = try files.map { try self.readEntry($0, accountID: accountID, key: key) }.sorted { $0.timestamp > $1.timestamp }
                let error = self.errors[accountID]
                DispatchQueue.main.async { completion(entries, error) }
            } catch { DispatchQueue.main.async { completion([], error.localizedDescription) } }
        }
    }

    public func preview(accountID: Int64, entry: MoonVaultEntry, completion: @escaping (Result<URL, Error>) -> Void) {
        self.queue.async {
            do {
                guard let name = entry.mediaFile, name == self.fileName(entry.id) + ".media" else { throw MoonVaultError.invalidFile }
                let source = self.accountDirectory(accountID).appendingPathComponent(name)
                let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= self.maximumMediaBytes + 1024 else { throw MoonVaultError.tooLarge }
                let key = try self.key(accountID: accountID)
                let data = try self.open(Data(contentsOf: source), name: name, accountID: accountID, key: key)
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoonGramVaultPreview", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let output = root.appendingPathComponent(UUID().uuidString + (entry.kind == .video ? ".mp4" : ".jpg"))
                #if os(iOS)
                try data.write(to: output, options: [.atomic, .completeFileProtection])
                #else
                try data.write(to: output, options: .atomic)
                #endif
                do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path) }
                catch { try? FileManager.default.removeItem(at: output); throw error }
                DispatchQueue.main.async { completion(.success(output)) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    public func delete(accountID: Int64, entry: MoonVaultEntry, completion: @escaping (Error?) -> Void) {
        self.queue.async {
            do {
                let base = self.fileName(entry.id)
                for suffix in [".mgv", ".media"] {
                    let file = self.accountDirectory(accountID).appendingPathComponent(base + suffix)
                    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                }
                self.seenText.remove("\(accountID):\(base)")
                DispatchQueue.main.async { completion(nil) }
            } catch { DispatchQueue.main.async { completion(error) } }
        }
    }

    private func allowed(accountID: Int64, peerID: Int64, media: Bool) -> Bool {
        (try? MoonStore.shared.settings(accountID: accountID).experiments)?.allows(peerID: peerID, media: media) == true
    }

    private func fileName(_ id: String) -> String { SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func accountDirectory(_ accountID: Int64) -> URL { self.directory.appendingPathComponent(String(accountID), isDirectory: true) }

    private func entryFiles(accountID: Int64) throws -> [URL] {
        let root = self.accountDirectory(accountID)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "mgv" }.prefix(500).map { $0 }
    }

    private func capacity(accountID: Int64, additional: Int, replacingEntry: Bool) throws {
        let root = self.accountDirectory(accountID)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        guard replacingEntry || files.filter({ $0.pathExtension == "mgv" }).count < 500 else { throw MoonVaultError.full }
        let bytes = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        guard bytes + additional <= self.maximumAccountBytes else { throw MoonVaultError.full }
    }

    private func key(accountID: Int64) throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "org.moongram.vault",
                                   kSecAttrAccount as String: String(accountID)]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        let key: SymmetricKey
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { key = SymmetricKey(data: data) }
        else if status == errSecItemNotFound {
            guard try self.entryFiles(accountID: accountID).isEmpty else { throw MoonVaultError.unavailable }
            key = SymmetricKey(size: .bits256)
            var write = query
            write[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
            write[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(write as CFDictionary, nil) == errSecSuccess else { throw MoonVaultError.unavailable }
        } else { throw MoonVaultError.unavailable }
        return key
    }

    private func writeEncrypted(_ data: Data, to url: URL, accountID: Int64, key: SymmetricKey) throws {
        let aad = Data("\(accountID)|\(url.lastPathComponent)".utf8)
        guard let combined = try AES.GCM.seal(data, using: key, authenticating: aad).combined else { throw MoonVaultError.invalidFile }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var vaultDirectory = self.directory
        try vaultDirectory.setResourceValues(excluded)
        #if os(iOS)
        try combined.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try combined.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var excludedFile = url
        try excludedFile.setResourceValues(excluded)
    }

    private func open(_ data: Data, name: String, accountID: Int64, key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data("\(accountID)|\(name)".utf8))
    }

    private func readEntry(_ url: URL, accountID: Int64, key: SymmetricKey) throws -> MoonVaultEntry {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 524_288 else { throw MoonVaultError.tooLarge }
        let data = try self.open(Data(contentsOf: url), name: url.lastPathComponent, accountID: accountID, key: key)
        return try JSONDecoder().decode(MoonVaultEntry.self, from: data)
    }
}
