import Foundation

// MARK: - 追剧 / 进度状态

/// 持久化的追剧与观看进度。
///
/// 存到远端时只带必要字段：drama 的完整结构里 description / cover 都是长文本，
/// 几百条累加起来会顶到 iCloud KVS 与 UserDefaults 的体积上限。
struct PersistedState: Codable, Equatable {
    var follows: [FollowedDrama] = []
    var progress: [WatchProgress] = []
    /// 状态版本号，便于以后做结构升级。
    var version: Int = 1
    /// 最近一次写入时间，用于判断远端副本是否更新。
    var updatedAt: Date = Date()
}

/// 存储后端：追剧与进度的读写落点。
///
/// tvOS 真机上只有 Caches 与 tmp 可写，系统在空间不足（以及应用不运行时）
/// 会清理 Caches，所以本地副本并不可靠。远端后端把状态写到 NAS，
/// 应用每次启动都能拉回来。
///
/// Swift 6 严格并发下，后端会被跨隔离域传递（后台同步任务、设置页测试连接），
/// 因此协议要求 Sendable；实现类用 actor 隔离可变状态（连接句柄）。
protocol StorageBackend: AnyObject, Sendable {
    /// 后端标识，用于界面显示。
    var displayName: String { get }
    /// 读取状态；没有数据时返回 nil（不当作错误）。
    func load() async throws -> PersistedState?
    /// 写入状态。
    func save(_ state: PersistedState) async throws
}

// MARK: - 本地后端

/// 本地后端：写在 Caches 里的 JSON 文件。
///
/// 这是 tvOS 上唯一能免 entitlement 的可用位置，代价是系统可能清理。
/// 即使配了远端后端，也保留这份本地副本作为离线兜底。
final class LocalStorageBackend: StorageBackend, @unchecked Sendable {
    let displayName = "本地缓存"

    private let file: URL

    init(fileName: String = "tv-state.json") {
        // tvOS 真机上 Documents / Application Support 只读，只有 Caches 与 tmp 可写。
        let directory = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        file = directory.appendingPathComponent(fileName)
    }

    func load() async throws -> PersistedState? {
        loadSync()
    }

    /// 同步读取：本地文件读写不需要异步，供启动时的初始化使用。
    func loadSync() -> PersistedState? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    func save(_ state: PersistedState) async throws {
        try saveSync(state)
    }

    /// 同步写入：本地文件写入不需要异步。
    func saveSync(_ state: PersistedState) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: file, options: .atomic)
    }
}

// MARK: - 配置

/// 远端存储的连接配置。
///
/// 密码不放在这里：存 UserDefaults 不安全，密码另存 Keychain（见 KeychainStore）。
struct StorageSettings: Codable, Equatable {
    /// 使用的后端类型。
    enum Kind: String, Codable, CaseIterable {
        case local
        case smb
        case webdav

        var displayName: String {
            switch self {
            case .local: return "仅本机缓存"
            case .smb: return "SMB 共享（NAS）"
            case .webdav: return "WebDAV 备份"
            }
        }

        var detail: String {
            switch self {
            case .local: return "追剧与进度存本机，系统清理后可能丢失"
            case .smb: return "直接读写 NAS 上的共享目录，断网时不可用"
            case .webdav: return "把状态备份到 NAS，保留本机副本"
            }
        }
    }

    var kind: Kind = .local
    /// SMB：服务器地址，例如 192.168.2.99。
    var smbHost: String = ""
    /// SMB：共享名，例如 backup。
    var smbShare: String = ""
    /// SMB：目录（相对共享根），留空表示共享根。
    var smbDirectory: String = ""
    /// SMB：用户名。
    var smbUsername: String = ""
    /// SMB：域（群晖一般留空）。
    var smbDomain: String = ""
    /// SMB：端口，默认 445。
    var smbPort: Int = 445

    /// WebDAV：完整地址，例如 https://192.168.2.99:6690/backup
    var webdavURL: String = ""
    /// WebDAV：用户名。
    var webdavUsername: String = ""
    /// WebDAV：保存状态的文件名。
    var webdavFileName: String = "tv-state.json"

    /// 该配置下可用的存储文件地址描述（界面显示用）。
    var locationSummary: String {
        switch kind {
        case .local:
            return "本机 Caches"
        case .smb:
            let directory = smbDirectory.isEmpty ? "" : "/" + smbDirectory
            return "smb://\(smbHost)/\(smbShare)\(directory)"
        case .webdav:
            let base = webdavURL.hasSuffix("/") ? String(webdavURL.dropLast()) : webdavURL
            return "\(base)/\(webdavFileName)"
        }
    }
}

// MARK: - 配置存取

/// 存储配置的读写：配置本身放 UserDefaults，密码放 Keychain。
///
/// tvOS 上 NSUserDefaults 是唯一被官方认可的持久化位置（上限 500 KB），
/// 配置体积很小，放得下。
final class StorageSettingsStore {
    private static let settingsKey = "storageSettings"

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    var settings: StorageSettings {
        get {
            guard let data = defaults.data(forKey: Self.settingsKey),
                  let value = try? JSONDecoder().decode(StorageSettings.self, from: data) else {
                return StorageSettings()
            }
            return value
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Self.settingsKey)
        }
    }

    /// SMB 密码（Keychain）。
    func smbPassword() -> String {
        keychain.read(account: "smb") ?? ""
    }

    func setSMBPassword(_ password: String) {
        if password.isEmpty {
            keychain.delete(account: "smb")
        } else {
            keychain.write(password, account: "smb")
        }
    }

    /// WebDAV 密码（Keychain）。
    func webdavPassword() -> String {
        keychain.read(account: "webdav") ?? ""
    }

    func setWebDAVPassword(_ password: String) {
        if password.isEmpty {
            keychain.delete(account: "webdav")
        } else {
            keychain.write(password, account: "webdav")
        }
    }
}

// MARK: - Keychain

/// Keychain 读写：密码等敏感数据放这里，tvOS 上是持久的。
final class KeychainStore {
    private let service: String

    init(service: String = "com.duanju.guoapp.tv.storage") {
        self.service = service
    }

    func write(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
