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
                    save()
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
            TVTextFieldRow(title: "地址", placeholder: "https://192.168.2.99:6690/backup", text: $settings.webdavURL)
            TVSettingDivider()
            TVTextFieldRow(title: "用户名", placeholder: "填写 NAS 账号", text: $settings.webdavUsername)
            TVSettingDivider()
            TVTextFieldRow(title: "密码", placeholder: "留空表示不修改", text: $webdavPassword, isSecure: true)
            TVSettingDivider()
            TVTextFieldRow(title: "文件名", placeholder: "tv-state.json", text: $settings.webdavFileName)
        }
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
    }

    private func save() {
        var updated = settings
        updated.smbPort = Int(smbPortText) ?? 445
        if !smbPassword.isEmpty {
            settingsStore.setSMBPassword(smbPassword)
            smbPassword = ""
        }
        if !webdavPassword.isEmpty {
            settingsStore.setWebDAVPassword(webdavPassword)
            webdavPassword = ""
        }
        settingsStore.settings = updated
    }

    private func testConnection() async {
        save()
        busy = true
        status = await store.testConnection()
        busy = false
    }

    private func backup() async {
        save()
        busy = true
        await store.backupNow()
        status = store.remoteStatus
        busy = false
    }

    private func restore() async {
        save()
        busy = true
        await store.restoreNow()
        status = store.remoteStatus
        busy = false
    }
}
