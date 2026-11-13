import SwiftUI

/// 设置页：适合电视的分组卡片布局，取代密集的表单。
///
/// - 站源：分组行内直接选择，当前站源打勾；
/// - 播放：开关行点按即切换；清晰度 / 倍速弹出居中选项卡（默认聚焦当前值）；
/// - 关于：版本与说明信息。
/// 配置项与存储键（AppStorage）与原版完全一致。
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var store: Store
    @AppStorage("danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("autoAdvance") private var autoAdvance = true
    @AppStorage("playbackDiagnostics") private var diagnosticsEnabled = false
    @AppStorage("preferredQuality") private var preferredQuality = 0
    @AppStorage("playbackSpeed") private var playbackSpeed = 1.0
    @AppStorage("hardwareDecoder") private var hardwareDecoder = "videotoolbox-copy"

    @State private var activePicker: ActivePicker?
    @State private var showStorage = false
    @State private var showAccounts = false

    /// 弹窗选择的类别。
    private enum ActivePicker: String, Identifiable {
        case quality, speed, decoder
        var id: String { rawValue }
    }

    /// 硬解模式选项。默认 videotoolbox-copy。
    private static let decoderOptions = ["videotoolbox-copy", "videotoolbox", "no"]
    private static func decoderLabel(_ value: String) -> String {
        switch value {
        case "videotoolbox": return "零拷贝（兼容性较差）"
        case "no": return "关闭硬解"
        default: return "拷贝（推荐）"
        }
    }

    /// 清晰度选项：与 iOS 端一致，0 = 自动 · 优先高清。
    private static let qualityOptions = [0, 1080, 720, 480]
    /// 倍速选项：与 iOS 端 playbackSpeeds 一致。
    private static let speedOptions = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    private static func qualityLabel(_ value: Int) -> String {
        value == 0 ? "自动 · 优先高清" : "\(value)P"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TVTheme.sectionSpacing) {
                    sourceGroup
                    playbackGroup
                    storageGroup
                    aboutGroup
                }
                .padding(.horizontal, TVTheme.pageInset)
                .padding(.top, 20)
                .padding(.bottom, 56)
            }
            .sheet(item: $activePicker) { picker in
                pickerSheet(picker)
            }
            .navigationDestination(isPresented: $showStorage) {
                StorageSettingsView()
                    .environmentObject(store)
            }
            .navigationDestination(isPresented: $showAccounts) {
                SourceAccountView()
                    .environmentObject(appState)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSourceAccount)) { _ in
                showAccounts = true
            }
        }
    }

    // MARK: - 站源

    private var sourceGroup: some View {
        TVSettingGroup(title: "站源") {
            let sites = appState.availableSites
            ForEach(Array(sites.enumerated()), id: \.element.id) { index, site in
                if index > 0 {
                    TVSettingDivider()
                }
                TVSettingRow {
                    appState.selectedSource = site.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(site.name)
                                .font(.system(size: 24, weight: .medium))
                            Text(site.description)
                                .font(.system(size: 18))
                                .foregroundColor(TVTheme.textSecondary)
                        }
                        Spacer()
                        if site.id == appState.selectedSource {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 27))
                                .foregroundColor(TVTheme.accent)
                        }
                    }
                }
            }
            // 有站源需要登录或注册设备时才显示这个入口。
            if appState.availableSites.contains(where: { $0.requiresAccount || $0.requiresDeviceRegistration }) {
                TVSettingDivider()
                TVSettingRow {
                    showAccounts = true
                } label: {
                    HStack {
                        Text("站源账号")
                            .font(.system(size: 24, weight: .medium))
                        Spacer()
                        Text("登录与设备注册")
                            .font(.system(size: 20))
                            .foregroundColor(TVTheme.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(TVTheme.textTertiary)
                    }
                }
            }
        }
    }

    // MARK: - 播放

    private var playbackGroup: some View {
        TVSettingGroup(title: "播放") {
            TVToggleRow(title: "弹幕", isOn: $danmakuEnabled)
            TVSettingDivider()
            TVToggleRow(title: "播完自动连播下一集", isOn: $autoAdvance)
            TVSettingDivider()
            TVToggleRow(title: "播放诊断", isOn: $diagnosticsEnabled)
            TVSettingDivider()
            TVValueRow(title: "清晰度", value: Self.qualityLabel(preferredQuality)) {
                activePicker = .quality
            }
            TVSettingDivider()
            TVValueRow(title: "播放倍速", value: String(format: "%.2fx", playbackSpeed)) {
                activePicker = .speed
            }
            TVSettingDivider()
            TVValueRow(title: "硬件解码", value: Self.decoderLabel(hardwareDecoder)) {
                activePicker = .decoder
            }
            TVSettingDivider()
            Text("清晰度、倍速与硬件解码在下一次打开剧集时生效。画面卡顿时可先试「拷贝（推荐）」，不行再换零拷贝。")
                .font(.system(size: 18))
                .foregroundColor(TVTheme.textTertiary)
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
        }
    }

    // MARK: - 存储

    private var storageGroup: some View {
        TVSettingGroup(title: "存储") {
            TVSettingRow {
                showStorage = true
            } label: {
                HStack {
                    Text("追剧与进度")
                        .font(.system(size: 24, weight: .medium))
                    Spacer()
                    Text(storageSummary)
                        .font(.system(size: 20))
                        .foregroundColor(TVTheme.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(TVTheme.textTertiary)
                }
            }
        }
    }

    /// 当前存储方式的一句话摘要。
    private var storageSummary: String {
        let settings = StorageSettingsStore().settings
        switch settings.kind {
        case .local:
            return "仅本机缓存"
        case .smb:
            return "SMB 共享"
        case .webdav:
            return "WebDAV 备份"
        }
    }

    // MARK: - 关于

    private var aboutGroup: some View {
        TVSettingGroup(title: "关于") {
            HStack {
                Text("版本")
                    .font(.system(size: 24, weight: .medium))
                Spacer()
                Text(appVersion)
                    .font(.system(size: 22))
                    .foregroundColor(TVTheme.textSecondary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            aboutNote("原生 tvOS 应用 · Go 核心 · MPV 播放")
            aboutNote("播放时按遥控器 ↑ 放慢、↓ 加快，可实时调整倍速。")
            aboutNote("“最近观看”中按遥控器“播放/暂停”键，可删除该观看记录。")
            aboutNote("“首页”按遥控器“播放/暂停”键，可手动刷新。")
            aboutNote("追剧与观看进度默认存在本机缓存，系统空间不足时可能被清理；可在「存储」里改存到 NAS。")
        }
    }

    private func aboutNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18))
            .foregroundColor(TVTheme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .overlay(alignment: .top) {
                TVSettingDivider()
            }
    }

    // MARK: - 选项弹窗

    @ViewBuilder
    private func pickerSheet(_ picker: ActivePicker) -> some View {
        switch picker {
        case .quality:
            TVOptionSheet(
                title: "清晰度",
                options: Self.qualityOptions.map { TVOption(value: $0, label: Self.qualityLabel($0)) },
                selection: $preferredQuality
            )
        case .speed:
            TVOptionSheet(
                title: "播放倍速",
                options: Self.speedOptions.map { TVOption(value: $0, label: String(format: "%.2fx", $0)) },
                selection: $playbackSpeed
            )
        case .decoder:
            TVOptionSheet(
                title: "硬件解码",
                options: Self.decoderOptions.map { TVOption(value: $0, label: Self.decoderLabel($0)) },
                selection: $hardwareDecoder
            )
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return short.isEmpty ? build : "\(short) (\(build))"
    }
}
