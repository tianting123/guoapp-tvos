import Foundation
import SwiftUI

// MARK: - 应用状态

@MainActor
final class AppState: ObservableObject {
    @Published var initialized = false
    @Published var initializeError: String?
    @Published var allSources = false
    @Published var selectedSource = "hongguo"
    /// 核心告知的站源清单（上游自 1.0.8 起由核心在初始化时给出）。
    @Published var sources: [SourceSite] = []

    /// 站源开关：键是站源 id，值是用户是否启用。
    ///
    /// 上游把一部分站源标成 `defaultOff`（默认关闭），需要在设置里手动打开。
    /// 这里存用户显式改过的开关；没改过的按 `defaultOff` 取默认值
    /// （与上游 Dart 的 `sourceEnabled` 语义一致）。
    @Published var sourceSwitches: [String: Bool] = [:]

    /// 当前可用站源：优先用核心给的清单，缺失时退回写死列表。
    var availableSites: [SourceSite] {
        SourceSite.available(allSources: allSources, coreSources: sources)
    }

    /// 已启用的站源：界面上能选到的那些。
    ///
    /// 默认关闭的站源（`defaultOff`）除非用户手动打开，否则不出现在
    /// 首页的站源条、搜索与设置里。
    var enabledSites: [SourceSite] {
        SourceSwitch.enabled(
            availableSites,
            switches: sourceSwitches,
            id: { $0.id },
            defaultOff: { $0.defaultOff }
        )
    }

    /// 某个站源当前是否启用。
    func sourceEnabled(_ id: String) -> Bool {
        let site = availableSites.first { $0.id == id }
        // 找不到时按启用处理，避免核心刚上报、清单还没同步时源凭空消失。
        return SourceSwitch.isEnabled(
            id: id,
            switches: sourceSwitches,
            defaultOff: site?.defaultOff ?? false
        )
    }

    /// 设置某个站源是否启用。
    func setSourceEnabled(_ id: String, _ enabled: Bool) {
        sourceSwitches[id] = enabled
        SourceSwitchStore.persist(sourceSwitches)
        // 关掉了当前选中的站源 → 切回红果。
        if !enabled, selectedSource == id {
            selectedSource = availableSites.first?.id ?? "hongguo"
        }
    }

    /// 启动本地核心；已初始化时直接返回。失败时保留错误文案供界面重试。
    func bootstrap() async {
        guard !initialized else { return }
        initializeError = nil
        sourceSwitches = SourceSwitchStore.load()
        do {
            let result = try await CoreClient.shared.initialize()
            allSources = result.allSources
            sources = result.sources
            if !availableSites.contains(where: { $0.id == selectedSource }) {
                selectedSource = "hongguo"
            }
            initialized = true
        } catch {
            initializeError = error.localizedDescription
        }
    }
}

/// 站源开关的持久化（UserDefaults）。
///
/// 上游 Dart 侧存在 `sourceSwitches` 设置里，这里对应存一份。
/// 全部是 static 方法、无实例状态 —— Swift 6 严格并发下不需要 Sendable 标注。
enum SourceSwitchStore {
    static let key = "sourceSwitches"

    static func load() -> [String: Bool] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) else { return [:] }
        var result: [String: Bool] = [:]
        for (id, value) in raw {
            if let flag = value as? Bool { result[id] = flag }
            // NSNumber 也能转成 Bool
            if let number = value as? NSNumber { result[id] = number.boolValue }
        }
        return result
    }

    static func persist(_ switches: [String: Bool]) {
        UserDefaults.standard.set(switches, forKey: key)
    }
}

// MARK: - 追剧 / 观看进度

struct WatchProgress: Codable, Equatable {
    var drama: Drama
    var episode: Int
    var episodeTitle: String
    var position: Double
    var duration: Double
    var updatedAt: Date

    var episodeKey: String { "\(drama.id)#\(episode)" }
}

struct FollowedDrama: Codable, Equatable {
    var drama: Drama
    var followedAt: Date
    /// 追剧更新（FollowUpdate）：用户已知的集数；nil 表示还没有基准（第一次检查时设）。
    /// 以下三个字段都是可选的：第四阶段之前存下的追剧照样能读出来。
    var knownEpisodes: Int?
    /// 最近一次检查（核心 followCheck）看到的集数。
    var latestEpisodes: Int?
    var checkedAt: Date?
}

