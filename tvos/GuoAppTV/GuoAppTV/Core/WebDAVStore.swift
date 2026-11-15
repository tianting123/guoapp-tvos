import Foundation

/// WebDAV 客户端：把状态文件写到 NAS 的 WebDAV 目录（群晖 Cloud Sync 的 6690 端口）。
///
/// 认证支持 Basic 与 Digest —— 群晖的 WebDAV 默认走 Digest，老一些的配置是 Basic，
/// 两种都试一次，先成功哪个用哪个。
/// Swift 6：Digest 认证要缓存服务端 challenge（可变状态），用 actor 隔离。
actor WebDAVStore: StorageBackend {
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

    /// 固定指纹：为空表示走系统默认的证书校验。
    ///
    /// 家庭 NAS（fnOS / 群晖）常用自签名证书，用 IP 直连时证书的 CN / SAN
    /// 里根本没有那个 IP（fnOS 是 `CN=fnOS`，SAN 只有 `DNS:fnOS`），
    /// 系统会直接拒绝握手、报「证书无效 / 可能伪装成 …」。
    /// 填了指纹就只信任这一张证书 —— 比「跳过全部校验」安全得多。
    ///
    /// ⚠️ 指纹填错就连不上（这是故意的：宁可连不上，也不能在用户以为是
    /// A 服务器的时候连上 B 服务器）。
    private let pinnedFingerprint: String

    init(
        baseURL: URL,
        fileName: String,
        username: String,
        password: String,
        pinnedFingerprint: String = ""
    ) {
        self.baseURL = baseURL
        self.fileName = fileName
        self.username = username
        self.password = password
        self.pinnedFingerprint = CertificatePinning.normalize(pinnedFingerprint)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if self.pinnedFingerprint.isEmpty {
            session = URLSession(configuration: configuration)
        } else {
            session = URLSession(
                configuration: configuration,
                delegate: PinnedCertificateDelegate(expected: self.pinnedFingerprint),
                delegateQueue: nil
            )
        }
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

    /// PROPFIND 必须带 XML 请求体：部分 WebDAV 服务端（含 fnOS）对空 body 的
    /// PROPFIND 直接回 400，而不是 207 Multi-Status。
    private static let propfindBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>
    """

    /// 测试连接：PROPFIND 探测目录是否可读。
    /// 非 2xx 一律抛出带状态码的错误，别悄悄返回 false —— 否则「测试连接」
    /// 会把 401/403/404 当成成功。
    func probe() async throws -> Bool {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.propfindBody.utf8)
        let (_, response) = try await send(request, authenticated: false)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WebDAVError.httpStatus(http.statusCode)
        }
        return true
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

    /// 发请求并处理 401：先用 Basic，只有服务端明确下发 Digest 参数时才重试。
    ///
    /// fnOS 只支持 Basic，且 401 时给的是 `Basic realm="Restricted"`。
    /// 旧实现遇到任何 401 都重试一次，但 `applyDigestChallenge` 会因没有
    /// Digest 参数直接返回，重试发的还是同一个 Basic 头 —— 白跑一趟，
    /// 还把真正的 401 掩盖成「连接成功」。
    private func send(_ request: URLRequest, authenticated: Bool) async throws -> (Data, URLResponse) {
        var signed = request
        applyAuthorization(to: &signed)
        let (data, response) = try await session.data(for: signed)
        if let http = response as? HTTPURLResponse, http.statusCode == 401, !authenticated,
           let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate"),
           applyDigestChallenge(challenge, uri: request.url?.path ?? "/") {
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
    /// - Returns: 拿到了可用的 nonce 才返回 true（表示值得重试一次）。
    @discardableResult
    private func applyDigestChallenge(_ challenge: String, uri: String) -> Bool {
        guard challenge.lowercased().contains("digest") else { return false }
        let parameters = parseDigestParameters(challenge)
        digestState.nonce = parameters["nonce"] ?? ""
        digestState.realm = parameters["realm"] ?? ""
        digestState.qop = parameters["qop"] ?? ""
        digestState.opaque = parameters["opaque"]
        // Digest 的 uri 是本次请求的路径，WWW-Authenticate 里不会有这个字段。
        digestState.uri = uri.isEmpty ? "/" : uri
        return !digestState.nonce.isEmpty
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

