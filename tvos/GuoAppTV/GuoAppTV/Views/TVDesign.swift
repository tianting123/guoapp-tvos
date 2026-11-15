import SwiftUI
import UIKit

// MARK: - 电视端设计规范（TV Design System）
//
// 全部电视端页面共用一套设计 token（与 redfruit 设计一致）：暖近黑背景、暖白文字与三档表面、
// 单一绯红强调色、tvOS HIG 字号阶梯（正文不小于 29）、统一圆角与焦点动效。
// 页面不要各自写死颜色和尺寸，一律从这里取值，保证整体设计语言一致。
// 例外：播放页的视频底色保持纯黑（黑边与 OLED 观感）。

enum TVTheme {
    // 布局
    static let pageInset: CGFloat = 64        // 页面左右安全边距
    static let posterPageInset: CGFloat = 32  // 海报页左右边距（pageInset 的一半，海报页用）
    static let sectionSpacing: CGFloat = 40   // 内容分区间距
    static let gridSpacing: CGFloat = 24      // 海报横向间距
    static let posterColumnSpacing: CGFloat = 32 // 海报列间距（比 gridSpacing 大，海报之间更疏）
    static let posterRadius: CGFloat = 14     // 海报圆角

    // 色彩：暖近黑背景 #0E0B0C + 暖白文字 #F5F1EE + 单一绯红强调 #E8364A；
    // 获得焦点的白色底板上用深色字 ink #120A0C。
    static let background = Color(red: 14 / 255, green: 11 / 255, blue: 12 / 255)
    static let accent = Color(red: 232 / 255, green: 54 / 255, blue: 74 / 255)
    static let accentGradient = LinearGradient(
        colors: [
            Color(red: 240 / 255, green: 78 / 255, blue: 96 / 255),
            Color(red: 214 / 255, green: 40 / 255, blue: 60 / 255),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let textPrimary = Color(red: 245 / 255, green: 241 / 255, blue: 238 / 255)
    static let ink = Color(red: 18 / 255, green: 10 / 255, blue: 12 / 255)
    static let textSecondary = textPrimary.opacity(0.72)
    static let textTertiary = textPrimary.opacity(0.55)
    static let surfaceDim = textPrimary.opacity(0.06)
    static let surface = textPrimary.opacity(0.10)
    static let surfaceBright = textPrimary.opacity(0.18)

    // 字号：tvOS HIG 文字样式（pt），正文不小于 body 29，从沙发上也看得清
    enum TextSize {
        /// 推荐页 hero 的剧名（比 title1 更大，从沙发上一眼看清）。
        static let hero: CGFloat = 84
        static let title1: CGFloat = 76
        static let title2: CGFloat = 57
        static let headline: CGFloat = 38
        static let callout: CGFloat = 31
        static let body: CGFloat = 29
        static let caption: CGFloat = 25
        static let caption2: CGFloat = 23
    }

    // 焦点动效：海报 / 卡片放大 10%、胶囊 10%、按钮 6%；0.18 秒缓出，不弹跳
    static let focusScale: CGFloat = 1.10     // 海报卡焦点放大
    static let chipScale: CGFloat = 1.10      // 小胶囊焦点放大
    static let buttonScale: CGFloat = 1.06    // 操作按钮焦点放大
    static let focusRing: CGFloat = 4         // 海报焦点白环宽度（画在海报外侧）
    static let focusAnimation = Animation.easeOut(duration: 0.18)
    static let pressAnimation = Animation.easeOut(duration: 0.12)

    // 海报网格：大屏横向约每行 7 张，随屏宽自适应
    static func posterColumns(minimum: CGFloat = 216) -> [GridItem] {
        [GridItem(.adaptive(minimum: minimum, maximum: minimum * 1.3), spacing: posterColumnSpacing)]
    }

    // 选集网格
    static func episodeColumns(minimum: CGFloat = 232) -> [GridItem] {
        [GridItem(.adaptive(minimum: minimum, maximum: minimum * 1.4), spacing: 16)]
    }
}

/// 应用显示名（火龙果短剧 / 真果鉴，构建时由 GUOAPP_DISPLAY_NAME 写入 Info.plist）。
let tvAppDisplayName: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "火龙果短剧"

/// 秒 → "mm:ss" / "h:mm:ss"，货架、详情、历史共用。
func tvTimecode(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%02d:%02d", minutes, secs)
}

// MARK: - 焦点动效

/// 按压反馈：遥控器确认瞬间轻微下压。
struct TVPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(TVTheme.pressAnimation, value: configuration.isPressed)
    }
}

