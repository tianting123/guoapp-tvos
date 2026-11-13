import SwiftUI

/// 滑块验证码视图（电视端）。
///
/// tvOS 没有触摸屏，滑块靠遥控器左右方向键拖动 —— 上游 Flutter 端在电视上
/// 也是同样的做法（左右键每次 4 像素）。按住左右键连续移动会累积成一串
/// move 点，松开时补一个 up 点，交��核心校验。
///
/// 背景图是带缺口的图，模板图是要拖过去的那块；用户需要把模板对准缺口。
/// 这里只呈现，不做图像识别，位置由用户自己判断。
struct SliderCaptchaView: View {
    let captcha: SourceCaptcha
    /// 拖动结束时回调完整轨迹。参数为 nil 表示本次没真正拖动。
    let onTrack: (CaptchaTrack?) -> Void

    @State private var recorder = CaptchaTrackRecorder()
    /// 显示宽度（点），实际高度按图片比例算。
    @State private var displayWidth: CGFloat = 520
    @FocusState private var focused: Bool

    /// 可拖动的最大距离（点）：背景图宽度减去模板图宽度。
    private var limit: CGFloat {
        max(0, CGFloat(captcha.backgroundWidth - captcha.templateWidth))
    }

    /// 按图片原始像素记录的拖动偏移（与显示尺寸无关）。
    private var pixelOffset: CGFloat {
        let scale = CGFloat(captcha.backgroundWidth) / max(displayWidth, 1)
        return recorder.currentOffset * scale
    }

    var body: some View {
        VStack(spacing: 22) {
            sliderArea
            instruction
        }
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        // 方向键拖动：右加左减，每步 4 点（与上游一致）。
        .onMoveCommand { direction in
            switch direction {
            case .right:
                if !recorder.isDragging { recorder.begin() }
                recorder.move(by: CaptchaTrackRecorder.keyStep)
            case .left:
                if !recorder.isDragging { recorder.begin() }
                recorder.move(by: -CaptchaTrackRecorder.keyStep)
            default:
                break
            }
        }
        // 确认键 = 松手，提交轨迹。
        .onPlayPauseCommand { submit() }
    }

    private var sliderArea: some View {
        ZStack(alignment: .topLeading) {
            // 背景图（带缺口）
            if let image = captchaImage(captcha.backgroundImage) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: displayWidth)
            }
            // 拼图模板：跟随拖动偏移
            if let image = captchaImage(captcha.templateImage) {
                let scale = displayWidth / CGFloat(max(captcha.backgroundWidth, 1))
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: CGFloat(captcha.templateWidth) * scale)
                    .offset(x: pixelOffset * (displayWidth / CGFloat(max(captcha.backgroundWidth, 1))))
            }
            // 焦点提示边框
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(focused ? Color.white : Color.clear, lineWidth: 3)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }

    private var instruction: some View {
        Text("按遥控器左右方向键拖动拼图到缺口位置，按「播放/暂停」确认")
            .font(.system(size: 20))
            .foregroundColor(.secondary)
    }

    /// 提交当前轨迹。不足两个点（没真正拖过）时回调 nil。
    private func submit() {
        guard var track = recorder.finish() else {
            onTrack(nil)
            return
        }
        // 补上图片尺寸：核心会校验这几个字段必须在 1...4000 之间。
        track.backgroundWidth = captcha.backgroundWidth
        track.backgroundHeight = captcha.backgroundHeight
        track.templateWidth = captcha.templateWidth
        track.templateHeight = captcha.templateHeight
        onTrack(track)
    }

    /// 解析 data:image/... 的 base64 内联图片。
    private func captchaImage(_ data: String) -> UIImage? {
        guard let comma = data.firstIndex(of: ",") else { return nil }
        let base64 = String(data[data.index(after: comma)...])
        guard let raw = Data(base64Encoded: base64) else { return nil }
        return UIImage(data: raw)
    }
}
