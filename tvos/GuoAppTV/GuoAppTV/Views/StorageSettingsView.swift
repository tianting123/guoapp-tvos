import SwiftUI

/// 存储设置：选择追剧与进度的保存位置。
///
/// tvOS 真机上只有 Caches 与 tmp 可写，系统会清理，所以可以配一个远端
/// （NAS 的 SMB 共享或 WebDAV）来真正持久化：
/// - SMB：直接读写共享目录里的状态文件，断网时用不了；
/// - WebDAV：把状态备份到 NAS，本机仍留一份副本。
struct StorageSettingsView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var settings = StorageSettings()
    @State private var smbPortText = "445"
    @State private var smbPassword = ""
    @State private var webdavPassword = ""
    @State private var status = ""
    @State private var busy = false

    /// WebDAV 地址拆成四段单独输入。
    ///
    /// tvOS 的系统键盘要切符号面板才能打「:」「/」「https://」，在电视上
    /// 几乎没法用。这里只让用户填 IP 或域名，其余由程序拼好。
    @State private var webdavScheme = "https"
    @State private var webdavHost = ""
    /// 飞牛 fnOS 的 WebDAV HTTPS 默认端口就是 5006（HTTP 是 5005）。
    /// 群晖 Cloud Sync 的 WebDAV 才是 6690 —— 之前默认 6690 会把 fnOS 用户带偏。
    @State private var webdavPortText = "5006"
    @State private var webdavPath = ""
    /// 协议选择弹窗。
    @State private var activeWebdavScheme = false
    /// 同步频率选择弹窗。
    @State private var activeSyncInterval = false

    /// 同步间隔选项（秒）。0 表示不自动同步。
    private static let syncIntervals: [Double] = [0, 3, 10, 30, 60, 300]
    private static func syncIntervalLabel(_ value: Double) -> String {
        if value == 0 { return "不自动同步" }
        if value < 60 { return "每 \(Int(value)) 秒" }
        return "每 \(Int(value / 60)) 分钟"
    }

    @AppStorage("remoteSyncInterval") private var syncInterval: Double = 3

    private let settingsStore = StorageSettingsStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVTheme.sectionSpacing) {
                kindGroup
                if settings.kind == .smb {
                    smbGroup
                }
                if settings.kind == .webdav {
                    webdavGroup
                }
                syncGroup
                actionGroup
                if !status.isEmpty {
                    statusNote
                }
            }
            .padding(.horizontal, TVTheme.pageInset)
            .padding(.top, 20)
            .padding(.bottom, 56)
        }
        .onAppear(perform: load)
        .sheet(isPresented: $activeSyncInterval) {
            TVOptionSheet(
                title: "自动同步",
                options: Self.syncIntervals.map {
                    TVOption(value: $0, label: Self.syncIntervalLabel($0))
                },
                selection: $syncInterval
            )
        }
        .sheet(isPresented: $activeWebdavScheme) {
            TVOptionSheet(
                title: "协议",
                options: [
                    TVOption(value: "https", label: "HTTPS"),
                    TVOption(value: "http", label: "HTTP"),
                ],
                selection: $webdavScheme
            )
        }
    }

    // MARK: - 存储方式

    private var kindGroup: some View {
        TVSettingGroup(title: "存储方式") {
            ForEach(Array(StorageSettings.Kind.allCases.enumerated()), id: \.element) { index, kind in
                if index > 0 {
                    TVSettingDivider()
                }
                TVSettingRow {
                    settings.kind = kind
                    Task { await save() }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(kind.displayName)
                                .font(.system(size: 24, weight: .medium))
                            Text(kind.detail)
                                .font(.system(size: 18))
                                .foregroundColor(TVTheme.textSecondary)
                        }
                        Spacer()
                        if kind == settings.kind {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 27))
                                .foregroundColor(TVTheme.accent)
                        }
                    }
                }
            }
        }
    }

    // MARK: - SMB

    private var smbGroup: some View {
        TVSettingGroup(title: "SMB 共享") {
            TVTextFieldRow(title: "服务器", placeholder: "192.168.2.99", text: $settings.smbHost)
            TVSettingDivider()
            TVTextFieldRow(title: "共享名", placeholder: "backup", text: $settings.smbShare)
            TVSettingDivider()
            TVTextFieldRow(title: "目录", placeholder: "留空表示共享根目录", text: $settings.smbDirectory)
            TVSettingDivider()
            TVTextFieldRow(title: "用户名", placeholder: "填写 NAS 账号", text: $settings.smbUsername)
            TVSettingDivider()
            TVTextFieldRow(title: "密码", placeholder: "留空表示不修改", text: $smbPassword, isSecure: true)
            TVSettingDivider()
            TVTextFieldRow(title: "域", placeholder: "一般留空", text: $settings.smbDomain)
            TVSettingDivider()
            TVTextFieldRow(title: "端口", placeholder: "445", text: $smbPortText)
        }
    }

    // MARK: - WebDAV

    private var webdavGroup: some View {
        TVSettingGroup(title: "WebDAV") {
            TVValueRow(title: "协议", value: webdavScheme == "http" ? "HTTP" : "HTTPS") {
                activeWebdavScheme = true
            }
            TVSettingDivider()
            TVTextFieldRow(title: "服务器", placeholder: "192.168.2.154", text: $webdavHost)
            TVSettingDivider()
            TVTextFieldRow(title: "端口", placeholder: "5006", text: $webdavPortText)
            TVSettingDivider()
            TVTextFieldRow(title: "路径", placeholder: "WebDAV 可见文件夹名，如 backup", text: $webdavPath)
            TVSettingDivider()
            TVTextFieldRow(title: "用户名", placeholder: "填写 NAS 账号", text: $settings.webdavUsername)
            TVSettingDivider()
            TVTextFieldRow(title: "密码", placeholder: "留空表示不修改", text: $webdavPassword, isSecure: true)
            TVSettingDivider()
            TVTextFieldRow(title: "文件名", placeholder: "tv-state.json", text: $settings.webdavFileName)
            TVSettingDivider()
            TVTextFieldRow(
                title: "证书指纹",
                placeholder: "自签名证书才需要填",
                text: $settings.webdavFingerprint
            )
            TVSettingDivider()
            Text("完整地址：\(webdavURLPreview)")
                .font(.system(size: 18))
                .foregroundColor(TVTheme.textTertiary)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
            Text("不想处理证书：把上面「协议」切到 HTTP、端口填 5005（fnOS 的明文 WebDAV），就没有 TLS 握手、也就没有证书校验这一步；代价是账号密码在内网明文传输。坚持用 HTTPS 就填服务器证书的 SHA-256 指纹，程序只信任这一张，伪造证书仍会被拒绝。本应用不提供「跳过证书校验」开关。")
                .font(.system(size: 17))
                .foregroundColor(TVTheme.textTertiary)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
            Text("飞牛 fnOS：在「系统设置 → 文件共享协议 → WebDAV」里启用服务、设置「可见文件夹范围」，路径栏填那个文件夹名。HTTPS 端口 5006、HTTP 端口 5005；群晖 Cloud Sync 的 WebDAV 才是 6690。别把带端口的整串地址填进「服务器」栏 —— 下面「完整地址」显示的才是真正会保存的地址。")
                .font(.system(size: 17))
                .foregroundColor(TVTheme.textTertiary)
                .padding(.horizontal, 28)
                .padding(.bottom, 14)
        }
    }

    /// 拼出来的完整 WebDAV 地址（给用户确认）。
    /// 直接复用 `composeWebDAVURL()`，保证预览与实际保存的完全一致。
    private var webdavURLPreview: String {
        let composed = composeWebDAVURL()
        return composed.isEmpty ? "（请填写服务器）" : composed
    }

    /// 由各分段拼出完整地址，写进设置。
    ///
    /// 允许「服务器」栏直接粘 `192.168.2.154:5006` 或 `https://192.168.2.154:5006/backup`
    /// 这样的整串：自动拆出 host / port / path，不再拼出 `host:5006:6690` 这种
    /// `URL(string:)` 解析为 nil 的非法地址。
    private func composeWebDAVURL() -> String {
        var host = webdavHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return "" }
        var scheme = webdavScheme
        var port = webdavPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        var path = webdavPath.trimmingCharacters(in: .whitespacesAndNewlines)

        if host.contains("://") {
            if let parsed = URL(string: host) {
                scheme = parsed.scheme?.lowercased() == "http" ? "http" : "https"
                host = parsed.host ?? host
                if let parsedPort = parsed.port { port = String(parsedPort) }
                if !parsed.path.isEmpty, parsed.path != "/" { path = parsed.path }
            }
        } else if let colon = host.lastIndex(of: ":"),
                  let parsedPort = Int(String(host[host.index(after: colon)...])),
                  (1...65535).contains(parsedPort) {
            port = String(parsedPort)
            host = String(host[..<colon])
        }
        if path.isEmpty {
            path = ""
        } else if !path.hasPrefix("/") {
            path = "/" + path
        }
        let portPart = port.isEmpty ? "" : ":\(port)"
        return "\(scheme)://\(host)\(portPart)\(path)"
    }

    /// 把完整地址拆回各分段（进入页面时用）。
    private func decomposeWebDAVURL(_ url: String) {
        guard let parsed = URL(string: url), let scheme = parsed.scheme else {
            // 拆不动就整段塞进主机栏，由 compose 再自动识别。
            webdavScheme = "https"
            webdavHost = url
            webdavPortText = "5006"
            webdavPath = ""
            return
        }
        webdavScheme = scheme == "http" ? "http" : "https"
        webdavHost = parsed.host ?? ""
        webdavPortText = parsed.port.map(String.init) ?? (scheme == "http" ? "5005" : "5006")
        var path = parsed.path
        if path == "/" { path = "" }
        webdavPath = path
    }

    // MARK: - 同步频率

    private var syncGroup: some View {
        TVSettingGroup(title: "同步频率") {
            TVValueRow(title: "自动同步", value: Self.syncIntervalLabel(syncInterval)) {
                activeSyncInterval = true
            }
            TVSettingDivider()
            Text(syncExplanation)
                .font(.system(size: 18))
                .foregroundColor(TVTheme.textTertiary)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
        }
    }

    /// 说明当前的实际同步节奏。
    private var syncExplanation: String {
        if syncInterval == 0 {
            return "不自动同步：只在「立即备份到远端」时写入。进度仍会存在本机缓存。"
        }
        return "观看时进度每 5 秒记一次，连续记录后会合并成一次远端写入，实际间隔约 \(Int(syncInterval)) 秒。退出应用时会再补写一次。"
    }

    // MARK: - 操作

    private var actionGroup: some View {
        TVSettingGroup(title: "操作") {
            TVSettingRow {
                Task { await testConnection() }
            } label: {
                HStack {
                    Text("测试连接")
                        .font(.system(size: 24, weight: .medium))
                    Spacer()
                    if busy {
                        ProgressView()
                            .progressViewStyle(.circular)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(TVTheme.textTertiary)
                    }
                }
            }
            TVSettingDivider()
            TVSettingRow {
                Task { await backup() }
            } label: {
                HStack {
                    Text("立即备份到远端")
                        .font(.system(size: 24, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(TVTheme.textTertiary)
                }
            }
            TVSettingDivider()
            TVSettingRow {
                Task { await restore() }
            } label: {
                HStack {
                    Text("从远端恢复")
                        .font(.system(size: 24, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(TVTheme.textTertiary)
                }
            }
        }
    }

    private var statusNote: some View {
        Text(status)
            .font(.system(size: 19))
            .foregroundColor(status.contains("失败") || status.contains("错误")
                             ? TVTheme.accent : TVTheme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(TVTheme.surfaceDim)
            )
    }

    // MARK: - 行为

    private func load() {
        settings = settingsStore.settings
        smbPortText = String(settings.smbPort)
        smbPassword = ""
        webdavPassword = ""
        decomposeWebDAVURL(settings.webdavURL)
    }

    private func save() async {
        var updated = settings
        updated.smbPort = Int(smbPortText) ?? 445
        // 分段拼出的地址才是准的（settings.webdavURL 可能还是老的整段值）。
        updated.webdavURL = composeWebDAVURL()
        if !smbPassword.isEmpty {
            settingsStore.setSMBPassword(smbPassword)
            smbPassword = ""
        }
        if !webdavPassword.isEmpty {
            settingsStore.setWebDAVPassword(webdavPassword)
            webdavPassword = ""
        }
        settingsStore.settings = updated
        // 配置变了就换掉 Store 手里的远端后端，否则它还在连旧地址。
        await store.reloadRemoteBackend()
    }

    private func testConnection() async {
        await save()
        busy = true
        status = await store.testConnection()
        busy = false
    }

    private func backup() async {
        await save()
        busy = true
        await store.backupNow()
        status = store.remoteStatus
        busy = false
    }

    private func restore() async {
        await save()
        busy = true
        await store.restoreNow()
        status = store.remoteStatus
        busy = false
    }
}