/// 统一焦点视觉：放大 + 海报外侧白环 + 抬升投影（白环随内容一起放大）。
/// 描边可关闭（自带描边逻辑的组件，如选集按钮）。
private struct TVFocusEffect: ViewModifier {
    var focused: Bool
    var scale: CGFloat
    var cornerRadius: CGFloat
    var stroke: Bool

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius + TVTheme.focusRing, style: .continuous)
                    .strokeBorder(TVTheme.textPrimary, lineWidth: TVTheme.focusRing)
                    .padding(-TVTheme.focusRing)
                    .opacity(focused && stroke ? 1 : 0)
            )
            .scaleEffect(focused ? scale : 1)
            .shadow(color: .black.opacity(focused ? 0.7 : 0), radius: focused ? 25 : 0, y: focused ? 24 : 0)
            .animation(TVTheme.focusAnimation, value: focused)
    }
}

extension View {
    func tvFocusEffect(
        focused: Bool,
        scale: CGFloat = TVTheme.focusScale,
        cornerRadius: CGFloat = TVTheme.posterRadius,
        stroke: Bool = true
    ) -> some View {
        modifier(TVFocusEffect(
            focused: focused, scale: scale, cornerRadius: cornerRadius, stroke: stroke
        ))
    }
}

/// 设置类组件的焦点视觉：白色描边 + 提亮底色 + 轻微放大。
///
/// 与海报卡的 `tvFocusEffect` 分开：设置行是整行通栏的，放大 1.12 倍会顶出
/// 分组圆角容器、显得很躁；这里用 1.02 倍的轻放大，重点靠**白色描边**——
/// 电视是纯黑底，描边是最清晰的选中信号。背景从 surfaceDim 提到
/// surfaceBright，配合描边后即使在 3 米外也能看出焦点在哪一行。
private struct TVSettingFocusEffect: ViewModifier {
    var focused: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(focused ? 1.02 : 1)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(focused ? TVTheme.surfaceBright : TVTheme.surfaceDim)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(focused ? 0.95 : 0), lineWidth: 3)
            )
            .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: focused ? 18 : 0, y: focused ? 8 : 0)
            .animation(TVTheme.focusAnimation, value: focused)
    }
}

extension View {
    /// 设置类组件的焦点反馈。
    func tvSettingFocus(_ focused: Bool) -> some View {
        modifier(TVSettingFocusEffect(focused: focused))
    }
}

// MARK: - 胶囊筛选按钮

/// 分类 / 站源 / 榜单筛选胶囊。
/// 选中态用品牌强调色；焦点态用白底黑字（Apple 风格），层次清晰互不打架。
struct TVChip: View {
    let title: String
    var isSelected = false
    var compact = false
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: compact ? TVTheme.TextSize.caption : TVTheme.TextSize.body, weight: .medium))
                .padding(.horizontal, compact ? 24 : 30)
                .padding(.vertical, compact ? 8 : 12)
                .foregroundColor(foregroundColor)
                .background(Capsule().fill(backgroundColor))
                .overlay(Capsule().strokeBorder(.clear, lineWidth: 0))
        }
        .buttonStyle(TVPressButtonStyle())
        .focused($focused)
        .scaleEffect(focused ? TVTheme.chipScale : 1)
        .zIndex(focused ? 1 : 0)
        .animation(TVTheme.focusAnimation, value: focused)
    }

    private var backgroundColor: Color {
        if focused { return TVTheme.textPrimary }
        if isSelected { return TVTheme.accent }
        return TVTheme.surface
    }

    private var foregroundColor: Color {
        if focused { return TVTheme.ink }
        if isSelected { return TVTheme.textPrimary }
        return TVTheme.textSecondary
    }
}

// MARK: - 操作按钮

/// 主操作按钮：品牌强调色渐变，页面中唯一的强视觉操作。
struct TVPrimaryButton: View {
    let title: String
    var icon: String? = nil
    /// 准备中：图标换成加载圈。
    var isLoading = false
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if isLoading {
                    ProgressView()
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: TVTheme.TextSize.caption, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: TVTheme.TextSize.body, weight: .semibold))
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 19)
            .foregroundColor(focused ? TVTheme.ink : TVTheme.textPrimary)
            .background(Capsule().fill(focused ? AnyShapeStyle(TVTheme.textPrimary) : AnyShapeStyle(TVTheme.accentGradient)))
        }
        .buttonStyle(TVPressButtonStyle())
        .focused($focused)
        .scaleEffect(focused ? TVTheme.buttonScale : 1)
        .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: focused ? 20 : 0, y: focused ? 16 : 0)
        .animation(TVTheme.focusAnimation, value: focused)
    }
}