// MARK: - 存储协调

/// 追剧与进度的存储协调者。
///
/// tvOS 真机上只有 Caches 与 tmp 可写，系统在空间不足（以及应用不运行时）
/// 会清理 Caches，所以本地副本不可靠。这里把状态同时写本地与远端：
/// - 本地：读写都快，离线可用，作为缓存；
/// - 远端（SMB / WebDAV）：真正持久的那一份。
///
/// 启动时优先读远端：远端有数据就用远端（覆盖可能被清理掉的本地副本）；
/// 远端不可用则退回本地，保证应用照常能开。
@MainActor
final class Store: ObservableObject {
    @Published private(set) var follows: [FollowedDrama] = []
    @Published private(set) var progress: [WatchProgress] = []
    /// 远端后端最近一次操作的结果，用于在设置页提示。
    @Published private(set) var remoteStatus: String = ""
    @Published private(set) var remoteIsHealthy = true

    private let local: LocalStorageBackend
    private let settingsStore: StorageSettingsStore
    private var remote: StorageBackend?
    /// 远端同步的防抖任务：进度每 5 秒落一次盘，不必每次都同步远端。
    private var syncTask: Task<Void, Never>?
    /// 远端同步的最小间隔（可在设置里调整）。
    ///
    /// 进度每 5 秒落一次盘，每次落盘都会把同步任务重新计时（防抖），
    /// 所以实际同步间隔约等于「落盘间隔 + 同步延迟」。
    /// 默认 3 秒：SMB 每次同步都要重写整个状态文件，间隔太短会频繁写盘；
    /// 太长则退出应用时可能来不及把最后一点进度传上去。
    private var syncDelay: Duration? {
        let seconds = UserDefaults.standard.double(forKey: "remoteSyncInterval")
        // 0 表示不自动同步（只在点「立即备份」时写）。
        guard seconds > 0 else { return nil }
        return .seconds(seconds)
    }

    init(
        local: LocalStorageBackend = LocalStorageBackend(),
        settingsStore: StorageSettingsStore = StorageSettingsStore()
    ) {
        self.local = local
        self.settingsStore = settingsStore
        // 远端状态先按本地初始化，随后异步拉远端覆盖。
        if let state = local.loadSync() {
            follows = state.follows
            progress = state.progress
        }
    }

    // MARK: - 状态

    // MARK: - 追剧更新

    /// 记下一次检查的结果（基准规则见 FollowUpdate.afterCheck）。
    /// releaseStatus：检查带回的完结状态（有就记下，已完结的剧以后不再自动检查）。
    func recordCheck(dramaID: String, latestEpisodes: Int, releaseStatus: String = "", at date: Date) {
        guard let index = follows.firstIndex(where: { $0.drama.id == dramaID }) else { return }
        if !releaseStatus.isEmpty { follows[index].drama.releaseStatus = releaseStatus }
        let counts = FollowUpdate.afterCheck(known: follows[index].knownEpisodes, latest: latestEpisodes)
        follows[index].knownEpisodes = counts.known
        follows[index].latestEpisodes = counts.latest
        follows[index].checkedAt = date
        persist()
    }

    /// 用户自己打开或播放了这部剧：已知集数追平，角标消失。
    func acknowledgeUpdate(dramaID: String) {
        guard let index = follows.firstIndex(where: { $0.drama.id == dramaID }),
              let latest = follows[index].latestEpisodes,
              FollowUpdate.hasUpdate(known: follows[index].knownEpisodes, latest: latest)
        else { return }
        follows[index].knownEpisodes = latest
        persist()
    }

    /// 这部剧有更新时的角标（「更新至 N 集」），否则 nil。
    func updateBadge(for dramaID: String) -> String? {
        guard let follow = follows.first(where: { $0.drama.id == dramaID }),
              FollowUpdate.hasUpdate(known: follow.knownEpisodes, latest: follow.latestEpisodes),
              let latest = follow.latestEpisodes
        else { return nil }
        return FollowUpdate.badge(latest: latest)
    }

