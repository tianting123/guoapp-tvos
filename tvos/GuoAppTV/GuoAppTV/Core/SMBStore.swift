import Foundation

/// SMB 存储后端：把追剧与进度直接写到 NAS 的 SMB 共享。
///
/// tvOS 上没有系统级 SMB 挂载，这里用自己的 SMB2 客户端直连，
/// 读写共享目录里的一个 JSON 文件。
final class SMBStore: StorageBackend {
    let displayName = "SMB 共享"

    private let host: String
    private let port: Int
    private let share: String
    private let directory: String
    private let username: String
    private let password: String
    private let domain: String
    private let fileName: String

    private var client: SMB2Client?

    init(
        host: String,
        port: Int = 445,
        share: String,
        directory: String = "",
        username: String,
        password: String,
        domain: String = "",
        fileName: String = "tv-state.json"
    ) {
        self.host = host
        self.port = port
        self.share = share
        self.directory = directory
        self.username = username
        self.password = password
        self.domain = domain
        self.fileName = fileName
    }

    /// 共享内的文件路径。
    private var remotePath: String {
        var path = "\\" + fileName
        let trimmed = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        if !trimmed.isEmpty {
            path = "\\" + trimmed + path
        }
        return path
    }

    // MARK: - StorageBackend

    func load() async throws -> PersistedState? {
        let client = try await connectedClient()
        let fileId: UInt64
        do {
            fileId = try await client.openFile(remotePath, forWriting: false)
        } catch SMBError.fileNotFound {
            // 远端还没有文件：首次使用，不是错误。
            return nil
        }
        defer { Task { try? await client.closeFile(fileId) } }
        let data = try await client.readFile(fileId, length: 1024 * 1024)
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    func save(_ state: PersistedState) async throws {
        let client = try await connectedClient()
        let fileId = try await client.openFile(remotePath, forWriting: true)
        defer { Task { try? await client.closeFile(fileId) } }
        let data = try JSONEncoder().encode(state)
        try await client.writeFile(fileId, data: data)
    }

    /// 测试连接：连上服务器、认证、连共享，并试写一个临时文件确认可写。
    func probe() async throws -> Bool {
        let client = try await connectedClient()
        // 真写一次才算数：只认证成功不代表共享可写。
        let probePath = remotePath + ".probe"
        let fileId = try await client.openFile(probePath, forWriting: true)
        defer { Task { try? await client.closeFile(fileId) } }
        try await client.writeFile(fileId, data: Data("ok".utf8))
        return true
    }

    // MARK: - 连接管理

    /// 拿到可用的连接（复用已有会话）。
    private func connectedClient() async throws -> SMB2Client {
        if let client {
            return client
        }
        let client = SMB2Client(
            host: host,
            port: port,
            username: username,
            password: password,
            domain: domain
        )
        try await client.connect()
        try await client.connectShare(share)
        self.client = client
        return client
    }

    /// 断开连接（切换配置或退出时调用）。
    func disconnect() {
        client?.disconnect()
        client = nil
    }
}