/// 次操作按钮：未聚焦为半透明表面，聚焦时白底深色字。
struct TVSecondaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: TVTheme.TextSize.caption, weight: .medium))
                }
                Text(title)
                    .font(.system(size: TVTheme.TextSize.body, weight: .medium))
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 19)
            .foregroundColor(focused ? TVTheme.ink : TVTheme.textPrimary)
            .background(Capsule().fill(focused ? TVTheme.textPrimary : TVTheme.surfaceBright))
        }
        .buttonStyle(TVPressButtonStyle())
        .focused($focused)
        .scaleEffect(focused ? TVTheme.buttonScale : 1)
        .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: focused ? 20 : 0, y: focused ? 16 : 0)
        .animation(TVTheme.focusAnimation, value: focused)
    }
}

/// 次操作导航链接：外观与 TVSecondaryButton 完全一致，用于跳页型操作。
/// 走值链接（与全 App 的 Drama 跳转同一机制），不要用闭包目标链接：
/// tvOS 16 上闭包链接会被父视图重绘重复触发，把目标页盖住。
struct TVSecondaryLink<Value: Hashable>: View {
    let title: String
    var icon: String? = nil
    let value: Value

    @FocusState private var focused: Bool

    var body: some View {
        NavigationLink(value: value) {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 26, weight: .medium))
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 19)
            .foregroundColor(TVTheme.textPrimary)
            .background(Capsule().fill(focused ? TVTheme.surfaceBright : TVTheme.surface))
            .overlay(Capsule().strokeBorder(Color.white.opacity(focused ? 0.85 : 0), lineWidth: 3))
        }
        .buttonStyle(TVPressButtonStyle())
        .focused($focused)
        .scaleEffect(focused ? 1.05 : 1)
        .animation(TVTheme.focusAnimation, value: focused)
    }
}

// MARK: - 分区标题

/// 内容分区标题：图标 + 标题 + 可选的右侧补充信息。
struct TVSectionHeader: View {
    let title: String
    var icon: String? = nil
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: TVTheme.TextSize.caption, weight: .semibold))
                    .foregroundColor(TVTheme.accent)
            }
            Text(title)
                .font(.system(size: TVTheme.TextSize.callout, weight: .semibold))
            if let trailing {
                Spacer(minLength: 16)
                Text(trailing)
                    .font(.system(size: TVTheme.TextSize.caption2))
                    .foregroundColor(TVTheme.textTertiary)
            }
        }
    }
}

// MARK: - 进度条

/// 观看进度条：强调色填充，高度由调用方指定。
struct TVProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(TVTheme.textPrimary.opacity(0.14))
                Capsule()
                    .fill(TVTheme.accent)
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
    }
}

// MARK: - 加载与状态视图

/// 行内加载态：转圈 + 说明文字，水平居中。
struct TVLoadingView: View {
    var label: String = "正在加载…"

    /// 支持 `TVLoadingView("xxx")` 位置写法。
    init(_ label: String = "正在加载…") {
        self.label = label
    }

