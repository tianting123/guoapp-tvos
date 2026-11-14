import SwiftUI

/// 「打开站源账号页」的广播通知。
///
/// 播放页遇到「该站源需要登录」时发这个通知，设置页收到后跳到账号页。
extension Notification.Name {
    static let openSourceAccount = Notification.Name("openSourceAccount")
}

/// 站源账号设置页。
///
/// 上游有些站源要登录或要注册设备才能播放（红果要注册设备号，青空次元要账号
/// 登录）。核心在 `initialize` 时会在每个站源条目上标出 `devices` / `account`
/// 能力，这里按标记把需要处理的站源列出来。
///
/// 青空次元的登录是滑块验证码：核心先给一张背景图与拼图模板，用户用方向键
/// 把拼图拖到缺口，核心校验轨迹后换登录令牌。
struct SourceAccountView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// 需要账号登录的站源 → 当前状态。
    @State private var accountStates: [String: SourceAccountStatus] = [:]
    /// 需要设备注册的站源 → 是否就绪。
    @State private var deviceStates: [String: Bool] = [:]
    /// 正在处理的站源（显示转圈）。
    @State private var busySource: String?
    /// 代理模式：auto / direct / manual。
    @State private var proxyMode = "auto"
    @State private var proxyURL = ""
    @State private var systemProxyStatus = ""
    @State private var savingProxy = false
    @State private var activeProxyPicker = false
    /// 顶部提示文案。
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVTheme.sectionSpacing) {
                if let message {
                    notice(message, isError: messageIsError)
                }
                deviceSection
                accountSection
                proxySection
            }
            .padding(.horizontal, TVTheme.pageInset)
            .padding(.top, 20)
            .padding(.bottom, 56)
        }
        .task { await refresh() }
        .sheet(isPresented: $activeProxyPicker) {
            TVOptionSheet(
                title: "代理模式",
                options: [
                    TVOption(value: "auto", label: "自动（跟随系统）"),
                    TVOption(value: "direct", label: "直连"),
                    TVOption(value: "manual", label: "手动代理"),
                ],
                selection: $proxyMode
            )
        }
        .sheet(isPresented: $activeProxyPicker) {
            TVOptionSheet(
                title: "代理模式",
                options: [
                    TVOption(value: "auto", label: "自动（跟随系统）"),
                    TVOption(value: "direct", label: "直连"),
                    TVOption(value: "manual", label: "手动代理"),
                ],
                selection: $proxyMode
            )
        }
        .sheet(isPresented: $isPresentingLogin) {
            if let loginSource {
                LoginSheet(site: loginSource) { status in
                    isPresentingLogin = false
                    if let status {
                        accountStates[loginSource.id] = status
                        show(status.loggedIn ? "「\(loginSource.name)」登录成功" : "登录未完成", isError: !status.loggedIn)
                    }
                }
            }
        }
    }

    // MARK: - 设备注册

    /// 需要注册设备的站源（红果：注册设备号才能拿到播放签名）。
    @ViewBuilder
    private var deviceSection: some View {
        let sources = appState.enabledSites.filter { $0.requiresDeviceRegistration }
        if !sources.isEmpty {
            TVSettingGroup(title: "设备注册") {
                ForEach(Array(sources.enumerated()), id: \.element.id) { index, site in
                    if index > 0 { TVSettingDivider() }
                    TVSettingRow {
                        Task { await registerDevice(site) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(site.name)
                                    .font(.system(size: 24, weight: .medium))
                                Text(deviceStatusText(site))
                                    .font(.system(size: 18))
                                    .foregroundColor(TVTheme.textSecondary)
                            }
                            Spacer()
                            if busySource == site.id {
                                ProgressView()
                                    .scaleEffect(1.4)
                            } else if deviceStates[site.id] == true {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 27))
                                    .foregroundColor(TVTheme.accent)
                            } else {
                                Text("注册")
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundColor(TVTheme.accent)
                            }
                        }
                    }
                }
            }
            Text("部分站源需要先注册设备才能播放。注册后无需再操作。")
                .font(.system(size: 18))
                .foregroundColor(TVTheme.textTertiary)
        }
    }

    private func deviceStatusText(_ site: SourceSite) -> String {
        switch deviceStates[site.id] {
        case .some(true): return "已就绪"
        case .some(false): return "尚未注册"
        default: return "点击注册"
        }
    }

    // MARK: - 账号登录

    /// 需要账号登录的站源（青空次元）。
    @ViewBuilder
    private var accountSection: some View {
        let sources = appState.enabledSites.filter { $0.requiresAccount }
        if !sources.isEmpty {
            TVSettingGroup(title: "站源账号") {
                ForEach(Array(sources.enumerated()), id: \.element.id) { index, site in
                    if index > 0 { TVSettingDivider() }
                    TVSettingRow {
                        Task { await openAccount(site) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(site.name)
                                    .font(.system(size: 24, weight: .medium))
                                Text(accountStatusText(site))
                                    .font(.system(size: 18))
                                    .foregroundColor(TVTheme.textSecondary)
                            }
                            Spacer()
                            if busySource == site.id {
                                ProgressView()
                                    .scaleEffect(1.4)
                            } else if accountStates[site.id]?.loggedIn == true {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 27))
                                    .foregroundColor(TVTheme.accent)
                            } else {
                                Text("登录")
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundColor(TVTheme.accent)
                            }
                        }
                    }
                }
            }
            Text("需要登录的站源登录后才能播放。")
                .font(.system(size: 18))
                .foregroundColor(TVTheme.textTertiary)
        }
    }

    private func accountStatusText(_ site: SourceSite) -> String {
        guard let state = accountStates[site.id] else { return "点击登录" }
        if state.loggedIn {
            return state.name.isEmpty ? "已登录" : "已登录：\(state.name)"
        }
        return "未登录"
    }

    // MARK: - 代理

    /// 代理设置：红果等站源在部分网络下需要代理才能注册与播放。
    /// 核心默认自动读系统代理，但电视盒子往往没有可用的系统代理设置。
    private var proxySection: some View {
        TVSettingGroup(title: "网络代理") {
            TVSettingRow {
                activeProxyPicker = true
            } label: {
                HStack {
                    Text("代理模式")
                        .font(.system(size: 24, weight: .medium))
                    Spacer()
                    Text(proxyModeLabel)
                        .font(.system(size: 20))
                        .foregroundColor(TVTheme.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(TVTheme.textTertiary)
                }
            }
            TVSettingDivider()
            TVTextFieldRow(title: "代理地址", placeholder: proxyURLPlaceholder, text: $proxyURL)
            TVSettingDivider()
            HStack(spacing: 20) {
                TVPrimaryButton(title: "保存代理", icon: "network") {
                    Task { await saveProxy() }
                }
                .disabled(savingProxy)
                TVSecondaryButton(title: "重置", icon: "arrow.counterclockwise") {
                    proxyMode = "auto"
                    proxyURL = ""
                    Task { await saveProxy() }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            if !systemProxyStatus.isEmpty {
                Text(systemProxyStatus)
                    .font(.system(size: 18))
                    .foregroundColor(TVTheme.textTertiary)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 14)
            }
        }
    }

    private var proxyModeLabel: String {
        switch proxyMode {
        case "direct": return "直连"
        case "manual": return "手动代理"
        default: return "自动（跟随系统）"
        }
    }

    private var proxyURLPlaceholder: String {
        proxyMode == "manual" ? "如 http://192.168.2.1:7890" : "未使用手动代理"
    }

    private func saveProxy() async {
        savingProxy = true
        defer { savingProxy = false }
        do {
            let settings = try await CoreClient.shared.saveResourceSettings(
                mode: proxyMode,
                proxyURL: proxyMode == "manual" ? proxyURL : ""
            )
            proxyMode = settings.proxyMode
            systemProxyStatus = settings.systemProxyStatus
            if !settings.warning.isEmpty {
                show(settings.warning, isError: true)
            } else {
                show("代理设置已保存", isError: false)
            }
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    // MARK: - 提示

    private func notice(_ text: String, isError: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 26))
                .foregroundColor(isError ? .orange : TVTheme.accent)
            Text(text)
                .font(.system(size: 21))
                .foregroundColor(TVTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(TVTheme.surfaceBright)
        )
    }

    // MARK: - 动作

    private func refresh() async {
        if let settings = try? await CoreClient.shared.resourceSettings() {
            proxyMode = settings.proxyMode
            proxyURL = settings.proxyURL
            systemProxyStatus = settings.systemProxyStatus
        }
        for site in appState.enabledSites {
            if site.requiresDeviceRegistration {
                let ready = (try? await CoreClient.shared.sourceDevicesReady(source: site.id)) ?? false
                deviceStates[site.id] = ready
            }
            if site.requiresAccount {
                if let state = try? await CoreClient.shared.sourceAccountStatus(source: site.id) {
                    accountStates[site.id] = state
                }
            }
        }
    }

    private func registerDevice(_ site: SourceSite) async {
        busySource = site.id
        defer { busySource = nil }
        do {
            let ready = try await CoreClient.shared.registerSourceDevices(source: site.id)
            deviceStates[site.id] = ready
            if ready {
                show("「\(site.name)」设备注册成功", isError: false)
            } else {
                show("「\(site.name)」设备注册未完成，请重试", isError: true)
            }
        } catch {
            // 设备注册失败最常见的原因是网络不通（红果要访问它的注册接口）。
            // 给一句能照做的提示，而不是干巴巴地把错误甩给用户。
            let detail = error.localizedDescription
            show("设备注册失败：\(detail)。若提示网络错误，请检查下方代理设置后重试。", isError: true)
        }
    }

    private func openAccount(_ site: SourceSite) async {
        // 已登录的站源：点一下直接退出登录。
        if accountStates[site.id]?.loggedIn == true {
            busySource = site.id
            defer { busySource = nil }
            if let state = try? await CoreClient.shared.sourceAccountLogout(source: site.id) {
                accountStates[site.id] = state
                show("已退出「\(site.name)」账号", isError: false)
            }
            return
        }
        // 需要登录：打开登录页。
        await MainActor.run {
            isPresentingLogin = true
            loginSource = site
        }
    }

    @State private var isPresentingLogin = false
    @State private var loginSource: SourceSite?

    private func show(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }

    // MARK: - 登录弹窗

    /// 账号登录页（弹窗形式）。
    private struct LoginSheet: View {
        let site: SourceSite
        let onDone: (SourceAccountStatus?) -> Void

        @State private var identifier = ""
        @State private var password = ""
        @State private var captcha: SourceCaptcha?
        @State private var error: String?
        @State private var submitting = false
        @State private var track: CaptchaTrack?

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    TVSectionHeader(title: "登录 \(site.name)")
                    Text("输入账号密码后完成滑块验证")
                        .font(.system(size: 19))
                        .foregroundColor(TVTheme.textTertiary)
                    if let error {
                        Text(error)
                            .font(.system(size: 20))
                            .foregroundColor(.orange)
                    }
                    TVTextFieldRow(title: "账号", placeholder: "用户名或邮箱", text: $identifier)
                    TVSettingDivider()
                    TVTextFieldRow(title: "密码", placeholder: "密码", text: $password, isSecure: true)
                    if let captcha {
                        TVSettingDivider()
                        SliderCaptchaView(captcha: captcha) { value in
                            track = value
                            // 拖完滑块自动提交登录。
                            if value != nil {
                                Task { await submit() }
                            }
                        }
                    }
                    HStack(spacing: 20) {
                        TVPrimaryButton(title: submitting ? "登录中…" : "登录", icon: "person.badge.key") {
                            Task { await submit() }
                        }
                        .disabled(submitting)
                        TVSecondaryButton(title: "取消", icon: "xmark") {
                            onDone(nil)
                        }
                    }
                }
                .padding(.horizontal, TVTheme.pageInset)
                .padding(.vertical, 30)
            }
            .task { await loadCaptcha() }
        }

        /// 取滑块验证码。
        private func loadCaptcha() async {
            do {
                let value = try await CoreClient.shared.sourceAccountCaptcha(source: site.id)
                guard value.isValid else {
                    error = "验证码数据无效，请重试"
                    return
                }
                captcha = value
            } catch {
                self.error = error.localizedDescription
            }
        }

        /// 提交登录。滑块拖完会自动调一次；没拖验证码时按钮也能点。
        private func submit() async {
            guard !submitting else { return }
            guard let track, track.isValid else {
                error = "请先拖动滑块完成验证"
                return
            }
            submitting = true
            defer { submitting = false }
            do {
                let status = try await CoreClient.shared.sourceAccountLogin(
                    source: site.id,
                    identifier: identifier.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password,
                    captchaID: captcha?.id ?? "",
                    track: track
                )
                onDone(status)
            } catch {
                self.error = error.localizedDescription
                // 验证失败要换一张新验证码，否则重试还是过不了。
                await loadCaptcha()
            }
        }
    }
}
