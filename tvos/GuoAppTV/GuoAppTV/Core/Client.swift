import Foundation

enum CoreError: LocalizedError {
    case message(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .transport(let text): return text
        }
    }
}

/// Go 核心的 Swift 客户端（见 upstream/native/core/app_runtime.go 的 NativeRequest）。
///
/// 协议就是一层 JSON：请求 `{action, ...}`，响应 `{ok, data, error, code}`。
/// 核心调用是阻塞的（站源请求最长 60 秒），所以统一走一条专用串行队列，
/// 绝不在主线程或 Swift 协作线程池里阻塞；actor 保证调用之间不交错。
actor CoreClient {
    static let shared = CoreClient()

    private let queue = DispatchQueue(label: "app.duanju.core", qos: .userInitiated)
    private var initialized = false
    private var playbackSequence = 0

    /// 首页目录缓存：切标签回来时直接用缓存，避免每次重新联网拉取。
    /// 带 TTL（30 分钟），过期后重新拉取，保证内容新鲜。
    /// 只缓存浏览（query 为空），搜索结果不缓存，保证搜索实时。
    private struct CacheEntry<Value> {
        let value: Value
        let timestamp: Date
    }
    private static let cacheTTL: TimeInterval = 1800
    private var catalogCache: [String: CacheEntry<CatalogPage>] = [:]
    private var categoriesCache: [String: CacheEntry<[Category]>] = [:]
    private var rankingBoardsCache: CacheEntry<[RankingBoard]>?
    private var rankingsCache: [String: CacheEntry<RankingPage>] = [:]
    private var producerCache: [String: CacheEntry<ProducerWorks>] = [:]

    private func isFresh(_ timestamp: Date) -> Bool {
        Date().timeIntervalSince(timestamp) < Self.cacheTTL
    }

    /// 写缓存时顺带清理过期条目，避免缓存无限增长。
    private func purgeExpiredCache() {
        catalogCache = catalogCache.filter { isFresh($0.value.timestamp) }
        categoriesCache = categoriesCache.filter { isFresh($0.value.timestamp) }
        if let entry = rankingBoardsCache, !isFresh(entry.timestamp) {
            rankingBoardsCache = nil
        }
        rankingsCache = rankingsCache.filter { isFresh($0.value.timestamp) }
        producerCache = producerCache.filter { isFresh($0.value.timestamp) }
    }

    /// 清空首页目录缓存（首页按播放/暂停键手动刷新时调用，强制重新拉取）。
    func invalidateHomeCache() {
        catalogCache.removeAll()
        categoriesCache.removeAll()
        rankingBoardsCache = nil
        rankingsCache.removeAll()
    }

    private func call(_ payload: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(decoding: data, as: UTF8.self)
        let responseText = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try DuanjuBridge.request(text))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        guard
            let responseData = responseText.data(using: .utf8),
            let envelope = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        else {
            throw CoreError.transport("本地核心返回了无效数据")
        }
        guard envelope["ok"] as? Bool == true else {
            throw CoreError.message(envelope["error"] as? String ?? "读取失败，请重试")
        }
        return envelope["data"] as? [String: Any] ?? [:]
    }

    private func nextSequence() -> Int {
        playbackSequence += 1
        return playbackSequence
    }

    /// 初始化核心。返回核心编译时是否包含全部站源（--all-sources）与站源清单。
    ///
    /// 上游自 1.0.8 起不再返回 allSources 布尔值，改为返回编译期版本名
    /// flavor（hongguojian / zhenguojian）与站源清单 sources；
    /// 界面不再写死站源表，改为按核心给的清单显示。
    func initialize() async throws -> (allSources: Bool, sources: [SourceSite]) {
        if initialized { return (allSources, sources) }
        // tvOS 沙盒：真机上 Documents / Application Support 只读，只有
        // Caches 与 tmp 可写。核心的数据目录必须放在 Caches；代价是
        // 系统在存储不足时可能回收 Caches（缓存、海报、进度会丢失，
        // 属于 tvOS 的固有约束，下载等功能也因此不做）。
        let directory = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try await call(["action": "initialize", "directory": directory.path])
        flavor = data["flavor"] as? String ?? ""
        allSources = flavor == "zhenguojian"
        sources = (data["sources"] as? [[String: Any]] ?? []).compactMap { SourceSite(dict: $0) }
        initialized = true
        return (allSources, sources)
    }

    private(set) var allSources = false
    /// 核心编译期版本名：hongguojian（仅红果）/ zhenguojian（全部站源）。
    private(set) var flavor = ""
    /// 核心告知的站源清单（含名称、描述与可用能力）。
    private(set) var sources: [SourceSite] = []

    func categories(source: String, force: Bool = false) async throws -> [Category] {
        if !force, let entry = categoriesCache[source], isFresh(entry.timestamp) {
            return entry.value
        }
        let data = try await call(["action": "categories", "source": source, "force": force])
        let rows = data["items"] as? [Any] ?? []
        let result = rows.compactMap { ($0 as? [String: Any]).map(Category.init(dict:)) }
        purgeExpiredCache()
        categoriesCache[source] = CacheEntry(value: result, timestamp: Date())
        return result
    }

    /// 榜单列表（Go 核心 `rankingBoards`）。
    func rankingBoards() async throws -> [RankingBoard] {
        if let entry = rankingBoardsCache, isFresh(entry.timestamp) {
            return entry.value
        }
        let data = try await call(["action": "rankingBoards"])
        let rows = data["items"] as? [Any] ?? []
        let result = rows.compactMap { ($0 as? [String: Any]).map(RankingBoard.init(dict:)) }
        purgeExpiredCache()
        rankingBoardsCache = CacheEntry(value: result, timestamp: Date())
        return result
    }

    /// 某一榜单的一页（Go 核心 `rankings`）。
    func rankings(board: String, page: Int = 1) async throws -> RankingPage {
        let key = "\(board)|\(page)"
        if let entry = rankingsCache[key], isFresh(entry.timestamp) {
            return entry.value
        }
        let data = try await call(["action": "rankings", "board": board, "page": page])
        let result = RankingPage(dict: data)
        purgeExpiredCache()
        rankingsCache[key] = CacheEntry(value: result, timestamp: Date())
        return result
    }

    func catalog(
        source: String, page: Int = 1, query: String = "", category: String = "", force: Bool = false
    ) async throws -> CatalogPage {
        // 只缓存浏览（query 为空），搜索结果不缓存，保证搜索实时。
        let cacheKey: String? = query.isEmpty ? "\(source)|\(page)|\(category)" : nil
        if !force, let key = cacheKey, let entry = catalogCache[key], isFresh(entry.timestamp) {
            return entry.value
        }
        let data = try await call([
            "action": "catalog",
            "source": source,
            "page": page,
            "query": query,
            "category": category,
            "force": force,
        ])
        let result = CatalogPage(dict: data)
        if let key = cacheKey {
            purgeExpiredCache()
            catalogCache[key] = CacheEntry(value: result, timestamp: Date())
        }
        return result
    }

    func suggestions(query: String) async throws -> [String] {
        let data = try await call(["action": "suggestions", "query": query])
        return (data["items"] as? [Any] ?? []).compactMap { $0 as? String }
    }

    /// 海报由核心下载到本地文件并返回路径；HEIC 海报 tvOS 原生支持，无需转码。
    func coverPath(for drama: Drama) async throws -> String {
        let data = try await call(["action": "cover", "drama": drama.requestJSON(), "force": false])
        guard let path = data["path"] as? String, !path.isEmpty else {
            throw CoreError.message("海报暂不可用")
        }
        return path
    }

    func detail(drama: Drama) async throws -> DramaDetail {
        let data = try await call(["action": "detail", "drama": drama.requestJSON()])
        return DramaDetail(dict: data)
    }

    /// 出品方剧作：点入详情页的出品方入口后才调用，核心先按剧名定出品方，
    /// 再拉该出品方的全部剧作（已补上线日期，供按最新/最热排序）。
    func producerWorks(drama: Drama) async throws -> ProducerWorks {
        // 出品方检索要几十秒，结果按剧缓存（同目录缓存 TTL）：页面重建或
        // 返回时直接用缓存，不再重复检索。
        if let entry = producerCache[drama.id], isFresh(entry.timestamp) {
            return entry.value
        }
        let data = try await call(["action": "producerWorks", "drama": drama.requestJSON()])
        let result = ProducerWorks(dict: data)
        purgeExpiredCache()
        producerCache[drama.id] = CacheEntry(value: result, timestamp: Date())
        return result
    }

    func resolve(drama: Drama, episode: Episode, quality: Int = 0) async throws -> PlaybackPlan {
        let data = try await call([
            "action": "resolve",
            "drama": drama.requestJSON(),
            "chapter": episode.raw,
            "index": episode.number,
            "quality": quality,
            "sequence": nextSequence(),
        ])
        return PlaybackPlan(dict: data)
    }

    /// 预热播放：让核心先把视频数据拉进本地代理缓存，再开始播放。
    ///
    /// 核心的 preload 动作（native/core/app_preload.go）会解析播放地址，
    /// 并把最多 4MB 的视频数据预热进本地流代理。返回的 plan 就是可直接
    /// 播放的地址（同样是本地代理地址）。
    ///
    /// 为什么需要：mpv 打开一个网络流时从 0 字节开始拉，弱网下缓冲
    /// 很容易耗尽，表现为画面一顿一顿。先预热过，播放器一开始就有
    /// 数据在手，缓冲中断会少很多。上游 Dart 端在播放前与切集时都做
    /// 同样的预热。
    func preload(drama: Drama, episode: Episode, quality: Int = 0) async throws -> PlaybackPlan {
        let data = try await call([
            "action": "preload",
            "drama": drama.requestJSON(),
            "chapter": episode.raw,
            "index": episode.number,
            "quality": quality,
            // preload 走核心的「读」通道：必须带 session（同一 scope 共用一个），
            // 且 sequence 要全局递增，否则核心会以「请求标记无效」拒绝。
            "session": readSession(scope: "preload"),
            "sequence": nextSequence(),
        ])
        return PlaybackPlan(dict: data)
    }

    /// 读通道的 session 标识：格式必须是「归属者:范围」，字符集限
    /// 字母数字与 - _ : . ，否则核心不认。
    private func readSession(scope: String) -> String {
        "guoapp-tv:\(scope)"
    }

    /// 当前线路失败时向核心要下一条线路。
    func fallback(plan: PlaybackPlan) async throws -> PlaybackPlan {
        let data = try await call([
            "action": "fallback",
            "session": plan.session,
            "sequence": nextSequence(),
        ])
        return PlaybackPlan(dict: data)
    }

    func danmaku(plan: PlaybackPlan, startMs: Int, durationMs: Int) async throws -> DanmakuPage {
        let data = try await call([
            "action": "danmaku",
            "playbackSession": plan.session,
            "startMs": startMs,
            "durationMs": durationMs,
        ])
        return DanmakuPage(dict: data)
    }

    /// 释放一次播放会话（退出播放页时调用）。
    func release(session: String) async throws {
        guard !session.isEmpty else { return }
        _ = try await call(["action": "release", "session": session])
    }

    /// 查询站源的设备注册状态。返回 true 表示已就绪。
    ///
    /// 红果需要先注册设备号才能拿到播放签名；没注册时解析会失败。
    /// 核心的 sourceDevices 对不支持设备注册的站源直接返回 ready=true。
    func sourceDevicesReady(source: String) async throws -> Bool {
        let data = try await call(["action": "sourceDevices", "source": source])
        return (data["ready"] as? NSNumber)?.boolValue ?? (data["ready"] as? Bool) ?? false
    }

    /// 注册站源设备。返回 true 表示注册成功。
    func registerSourceDevices(source: String) async throws -> Bool {
        let data = try await call([
            "action": "sourceDevices",
            "source": source,
            "command": "register",
        ])
        return (data["ready"] as? NSNumber)?.boolValue ?? (data["ready"] as? Bool) ?? false
    }

    // MARK: - 站源账号

    /// 查询站源账号状态。
    func sourceAccountStatus(source: String) async throws -> SourceAccountStatus {
        let data = try await call([
            "action": "sourceAccount",
            "source": source,
        ])
        return SourceAccountStatus(dict: data)
    }

    /// 取站源登录用的滑块验证码。
    func sourceAccountCaptcha(source: String) async throws -> SourceCaptcha {
        let data = try await call([
            "action": "sourceAccount",
            "source": source,
            "command": "captcha",
        ])
        return SourceCaptcha(dict: data)
    }

    /// 用账号密码与滑块轨迹登录。
    func sourceAccountLogin(
        source: String,
        identifier: String,
        password: String,
        captchaID: String,
        track: CaptchaTrack
    ) async throws -> SourceAccountStatus {
        let data = try await call([
            "action": "sourceAccount",
            "source": source,
            "command": "login",
            "account": [
                "identifier": identifier,
                "password": password,
                "captchaId": captchaID,
                "track": track.dictionary,
            ],
        ])
        return SourceAccountStatus(dict: data)
    }

    /// 退出站源账号。
    func sourceAccountLogout(source: String) async throws -> SourceAccountStatus {
        let data = try await call([
            "action": "sourceAccount",
            "source": source,
            "command": "logout",
        ])
        return SourceAccountStatus(dict: data)
    }

    // MARK: - 代理设置

    /// 读取核心当前的资源设置（代理模式与地址）。
    func resourceSettings() async throws -> ResourceSettings {
        let data = try await call(["action": "resourceSettings"])
        return ResourceSettings(dict: data)
    }

    /// 保存代理设置。mode 取值：auto（自动读系统代理）/ direct（直连）/ manual（手动）。
    func saveResourceSettings(mode: String, proxyURL: String) async throws -> ResourceSettings {
        let data = try await call([
            "action": "saveResourceSettings",
            "settings": [
                "proxyMode": mode,
                "proxyUrl": proxyURL,
            ],
        ])
        return ResourceSettings(dict: data)
    }

    /// 取消正在进行的解析（与 Dart 侧行为一致，sequence 递增）。
    func cancelPlayback() async throws {
        _ = try await call(["action": "cancelPlayback", "sequence": nextSequence()])
    }
}