    var body: some View {
        HStack(spacing: 14) {
            ProgressView()
            Text(label)
                .font(.system(size: TVTheme.TextSize.body))
                .foregroundColor(TVTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// 加载失败（redfruit 的 MessageView.failure）：「出了点问题」+ 一句说明（经 UserFacingError 处理）+ 重试。
struct TVFailureView: View {
    let message: String
    let retry: () -> Void

    init(message: String, retry: @escaping () -> Void) {
        self.message = message
        self.retry = retry
    }

    var body: some View {
        VStack(spacing: 28) {
            TVStatusView(icon: "exclamationmark.triangle", title: "出了点问题", message: message, expands: false)
            TVPrimaryButton(title: "重试", icon: "arrow.clockwise", action: retry)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 通用状态视图：空态 / 错误态 / 提示态。
/// `expands` 为 true 时撑满可用空间（页面级空态），false 时按内容收紧（区块内使用）。
struct TVStatusView: View {
    var icon: String = "sparkles"
    var title: String
    var message: String? = nil
    var expands = true

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(TVTheme.surface)
                    .frame(width: 108, height: 108)
                Image(systemName: icon)
                    .font(.system(size: 44, weight: .medium))
                    .foregroundColor(TVTheme.textSecondary)
            }
            Text(title)
                .font(.system(size: TVTheme.TextSize.callout, weight: .semibold))
            if let message {
                Text(message)
                    .font(.system(size: TVTheme.TextSize.body))
                    .foregroundColor(TVTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 660)
            }
        }
        .frame(
            maxWidth: expands ? .infinity : nil,
            maxHeight: expands ? .infinity : nil
        )
    }
}

// MARK: - 选集按钮

/// 选集格子：标题 + VIP 角标 + 已看进度条。
/// 「上次看到」的分集用强调色圆点与描边标出。
struct TVEpisodeButton: View {
    let title: String
    var vip = false
    var progress: Double? = nil
    var isCurrent = false
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if isCurrent {
                        Circle()
                            .fill(TVTheme.accent)
                            .frame(width: 10, height: 10)
                    }
                    Text(title)
                        .font(.system(size: TVTheme.TextSize.caption, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if vip {
                        Text("VIP")
                            .font(.system(size: TVTheme.TextSize.caption2, weight: .bold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(TVTheme.accent))
                            .foregroundColor(TVTheme.textPrimary)
                    }
                }
                if let progress, progress > 0.005 {
                    TVProgressBar(fraction: progress)
                        .frame(height: 5)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(focused ? TVTheme.textPrimary : TVTheme.surface)
            )
            .foregroundColor(focused ? TVTheme.ink : TVTheme.textPrimary)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        focused ? TVTheme.textPrimary : TVTheme.accent.opacity(isCurrent ? 0.85 : 0),
                        lineWidth: focused ? 4 : 2
                    )
            )
        }
        .buttonStyle(TVPressButtonStyle())
        .focused($focused)
        .tvFocusEffect(focused: focused, scale: 1.04, cornerRadius: 14, stroke: false)
        .zIndex(focused ? 1 : 0)
    }
}

// MARK: - 设置页组件

/// 设置分组：小标题 + 圆角分组容器。
struct TVSettingGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: TVTheme.TextSize.callout, weight: .semibold))
                .foregroundColor(TVTheme.textSecondary)
                .padding(.leading, 6)
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(TVTheme.surfaceDim)
            )
        }
    }
}

/// 设置行容器：整行可聚焦，焦点时整行提亮（Apple TV 设置风格）。
struct TVSettingRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                label()
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(TVPressButtonStyle())
        .focused($focused)
        // 焦点态给白色描边：电视纯黑底，背景色变化太弱，描边才看得清。
        .tvSettingFocus(focused)
    }
}

/// 分组内行分隔线。
struct TVSettingDivider: View {
    var body: some View {
        Rectangle()
            .fill(TVTheme.textPrimary.opacity(0.06))
            .frame(height: 1)
            .padding(.leading, 28)
    }
}

/// 迷你开关：设置行右侧的状态指示（选中即切换，无需独立滑块）。
struct TVSwitchMini: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: .center) {
            Capsule()
                .fill(isOn ? TVTheme.accent : TVTheme.textPrimary.opacity(0.22))
                .frame(width: 58, height: 32)
            Circle()
                .fill(TVTheme.textPrimary)
                .frame(width: 26, height: 26)
                .offset(x: isOn ? 13 : -13)
        }
    }
}

/// 值选择行：展示当前值，点按弹出选项面板。
struct TVValueRow: View {
    let title: String
    let value: String
    let action: () -> Void

    var body: some View {
        TVSettingRow(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: TVTheme.TextSize.body, weight: .medium))
                Spacer()
                Text(value)
                    .font(.system(size: TVTheme.TextSize.body))
                    .foregroundColor(TVTheme.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: TVTheme.TextSize.caption2, weight: .semibold))
                    .foregroundColor(TVTheme.textTertiary)
            }
        }
    }
}

/// 开关行：点按整行即切换。
struct TVToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        TVSettingRow {
            isOn.toggle()
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: TVTheme.TextSize.body, weight: .medium))
                Spacer()
                TVSwitchMini(isOn: isOn)
            }
        }
    }
}

// MARK: - 选项弹窗

/// 弹窗选项。
struct TVOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var id: Value { value }
}