    var updatedFollowCount: Int {
        follows.filter { FollowUpdate.hasUpdate(known: $0.knownEpisodes, latest: $0.latestEpisodes) }.count
    }

    func isFollowing(_ drama: Drama) -> Bool {
        follows.contains { $0.drama.id == drama.id }
    }

    /// knownEpisodes：在详情页追剧时传详情里的分集数（与 followCheck 返回的是同一种计数），
    /// 作为追剧更新的基准；其它地方追剧不传，由第一次检查设基准。
    func toggleFollow(_ drama: Drama, knownEpisodes: Int? = nil) {
        if let index = follows.firstIndex(where: { $0.drama.id == drama.id }) {
            follows.remove(at: index)
        } else {
            let known = knownEpisodes.flatMap { $0 > 0 ? $0 : nil }
            follows.insert(FollowedDrama(drama: drama, followedAt: Date(), knownEpisodes: known), at: 0)
        }
        persist()
    }

    /// 某部剧的最新观看进度（任意分集）。
    func latestProgress(for dramaId: String) -> WatchProgress? {
        progress.filter { $0.drama.id == dramaId }.max { $0.updatedAt < $1.updatedAt }
    }

    /// 最近观看：每部剧只保留最新一条进度，按观看时间倒序。
    /// 与 iOS 端 history 行为一致（按 drama 去重、按 updatedAt 倒序）。
    var recentHistory: [WatchProgress] {
        var latest: [String: WatchProgress] = [:]
        for entry in progress {
            if let old = latest[entry.drama.id] {
                if entry.updatedAt > old.updatedAt { latest[entry.drama.id] = entry }
            } else {
                latest[entry.drama.id] = entry
            }
        }
        return latest.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func progress(for dramaId: String, episode: Int) -> WatchProgress? {
        progress.first { $0.drama.id == dramaId && $0.episode == episode }
    }

    func saveProgress(_ entry: WatchProgress) {
        if let index = progress.firstIndex(where: { $0.episodeKey == entry.episodeKey }) {
            progress[index] = entry
        } else {
            progress.append(entry)
        }
        // 只保留最近 500 条进度，避免文件无限增长。
        if progress.count > 500 {
            progress = Array(progress.sorted { $0.updatedAt > $1.updatedAt }.prefix(500))
        }
        persist()
    }

    /// 清除全部观看记录：「继续观看」清空，追剧列表不受影响。
    func clearHistory() {
        progress.removeAll()
        persist()
    }

    /// 删除某部剧的全部观看记录（最近观看里该剧的整条记录）。
    func deleteHistory(for drama: Drama) {
        progress.removeAll { $0.drama.id == drama.id }
        persist()
    }

    // MARK: - 持久化

    private var currentState: PersistedState {
        PersistedState(follows: follows, progress: progress, updatedAt: Date())
    }

    /// 写本地；远端同步延后合并，避免每次进度落盘都等一次网络往返。
    private func persist() {
        let state = currentState
        try? local.saveSync(state)
        guard remote != nil else { return }
        syncTask?.cancel()
        // 间隔设为 0 表示不自动同步，只在点「立即备份」时写远端。
        guard let delay = syncDelay else { return }
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let backend = self.remote else { return }
            await self.syncToRemote(backend, state: state)
        }
    }

    /// 启动时拉远端状态：有就用远端覆盖本地（远端才是持久的那份）。
    func bootstrapRemote() async {
        let backend = await makeRemoteBackend()
        guard let backend else {
            remoteStatus = "未配置远端存储"
            remoteIsHealthy = true
            return
        }
        remote = backend
        do {
            if let state = try await backend.load() {
                // 远端比本地新才覆盖，避免旧副本盖掉刚在本地记的进度。
                if let localState = local.loadSync(), localState.updatedAt > state.updatedAt {
                    remoteStatus = "本地记录更新，未覆盖"
                    remoteIsHealthy = true
                    return
                }
                follows = state.follows
                progress = state.progress
                remoteStatus = "已从远端恢复 \(state.follows.count) 个追剧、\(state.progress.count) 条进度"
                remoteIsHealthy = true
            } else {
                remoteStatus = "远端暂无数据"
                remoteIsHealthy = true
            }
        } catch {
            remoteStatus = error.localizedDescription
            remoteIsHealthy = false
        }
    }

