import Foundation

/// WebDAV 客户端：把状态文件写到 NAS 的 WebDAV 目录（群晖 Cloud Sync 的 6690 端口）。
///
/// 认证支持 Basic 与 Digest —— 群晖的 WebDAV 默认走 Digest，老一些的配置是 Basic，
/// 两种都试一次，先成功哪个用哪个。
final class WebDAVStore: StorageBackend {
    let displayName = "WebDAV 备份"

    private let baseURL: URL
    private let fileName: String
    private let username: String
    private let password: String
    private let session: URLSession

    /// Digest 认证用：保存服务端给的 nonce 与 realm。
    private var digestState = DigestState()

    /// Digest 认证的会话参数。
    private struct DigestState {
        var nonce = ""
        var realm = ""
        var qop = ""
        var opaque: String?
        /// 请求 URI：Digest 响应要用。
        var uri = ""
    }

    init(baseURL: URL, fileName: String, username: String, password: String) {
        self.baseURL = baseURL
        self.fileName = fileName
        self.username = username
        self.password = password
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// 状态文件地址。
    private var fileURL: URL {
        baseURL.appendingPathComponent(fileName)
    }

    // MARK: - StorageBackend

    func load() async throws -> PersistedState? {
        var request = URLRequest(url: fileURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request, authenticated: false)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.invalidResponse
        }
        if http.statusCode == 404 {
            // 远端还没有文件：不是错误，由调用方按「首次使用」处理。
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WebDAVError.httpStatus(http.statusCode)
        }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    func save(_ state: PersistedState) async throws {
        let data = try JSONEncoder().encode(state)
        // 先确保目录存在（WebDAV 需要显式建目录），失败不致命：
        // 很多服务端允许直接 PUT 到已有目录。
        try? await ensureCollection()
        var request = URLRequest(url: fileURL)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (_, response) = try await send(request, authenticated: false)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WebDAVError.httpStatus(http.statusCode)
        }
    }

    /// 测试连接：PROPFIND 探测目录是否可读。
    func probe() async throws -> Bool {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await send(request, authenticated: false)
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: - 目录

    private func ensureCollection() async throws {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "MKCOL"
        let (_, response) = try await send(request, authenticated: false)
        guard let http = response as? HTTPURLResponse else { return }
        // 405 = 已存在，属于正常情况。
        if !(200..<300).contains(http.statusCode), http.statusCode != 405 {
            throw WebDAVError.httpStatus(http.statusCode)
        }
    }

    // MARK: - 请求与认证

    /// 发请求并处理 401：先用 Basic，被拒再用 Digest 重试。
    private func send(_ request: URLRequest, authenticated: Bool) async throws -> (Data, URLResponse) {
        var signed = request
        applyAuthorization(to: &signed)
        let (data, response) = try await session.data(for: signed)
        if let http = response as? HTTPURLResponse, http.statusCode == 401, !authenticated {
            // 服务端可能在 401 的 WWW-Authenticate 里给出 Digest 参数，解析后重试。
            if let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate") {
                applyDigestChallenge(challenge)
            }
            return try await send(request, authenticated: true)
        }
        return (data, response)
    }

    private func applyAuthorization(to request: inout URLRequest) {
        guard !username.isEmpty else { return }
        if !digestState.nonce.isEmpty {
            request.setValue(digestHeader(method: request.httpMethod ?? "GET"), forHTTPHeaderField: "Authorization")
        } else {
            let credential = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        }
    }

    /// 解析 WWW-Authenticate 里的 Digest 参数。
    private func applyDigestChallenge(_ challenge: String) {
        guard challenge.lowercased().contains("digest") else { return }
        let parameters = parseDigestParameters(challenge)
        digestState.nonce = parameters["nonce"] ?? ""
        digestState.realm = parameters["realm"] ?? ""
        digestState.qop = parameters["qop"] ?? ""
        digestState.opaque = parameters["opaque"]
        digestState.uri = parameters["uri"] ?? ""
    }

    /// 组装 Digest 响应头。
    private func digestHeader(method: String) -> String {
        let ha1 = MD5.hex("\(username):\(digestState.realm):\(password)")
        let ha2 = MD5.hex("\(method):\(digestState.uri)")
        let nonce = digestState.nonce
        let nc = "00000001"
        let cnonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        var response: String
        if digestState.qop.isEmpty {
            response = MD5.hex("\(ha1):\(nonce):\(ha2)")
        } else {
            response = MD5.hex("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
        }
        var header = "Digest username=\"\(username)\", realm=\"\(digestState.realm)\", nonce=\"\(nonce)\", uri=\"\(digestState.uri)\""
        if !digestState.qop.isEmpty {
            header += ", qop=auth, nc=\(nc), cnonce=\"\(cnonce)\""
        }
        header += ", response=\"\(response)\""
        if let opaque = digestState.opaque {
            header += ", opaque=\"\(opaque)\""
        }
        return header
    }

    /// 解析 Digest 头里的 key=value 列表。
    private func parseDigestParameters(_ challenge: String) -> [String: String] {
        var result: [String: String] = [:]
        let lowercased = challenge.lowercased()
        guard let range = lowercased.range(of: "digest") else { return result }
        let body = challenge[range.upperBound...]
        var current = ""
        var quoted = false
        var pieces: [String] = []
        for character in body {
            if character == "\"" {
                quoted.toggle()
            }
            if character == "," && !quoted {
                pieces.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        pieces.append(current)
        for piece in pieces {
            let parts = piece.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            var value = parts[1]
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            result[parts[0].lowercased()] = value
        }
        return result
    }
}

/// WebDAV 相关的错误。
enum WebDAVError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器没有返回有效响应"
        case .httpStatus(let code):
            switch code {
            case 401: return "认证失败，请检查用户名与密码"
            case 403: return "没有权限访问该目录"
            case 404: return "找不到该地址，请检查 WebDAV 路径"
            case 405: return "该地址不支持 WebDAV 写入"
            default: return "服务器返回错误状态 \(code)"
            }
        }
    }
}