/// 设置选项弹窗：tvOS 居中卡片，默认聚焦当前选中项，
/// 遥控器上下移动、确认即选择并关闭。
struct TVOptionSheet<Value: Hashable>: View {
    let title: String
    let options: [TVOption<Value>]
    @Binding var selection: Value

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Value?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: TVTheme.TextSize.headline, weight: .semibold))
                .padding(.bottom, 16)
            ForEach(options) { option in
                Button {
                    selection = option.value
                    dismiss()
                } label: {
                    HStack {
                        Text(option.label)
                            .font(.system(size: TVTheme.TextSize.body, weight: option.value == selection ? .semibold : .regular))
                        Spacer()
                        if option.value == selection {
                            Image(systemName: "checkmark")
                                .font(.system(size: TVTheme.TextSize.caption, weight: .semibold))
                                .foregroundColor(TVTheme.accent)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TVPressButtonStyle())
                .focused($focused, equals: option.value)
                // 弹窗里的选项同样靠白描边区分焦点（背景色差太弱）。
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            Color.white.opacity(focused == option.value ? 0.95 : 0),
                            lineWidth: 3
                        )
                )
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(focused == option.value ? TVTheme.surfaceBright : .clear)
                )
            }
        }
        .padding(32)
        .frame(width: 560)
        .onAppear {
            DispatchQueue.main.async { focused = selection }
        }
    }
}

// MARK: - 内容货架

/// 横向内容货架：分区标题 + 横向滚动卡片列。
/// 焦点在卡片间移动时由系统焦点引擎自动滚动。
struct TVShelfRow<Cards: View>: View {
    let title: String
    var icon: String? = nil
    @ViewBuilder var cards: () -> Cards

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TVSectionHeader(title: title, icon: icon)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: TVTheme.gridSpacing) {
                    cards()
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 2)
            }
        }
    }
}

// MARK: - 文本输入

/// 电视端文本输入行：标题 + 输入框。
///
/// tvOS 上没有 iOS 那种表单，文本框要自己适配遥控器：
/// - 未编辑时整行是一个按钮，点按（Select）进入编辑态；
/// - 编辑态换成真正的 TextField，并把键盘焦点交给它，系统弹出文本编辑面板；
///   点「完成」收起。
///
/// 关键点：**编辑态与显示态必须是两个不同的视图**。若把 Button 和 TextField
/// 放在同一个视图树里，按钮会抢走焦点，TextField 拿不到键盘焦点，
/// 系统文本面板就不会弹出（表现为「怎么点都输不进去」）。
struct TVTextFieldRow: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false

    @State private var editing = false
    /// 行焦点：遥控器导航用。
    @FocusState private var rowFocused: Bool
    /// 输入焦点：系统文本面板用。提到外层是因为 @FocusState 不能声明在
    /// 计算属性里。
    @FocusState private var inputFocused: Bool

    var body: some View {
        Group {
            if editing {
                editingRow
            } else {
                displayRow
            }
        }
        .focused($rowFocused)
        // 编辑态也要保持高亮：进编辑后键盘焦点被 TextField 拿走，行焦点会
        // 变成 false，描边会消失 —— 用户就看不出自己在编辑哪一行了。
        .tvSettingFocus(rowFocused || editing)
    }

    /// 显示态：整行可点按，点一下进入编辑。
    private var displayRow: some View {
        Button {
            editing = true
        } label: {
            HStack(spacing: 16) {
                Text(title)
                    .font(.system(size: 24, weight: .medium))
                    .frame(width: 190, alignment: .leading)
                HStack {
                    Text(text.isEmpty ? placeholder : text)
                        .font(.system(size: 22))
                        .foregroundColor(text.isEmpty ? TVTheme.textTertiary : TVTheme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(TVTheme.textTertiary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(TVPressButtonStyle())
    }

    /// 编辑态：真正的输入控件 + 完成按钮。
    private var editingRow: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 24, weight: .medium))
                .frame(width: 190, alignment: .leading)
            Group {
                if isSecure {
                    SecureField("", text: $text)
                } else {
                    TextField("", text: $text)
                }
            }
            .font(.system(size: 22))
            .foregroundColor(TVTheme.textPrimary)
            .tint(TVTheme.accent)
            .focused($inputFocused)
            Button("完成") {
                inputFocused = false
                editing = false
            }
            .font(.system(size: 20, weight: .medium))
            .foregroundColor(TVTheme.accent)
            .buttonStyle(TVPressButtonStyle())
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // 进入编辑态后把键盘焦点交给输入控件，系统才会弹文本面板。
            DispatchQueue.main.async { inputFocused = true }
        }
    }
}