    /// 按当前配置重建远端后端。
    ///
    /// 设置页改了存储配置后必须调这个：Store 持有的 remote 还是旧配置的
    /// 实例，不换掉的话「测试连接」和后台同步都还在连旧地址。
    ///
    /// 同时会把旧的 SMB 连接断开，避免白白占着一条 TCP 连接。
    func reloadRemoteBackend() async {
        if let smb = remote as? SMBStore {
            await smb.disconnect()
        }
        remote = await makeRemoteBackend()
        remoteStatus = remote == nil ? "未配置远端存储" : remoteStatus
    }

    /// 立刻把当前状态推到远端（设置页的「立即备份」）。
    func backupNow() async {
        await reloadRemoteBackend()
        // ?? 的右操作数是 autoclosure，不能在里面 await：分开求值。
        var backend = remote
        if backend == nil { backend = await makeRemoteBackend() }
        guard let backend else {
            remoteStatus = "未配置远端存储"
            remoteIsHealthy = false
            return
        }
        remote = backend
        await syncToRemote(backend, state: currentState)
    }

    /// 从远端拉回并覆盖本地（设置页的「从远端恢复」）。
    func restoreNow() async {
        await reloadRemoteBackend()
        // ?? 的右操作数是 autoclosure，不能在里面 await：分开求值。
        var backend = remote
        if backend == nil { backend = await makeRemoteBackend() }
        guard let backend else {
            remoteStatus = "未配置远端存储"
            remoteIsHealthy = false
            return
        }
        remote = backend
        do {
            guard let state = try await backend.load() else {
                remoteStatus = "远端暂无数据"
                return
            }
            follows = state.follows
            progress = state.progress
            try? local.saveSync(state)
            remoteStatus = "已恢复 \(state.follows.count) 个追剧、\(state.progress.count) 条进度"
            remoteIsHealthy = true
        } catch {
            remoteStatus = error.localizedDescription
            remoteIsHealthy = false
        }
    }

    /// 测试远端连接。
    func testConnection() async -> String {
        // 先按当前配置重建后端，避免测的是旧配置。
        await reloadRemoteBackend()
        guard let backend = await makeRemoteBackend() else {
            remoteStatus = "未配置远端存储"
            remoteIsHealthy = false
            return remoteStatus
        }
        remote = backend
        do {
            if let smb = backend as? SMBStore {
                _ = try await smb.probe()
            } else if let webdav = backend as? WebDAVStore {
                _ = try await webdav.probe()
            }
            remoteStatus = "连接成功"
            remoteIsHealthy = true
        } catch {
            remoteStatus = error.localizedDescription
            remoteIsHealthy = false
        }
        return remoteStatus
    }

    private func syncToRemote(_ backend: StorageBackend, state: PersistedState) async {
        do {
            try await backend.save(state)
            remoteStatus = "已备份到远端"
            remoteIsHealthy = true
        } catch {
            remoteStatus = "备份失败：\(error.localizedDescription)"
            remoteIsHealthy = false
        }
    }

    /// 按当前配置构造远端后端。
    ///
    /// 配置没变时复用已有实例 —— SMBStore 内部持有一条复用的 TCP 连接，
    /// 每次重建就等于每次重新握手认证。
    func makeRemoteBackend() async -> StorageBackend? {
        let settings = settingsStore.settings
        switch settings.kind {
        case .local:
            return nil
        case .smb:
            guard !settings.smbHost.isEmpty, !settings.smbShare.isEmpty else { return nil }
            if let existing = remote as? SMBStore, await existing.matches(settings) {
                return existing
            }
            return SMBStore(
                host: settings.smbHost,
                port: settings.smbPort,
                share: settings.smbShare,
                directory: settings.smbDirectory,
                username: settings.smbUsername,
                password: settingsStore.smbPassword(),
                domain: settings.smbDomain
            )
        case .webdav:
            guard let url = URL(string: settings.webdavURL), !settings.webdavURL.isEmpty else { return nil }
            return WebDAVStore(
                baseURL: url,
                fileName: settings.webdavFileName,
                username: settings.webdavUsername,
                password: settingsStore.webdavPassword()
            )
        }
    }
}