// MARK: - 作者社交账号

/// 作者的社交账号：B 站与微信公众号不是同一个名字，分别展示。
///
/// tvOS 上没有浏览器、也没有微信，外链点了也打不开，所以只做「从沙发上一眼看得清」的静态展示。
/// 刻意不放可聚焦按钮：默认焦点必须留给剧集海报和播放按钮，别被署名抢走。
enum AuthorSocial {
    static let bilibiliName = "芽芽ol"
    static let wechatName = "芽芽打包酱"
    static let bilibiliLabel = "B 站"
    static let wechatLabel = "公众号"
    static let bilibiliColor = Color(red: 251 / 255, green: 114 / 255, blue: 153 / 255)
    static let wechatColor = Color(red: 7 / 255, green: 193 / 255, blue: 96 / 255)
    /// 长文案里写全两个名字：Swift 会把 ≤15 字节的短字符串内联进指令，打包产物里搜不到连续字节；
    /// 留一句完整文案既方便在电视上读，也让 IPA 能直接核对署名。
    static let searchHint = "B 站搜「芽芽ol」· 公众号搜「芽芽打包酱」"
    static let heroLine = "B 站 · 芽芽ol ／ 公众号 · 芽芽打包酱"
}

/// 单个平台的一行：平台色胶囊 + 该平台自己的账号名。
struct AuthorAccountRow: View {
    let label: String
    let color: Color
    let name: String

    var body: some View {
        HStack(spacing: 16) {
            Text(label)
                .font(.system(size: TVTheme.TextSize.caption2, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 112, alignment: .center)
                .padding(.vertical, 7)
                .background(Capsule().fill(color))
            Text(name)
                .font(.system(size: TVTheme.TextSize.callout, weight: .semibold))
                .foregroundColor(TVTheme.textPrimary)
        }
        .fixedSize()
    }
}

/// 紧凑双行卡片：启动页、推荐页顶部常驻用。
struct AuthorBadge: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("关注作者")
                .font(.system(size: TVTheme.TextSize.caption2, weight: .semibold))
                .foregroundColor(TVTheme.textTertiary)
            AuthorAccountRow(label: AuthorSocial.bilibiliLabel, color: AuthorSocial.bilibiliColor,
                             name: AuthorSocial.bilibiliName)
            AuthorAccountRow(label: AuthorSocial.wechatLabel, color: AuthorSocial.wechatColor,
                             name: AuthorSocial.wechatName)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(TVTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(TVTheme.accent.opacity(0.45), lineWidth: 2)
                )
        )
        .fixedSize()
    }
}

/// 单行横条：剧场页目录顶部用，只占一行高度，不把海报往下推太多。
struct AuthorStrip: View {
    var body: some View {
        HStack(spacing: 28) {
            Text("关注作者")
                .font(.system(size: TVTheme.TextSize.caption2, weight: .bold))
                .foregroundColor(TVTheme.textSecondary)
            AuthorAccountRow(label: AuthorSocial.bilibiliLabel, color: AuthorSocial.bilibiliColor,
                             name: AuthorSocial.bilibiliName)
            AuthorAccountRow(label: AuthorSocial.wechatLabel, color: AuthorSocial.wechatColor,
                             name: AuthorSocial.wechatName)
            Text(AuthorSocial.searchHint)
                .font(.system(size: TVTheme.TextSize.caption2))
                .foregroundColor(TVTheme.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(TVTheme.surfaceDim)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(TVTheme.accent.opacity(0.35), lineWidth: 2)
                )
        )
    }
}

/// 宽版卡片：「我的」页顶部用，两个平台横排 + 搜索提示。
struct AuthorCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("关注作者")
                .font(.system(size: TVTheme.TextSize.caption, weight: .bold))
                .foregroundColor(TVTheme.textSecondary)
            HStack(spacing: 40) {
                AuthorAccountRow(label: AuthorSocial.bilibiliLabel, color: AuthorSocial.bilibiliColor,
                                 name: AuthorSocial.bilibiliName)
                AuthorAccountRow(label: AuthorSocial.wechatLabel, color: AuthorSocial.wechatColor,
                                 name: AuthorSocial.wechatName)
            }
            Text(AuthorSocial.searchHint)
                .font(.system(size: TVTheme.TextSize.caption2))
                .foregroundColor(TVTheme.textTertiary)
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(TVTheme.surfaceDim)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(TVTheme.accent.opacity(0.45), lineWidth: 2)
                )
        )
    }
}
