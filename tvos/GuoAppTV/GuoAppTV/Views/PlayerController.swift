import Libmpv
import QuartzCore
import SwiftUI
import UIKit

// mpv 播放控制器（从 PlayerView.swift 原样拆出，另加 isPaused、halt()、停止后不再起播，
// 以及推荐页 hero 用的 pause() / resume() / videoSize）：
// 句柄生命周期、事件泵、进度、倍速、后台 / 前台处理。

// MARK: - mpv 事件

/// libmpv 句柄的 Sendable 包装，用于把句柄交给事件队列。
/// libmpv 客户端 API 自身线程安全（mpv client.h："the client API is generally
/// fully thread-safe"）；唯一要求单线程调用的 mpv_wait_event 只在串行的
/// eventQueue 上调用，因此这里的 @unchecked Sendable 有库的线程安全保证兜底。
private struct MpvHandle: @unchecked Sendable {
    let raw: OpaquePointer
}

/// wakeup 回调的上下文：只在创建时写入、此后只读，随句柄一起释放。
/// 回调在任意线程触发，只能通过它拿到控制器与句柄，不能碰 @MainActor 状态。
private struct MpvWakeupContext: Sendable {
    let controller: Unmanaged<PlayerController>
    let handle: MpvHandle
}

/// mpv 的 wakeup 回调。mpv 在自己的 core 线程上调用它，所以必须是非隔离的顶层函数：
/// 若写成 @MainActor 方法里的闭包，Swift 6 会把闭包推断为主线程隔离并在入口插入
/// 运行时检查，mpv 一调就崩（EXC_BREAKPOINT，dispatch_assert_queue 失败）。
/// 这里只把排空事件的工作转交给串行的 eventQueue，不碰任何 @MainActor 状态。
private func mpvWakeup(_ rawContext: UnsafeMutableRawPointer?) {
    guard let rawContext else { return }
    let context = rawContext.assumingMemoryBound(to: MpvWakeupContext.self).pointee
    let controller = context.controller.takeUnretainedValue()
    let handle = context.handle
    controller.eventQueue.async {
        controller.drainEvents(handle: handle.raw)
    }
}

// MARK: - 播放控制器

/// 持有 mpv 句柄，负责换集、进度上报、播完 / 失败通知、弹幕调度。
/// 原版应用用 mpv + decryption_key 解密 CENC 播放；AVPlayer 没有传原始密钥
/// 解密 CENC 的接口，所以这里直接用 MPVKit 的 libmpv，与原版一致。
/// 每次 play() 都新建句柄：decryption-key 必须在 mpv_initialize 之前设置，
/// 而密钥随内容变化，复用句柄无法换密钥。
@MainActor
final class PlayerController: NSObject, ObservableObject {
    @Published var progress = PlaybackProgress(position: 0, duration: 0)
    @Published var endedToken = 0
    @Published var failedToken = 0
    /// 临时诊断面板内容：播放状态、音视频编码、硬解、解密、播放地址。
    @Published var debugInfo = ""
    /// 诊断面板是否打开。
    ///
    /// 之前不管面板开没开，每秒都读 5 个 mpv 属性并拼字符串：
    /// mpv_get_property_string 会跨线程加锁取内核状态，主线程每秒做 5 次
    /// 是白白的开销，弱网时更会跟解码抢 CPU。面板关闭时直接跳过。
    var diagnosticsEnabled = false {
        didSet {
            if diagnosticsEnabled {
                // 刚打开就立刻刷新一次，不用等下一个心跳。
                refreshDebugInfo()
            } else {
                debugInfo = ""
            }
        }
    }
    /// 是否已暂停（播放控件显示暂停 / 播放图标、暂停时不自动隐藏控件）。
    @Published private(set) var isPaused = false
    /// 视频画面的像素尺寸（video-params/w、h）；推荐页 hero 按它选竖屏 / 横屏版式。
    /// 只在变化时发布，起播与停止时清空。
    @Published private(set) var videoSize: CGSize?
    /// 播放中是否不让屏保出现。全屏播放页保持默认 true；推荐页 hero 设为 false，
    /// 屏保按电视的设置出现（App 失去活跃时 enterBackground 会暂停，醒来再续播）。
    var keepsScreenAwake = true
    /// 起播时（含换集、出错重试、画面重建后的重启）先停在第一帧、不出声。推荐页 hero 用：用户暂停后
    /// 预览别的剧，或在加载途中按了暂停，加载完也停着。由调用方维护（hero 暂停 / 继续时一起改）；全屏播放不用。
    var startsPaused = false
    /// 按视频尺寸给出 mpv 的画面摆放选项（nil 尺寸 = 还不知道）。推荐页 hero 用：mpv 起播后不跟随图层尺寸变化，
    /// 所以 hero 的图层固定铺满画布、从不改尺寸，由这里给的边距把画面摆到面板上（HeroLayout.mpvMargins）。
    /// 起播前按 nil 设一次，mpv 报告视频参数（VIDEO_RECONFIG）后按实际尺寸再设。全屏播放不设。
    var framing: ((CGSize?) -> [String: String])?

    /// 事件队列：mpv 事件泵跑在这里；销毁时同步等它排空，避免句柄悬空。
    nonisolated let eventQueue = DispatchQueue(label: "com.duanju.guoapp.tv.mpv-events")

    private var mpv: OpaquePointer?
    private var wakeupContext: UnsafeMutablePointer<MpvWakeupContext>?
    private var metalLayer: CAMetalLayer?
    /// 当前句柄绑定的图层；与 metalLayer 不是同一个时句柄不可复用（须重建指向新层）。
    private var handleLayer: CAMetalLayer?
    private var currentURL: URL?
    private var hasDecryptionKey = false
    /// 最近一次 mpv END_FILE 错误原文（失败页展示用，便于定位起播失败原因）。
    private(set) var lastError = ""
    private var activePlan: PlaybackPlan?
    private var activeDanmakuEnabled = true
    /// 本次播放的倍速：视图重建（切到全屏）续播时沿用，不能掉回 1.0。
    private var activeSpeed: Double = 1.0
    private var pendingPlay: (plan: PlaybackPlan, start: Double, danmakuEnabled: Bool, speed: Double)?
    private let overlay = DanmakuOverlayView()
    private let danmaku = DanmakuEngine()
    private var overlayAttached = false
    private var progressTimer: Timer?
    private var backgroundObservers: [NSObjectProtocol] = []
    private var backgroundObserversInstalled = false
    private var wasPlayingBeforeBackground = false
    /// stop()（退出播放页）之后不再起播：仍在解析中的异步加载晚回来时直接忽略，
    /// 避免已离开的页面在后台起一个没人管、也没人销毁的 mpv 句柄。
    private var stopped = false

    // MARK: - 黑屏自愈

    /// 每次 startPlayback / destroyMpv 递增：延时检查只对当前这一次播放有效。
    private var playbackGeneration = 0
    /// 只让最后一次健康检查生效（起播、回前台、缓冲重试都会安排检查）。
    private var healthCheckToken = 0
    /// 还没拿到时长 / 还在缓冲时重排检查的次数，最多 3 轮（9 秒）。
    private var healthCheckWaits = 0
    /// 本次播放已尝试的画面恢复次数：1 = 重选视频轨 + 软解，2 = 重建句柄，3 = 放弃。
    private var recoveryAttempts = 0
    /// 下一次 startPlayback 用软解起播（MoltenVK 渲染上下文丢失时重建用）。
    private var softwareDecodeForNextPlay = false

    /// 容器视图建好后由 PlayerHostView 调用；play() 若先到则在此补启动。
    func attach(to container: PlayerHostContainerView) {
        let newLayer = container.metalLayer
        let layerChanged = metalLayer.map { $0 !== newLayer } ?? false
        if layerChanged {
            // 先销毁仍指向旧图层的 mpv 句柄、再换图层：保证旧句柄销毁前旧图层仍被强引用。
            destroyMpv()
        }
        metalLayer = newLayer
        if !overlayAttached {
            overlay.frame = container.bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(overlay)
            danmaku.attach(overlay)
            overlayAttached = true
        }
        installBackgroundObservers()
        if layerChanged, let activePlan {
            // 视图重建导致 Metal 层换了：mpv 需重建并指向新层，从当前位置续播。
            startPlayback(plan: activePlan, start: progress.position,
                          danmakuEnabled: activeDanmakuEnabled, speed: activeSpeed)
            return
        }
        if let pending = pendingPlay {
            pendingPlay = nil
            startPlayback(plan: pending.plan, start: pending.start, danmakuEnabled: pending.danmakuEnabled, speed: pending.speed)
        }
    }

    func play(plan: PlaybackPlan, start: Double, danmakuEnabled: Bool, speed: Double = 1.0) {
        guard !stopped else { return }
        guard metalLayer != nil else {
            pendingPlay = (plan, start, danmakuEnabled, speed)
            debugInfo = "正在加载…"
            return
        }
        startPlayback(plan: plan, start: start, danmakuEnabled: danmakuEnabled, speed: speed)
    }

    func stop() {
        stopped = true
        destroyMpv()
        pendingPlay = nil
        activePlan = nil
        danmaku.reset()
        overlay.clear()
        for observer in backgroundObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        backgroundObservers.removeAll()
        backgroundObserversInstalled = false
    }

    func togglePause() {
        guard mpv != nil else { return }
        setFlag("pause", !getFlag("pause"))
        isPaused = getFlag("pause")
        updateIdleTimer()
    }

    /// 明确暂停 / 继续（推荐页 hero 切走或回来时用；不像 togglePause 依赖当前状态）。
    func pause() {
        setPaused(true)
    }

    func resume() {
        setPaused(false)
    }

    private func setPaused(_ paused: Bool) {
        guard mpv != nil else { return }
        setFlag("pause", paused)
        isPaused = getFlag("pause")
        updateIdleTimer()
    }

    /// 视频参数出来了（出第一帧前）：按实际尺寸摆放画面（framing），并立刻更新画面尺寸（不等每秒的计时器）。
    private func videoReconfigured() {
        guard let handle = mpv else { return }
        let width = getInt64("video-params/w")
        let height = getInt64("video-params/h")
        guard width > 0, height > 0 else { return }
        let size = CGSize(width: Double(width), height: Double(height))
        for (name, value) in framing?(size) ?? [:] {
            _ = mpv_set_property_string(handle, name, value)
        }
        if size != videoSize { videoSize = size }
    }

    /// 手动选集时卸下当前文件但保留句柄：旧集立刻停（不再上报进度、不会触发播完），
    /// 新集地址解析好后 play() 复用句柄直接 loadfile，省掉销毁重建。
    /// 与 stop() 的区别：stop() 连句柄一起销毁（退出播放时用）。
    ///
    /// 为什么保留句柄：mpv_initialize 连带 gpu-next / 硬解 / 音频初始化，是切集卡顿的大头；
    /// 复用句柄后切集只做「更新逐集选项 + loadfile」。
    /// 兜底：若复用后新集起不来（解密密钥没随 loadfile 生效等），黑屏自愈的第 2 档会重建句柄。
    func halt() {
        if mpv != nil {
            // stop 会产生 END_FILE(STOP) 事件，事件泵里按 STOP 忽略，不会误判为播完。
            command(["stop"])
        }
        // 进度计时器要停：否则旧集的进度会继续上报，记到新集名下。
        progressTimer?.invalidate()
        progressTimer = nil
        // 恢复系统空闲计时器，屏保才能正常出现（出错页不该让屏一直亮着）。
        UIApplication.shared.isIdleTimerDisabled = false
        activePlan = nil
        pendingPlay = nil
        progress = PlaybackProgress(position: 0, duration: 0)
        isPaused = false
        videoSize = nil
        danmaku.reset()
        overlay.clear()
    }

    /// 出错时停掉句柄：句柄此时状态不可信，直接销毁，重试时照常 load() → play()。
    /// 与 halt() 的区别：halt 只卸下文件、保留句柄（换集用），这里连句柄一起销毁。
    func haltAndDestroy() {
        halt()
        destroyMpv()
    }

    /// 正在播放时禁止系统空闲计时器，避免 tvOS 屏保在看剧时弹出；
    /// 暂停 / 停止 / 切后台时恢复，屏保才能正常出现。
    /// 注意：mpv 不是 AVPlayer，系统不知道在播视频，必须手动关空闲计时器。
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = PlaybackRules.disablesIdleTimer(
            hasPlayer: mpv != nil, paused: getFlag("pause"), keepsScreenAwake: keepsScreenAwake
        )
    }

    func seek(by seconds: Double) {
        command(["seek", "\(seconds)", "relative"])
    }

    /// 播放中实时改倍速（mpv 的 speed 属性可热改，不用重建播放器）。
    ///
    /// 改完原地精确跳转一次，丢掉已排队的旧倍速音频：Apple TV 的 HDMI 输出上 mpv 的 audiounit
    /// 初始化失败（取声道布局报 -10879），回退到 avfoundation 音频输出，而它固定预读 2 秒
    /// （mpv ao_avfoundation.m：device_buffer = samplerate * 2）。只改 speed 时这 2 秒旧倍速音频
    /// 要先播完，画面停顿或音画不同步 2～4 秒；跳转会清空缓冲、重新对齐音画，新倍速立即生效。
    func setSpeed(_ speed: Double) {
        guard let handle = mpv else { return }
        let previous = getDouble("speed")
        var value = speed
        let status = mpv_set_property(handle, "speed", MPV_FORMAT_DOUBLE, &value)
        guard status >= 0, abs(previous - speed) > 0.001 else { return }
        command(["seek", "0", "relative+exact"])
    }

    /// 播放中开关弹幕（全屏播放控件的「弹幕」按钮），不重建播放器。画面重建后的续播、还在等的起播都沿用；
    /// 换集与重试由 PlaybackSession 照设置里的同一开关（danmakuEnabled）传进 play()。
    func setDanmakuEnabled(_ enabled: Bool) {
        activeDanmakuEnabled = enabled
        pendingPlay?.danmakuEnabled = enabled
        danmaku.setEnabled(enabled)
    }

    // MARK: - 播放启动

    private func startPlayback(plan: PlaybackPlan, start: Double, danmakuEnabled: Bool,
                               speed: Double = 1.0, isRecovery: Bool = false) {
        // 自愈重建（isRecovery）必须新建句柄：MoltenVK 渲染上下文可能已丢，旧句柄不可信。
        // 其余情况若句柄还在、且它绑的图层没换，就复用句柄换集（见 reuseHandle）。
        if let handle = mpv,
           PlaybackRules.canReuseHandle(
               hasHandle: true, sameLayer: handleLayer === metalLayer, isRecovery: isRecovery
           ) {
            reuseHandle(handle, plan: plan, start: start, danmakuEnabled: danmakuEnabled, speed: speed)
            return
        }
        destroyMpv()
        playbackGeneration += 1
        healthCheckWaits = 0
        if !isRecovery {
            // 新的一集 / 用户主动重试：恢复硬解与恢复预算；自愈重建时不清，避免无限重建。
            recoveryAttempts = 0
            softwareDecodeForNextPlay = false
        }
        danmaku.configure(plan: plan, enabled: danmakuEnabled)
        guard let url = URL(string: plan.url) else {
            debugInfo = "播放地址无效"
            failedToken += 1
            return
        }
        guard let layer = metalLayer else {
            pendingPlay = (plan, start, danmakuEnabled, speed)
            debugInfo = "正在加载…"
            return
        }
        currentURL = url
        hasDecryptionKey = !plan.decryptionKey.isEmpty
        lastError = ""
        activePlan = plan
        activeDanmakuEnabled = danmakuEnabled
        activeSpeed = speed
        progress = PlaybackProgress(position: 0, duration: 0)
        videoSize = nil
        debugInfo = "正在加载…"

        guard let handle = mpv_create() else {
            debugInfo = "创建播放器失败"
            failedToken += 1
            return
        }
        mpv = handle
        // 句柄绑的图层记下来：图层换了（视图重建）句柄就不能复用，必须重建指向新层。
        handleLayer = layer
        // wid 是 int64，内容为 CAMetalLayer 的对象地址（mpv 不持有引用；
        // 本控制器的 metalLayer 强引用该图层，句柄销毁前图层一直有效）。
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        _ = mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid)
        _ = mpv_set_option_string(handle, "vo", "gpu-next")
        _ = mpv_set_option_string(handle, "gpu-api", "vulkan")
        _ = mpv_set_option_string(handle, "gpu-context", "moltenvk")
        // 默认硬解；黑屏自愈重建时改软解（videotoolbox 对某些编码会「时间在走但不出帧」）。
        let softwareDecode = softwareDecodeForNextPlay
        softwareDecodeForNextPlay = false
        _ = mpv_set_option_string(handle, "hwdec", softwareDecode ? "no" : "videotoolbox")
        _ = mpv_set_option_string(handle, "subs-match-os-language", "yes")
        _ = mpv_set_option_string(handle, "subs-fallback", "yes")
        _ = mpv_set_option_string(handle, "video-rotate", "no")
        if start > 0 {
            _ = mpv_set_option_string(handle, "start", "\(start)")
        }
        _ = mpv_set_option_string(handle, "demuxer-lavf-o", lavfOptions(for: plan).joined(separator: ","))
        _ = mpv_set_option_string(handle, "network-timeout", "20")
        // 播放倍速：来自设置里的播放倍速，打开剧集时生效。
        if speed != 1.0 {
            _ = mpv_set_option_string(handle, "speed", "\(speed)")
        }
        if !plan.local, !plan.headers.isEmpty {
            // 本地代理地址由 Go 核心转发请求头；直连地址才由 mpv 自己带头。
            // 注意：字段值含逗号时 mpv 会按逗号切分，站源的 UA/Referer 通常不含逗号。
            let fields = plan.headers.map { "\($0.key): \($0.value)" }.joined(separator: ",")
            _ = mpv_set_option_string(handle, "http-header-fields", fields)
        }
        if startsPaused {
            _ = mpv_set_option_string(handle, "pause", "yes")
        }
        for (name, value) in framing?(nil) ?? [:] {
            _ = mpv_set_option_string(handle, name, value)
        }
        _ = mpv_request_log_messages(handle, "no")
        let initStatus = mpv_initialize(handle)
        guard initStatus >= 0 else {
            debugInfo = "初始化失败: \(String(cString: mpv_error_string(initStatus)))"
            failedToken += 1
            destroyMpv()
            return
        }
        let contextPointer = UnsafeMutablePointer<MpvWakeupContext>.allocate(capacity: 1)
        contextPointer.initialize(to: MpvWakeupContext(
            controller: Unmanaged.passUnretained(self), handle: MpvHandle(raw: handle)
        ))
        wakeupContext = contextPointer
        mpv_set_wakeup_callback(handle, mpvWakeup, contextPointer)
        command(["loadfile", url.absoluteString, "replace"])
        isPaused = getFlag("pause")
        startProgressTimer()
        updateIdleTimer()
        scheduleVideoHealthCheck()
    }

    /// 复用已有句柄换集：只更新逐集选项再 loadfile，跳过销毁与重新初始化
    /// （mpv_initialize 连带 gpu-next / 硬解 / 音频初始化，是切集卡顿的大头）。
    ///
    /// 兜底：若复用后新集起不来（解密密钥没随 loadfile 生效等），
    /// 黑屏自愈的第 2 档会重建句柄从当前位置续播（见 recoverVideoOutput）。
    private func reuseHandle(_ handle: OpaquePointer, plan: PlaybackPlan, start: Double,
                             danmakuEnabled: Bool, speed: Double) {
        // 让上一轮的健康检查作废（它只对当前这一次播放有效）。
        playbackGeneration += 1
        healthCheckWaits = 0
        // 新的一集是新的���次播放：恢复预算还回去，之后再黑还能救。
        recoveryAttempts = 0
        softwareDecodeForNextPlay = false
        danmaku.configure(plan: plan, enabled: danmakuEnabled)
        guard let url = URL(string: plan.url) else {
            debugInfo = "播放地址无效"
            failedToken += 1
            return
        }
        currentURL = url
        hasDecryptionKey = !plan.decryptionKey.isEmpty
        lastError = ""
        activePlan = plan
        activeDanmakuEnabled = danmakuEnabled
        activeSpeed = speed
        progress = PlaybackProgress(position: 0, duration: 0)
        videoSize = nil
        debugInfo = "正在加载…"
        applyPerFileOptions(handle, plan: plan, start: start, speed: speed)
        command(["loadfile", url.absoluteString, "replace"])
        isPaused = getFlag("pause")
        startProgressTimer()
        updateIdleTimer()
        scheduleVideoHealthCheck()
    }

    /// demuxer 的 libavformat 选项（重试、实验特性、扩展名、协议白名单、解密密钥）：
    /// 首次起播（初始化前）与换集复用句柄（loadfile 前）共用同一份。
    ///
    /// 与 iOS 端 player_screen.dart 一致。注意：不要用 mpv 自身的 decryption-key 选项——
    /// 在此构建下它不生效（时长能读出但时间一直停在 0、无画面无声）。
    /// iOS 端用的是下面 demuxer-lavf-o 这一路，把密钥作为 FFmpeg demuxer 选项直接传给 libavformat。
    private func lavfOptions(for plan: PlaybackPlan) -> [String] {
        var options = [
            "seg_max_retry=3",
            "strict=experimental",
            "allowed_extensions=ALL",
            plan.local
                ? "protocol_whitelist=[file,crypto,data]"
                : "protocol_whitelist=[http,https,tcp,tls,crypto,data,file]",
        ]
        if !plan.decryptionKey.isEmpty {
            options.append("decryption_key=\(plan.decryptionKey)")
        }
        return options
    }

    /// 换集时逐集不同的选项：复用句柄时在 loadfile 前更新。
    /// demuxer 在每次打开文件时按当前选项创建，解密密钥因此随集生效；
    /// 请求头无则清空，避免上一集的头漏给下一集；
    /// 暂停状态与重建句柄时一致（新集默认起播，hero 的 startsPaused 则停在第一帧）。
    private func applyPerFileOptions(_ handle: OpaquePointer, plan: PlaybackPlan,
                                      start: Double, speed: Double) {
        _ = mpv_set_option_string(handle, "demuxer-lavf-o", lavfOptions(for: plan).joined(separator: ","))
        let fields = (!plan.local && !plan.headers.isEmpty)
            ? plan.headers.map { "\($0.key): \($0.value)" }.joined(separator: ",")
            : ""
        _ = mpv_set_option_string(handle, "http-header-fields", fields)
        // 每集都显式写起播点（含 0）：句柄是复用的，不清掉上一集的 start 会漏到下一集。
        _ = mpv_set_option_string(handle, "start", "\(start)")
        var speedValue = speed
        _ = mpv_set_property(handle, "speed", MPV_FORMAT_DOUBLE, &speedValue)
        setFlag("pause", startsPaused)
    }

    private func destroyMpv() {
        playbackGeneration += 1
        healthCheckToken += 1
        progressTimer?.invalidate()
        progressTimer = nil
        // 句柄没了，绑的图层记录也清掉（否则会被误判成可复用）。
        handleLayer = nil
        // 播放器销毁时恢复系统空闲计时器，屏保才能正常出现。
        UIApplication.shared.isIdleTimerDisabled = false
        guard let handle = mpv else { return }
        mpv = nil
        mpv_set_wakeup_callback(handle, nil, nil)
        // 同步等事件队列排空，保证没有 drain 正在用该句柄，再销毁。
        eventQueue.sync {
            mpv_terminate_destroy(handle)
        }
        if let contextPointer = wakeupContext {
            contextPointer.deinitialize(count: 1)
            contextPointer.deallocate()
            wakeupContext = nil
        }
    }

    // MARK: - mpv 事件泵（事件队列线程，不碰 @MainActor 状态）

    /// 排空挂起的 mpv 事件；只处理播完 / 失败，其余忽略。
    /// wait_event 超时 0 = 立即返回，不阻塞。
    nonisolated func drainEvents(handle: OpaquePointer) {
        while true {
            guard let event = mpv_wait_event(handle, 0) else { return }
            let eventId = event.pointee.event_id
            if eventId == MPV_EVENT_NONE || eventId == MPV_EVENT_SHUTDOWN { return }
            if eventId == MPV_EVENT_VIDEO_RECONFIG {
                Task { @MainActor [weak self] in self?.videoReconfigured() }
            }
            if eventId == MPV_EVENT_END_FILE {
                let endFile = event.pointee.data
                    .assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if endFile.reason == MPV_END_FILE_REASON_EOF {
                    Task { @MainActor [weak self] in self?.endedToken += 1 }
                } else if endFile.reason == MPV_END_FILE_REASON_ERROR {
                    let message = String(cString: mpv_error_string(endFile.error))
                    Task { @MainActor [weak self] in
                        self?.lastError = message
                        self?.failedToken += 1
                    }
                }
                // STOP / QUIT / REDIRECT：忽略。
            }
        }
    }

    // MARK: - 黑屏自愈

    /// 起播 / 回前台 / 缓冲等待后，延时检查画面是否真的出来了。
    /// generation + token 双重作废：换集、销毁、又安排了一次新检查时，旧检查直接退出。
    private func scheduleVideoHealthCheck(delay: Double = 3.0) {
        healthCheckToken += 1
        let token = healthCheckToken
        let generation = playbackGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self,
                  self.healthCheckToken == token,
                  self.playbackGeneration == generation,
                  self.mpv != nil,
                  !self.stopped
            else { return }
            self.checkVideoOutput()
        }
    }

    /// 判据只用代码里已验证可靠的 `video-params/w`：时间在走、时长已拿到、
    /// 没暂停也没在缓冲，但视频参数为空 —— 就是「黑屏但有弹幕」。
    private func checkVideoOutput() {
        let position = getDouble("time-pos")
        let duration = getDouble("duration")
        if duration <= 0 || position <= 0 || getFlag("paused-for-cache") {
            // 网络慢时不算黑屏：最多再等 3 轮（9 秒）。
            if healthCheckWaits < 3 {
                healthCheckWaits += 1
                scheduleVideoHealthCheck()
            }
            return
        }
        healthCheckWaits = 0
        if getInt64("video-params/w") > 0 {
            // 画面正常：把恢复预算还回去，之后再黑还能救。
            recoveryAttempts = 0
            return
        }
        recoverVideoOutput()
    }

    private func recoverVideoOutput() {
        guard let handle = mpv, let plan = activePlan, !stopped else { return }
        recoveryAttempts += 1
        switch recoveryAttempts {
        case 1:
            // 轻恢复：用 property 重选视频轨并关掉硬解，不打断播放、不重新缓冲。
            // 旧代码错在用 set_option_string，这里必须是 set_property_string。
            _ = mpv_set_property_string(handle, "vid", "auto")
            _ = mpv_set_property_string(handle, "hwdec", "no")
            debugInfo = "画面恢复 1/2：重选视频轨并切软解"
            scheduleVideoHealthCheck()
        case 2:
            // MoltenVK 上下文可能已丢：重建句柄，从当前位置续播，这次直接软解起播。
            softwareDecodeForNextPlay = true
            startPlayback(plan: plan, start: progress.position,
                          danmakuEnabled: activeDanmakuEnabled, isRecovery: true)
        default:
            // 两次都救不回来就停手，别无限重建；诊断面板里给出可行动提示。
            debugInfo = "画面恢复失败：请按重试或换一条线路"
        }
    }

    // MARK: - 进度与诊断

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        guard mpv != nil else { return }
        let position = getDouble("time-pos")
        let duration = getDouble("duration")
        let paused = getFlag("pause")
        if paused != isPaused { isPaused = paused }
        let width = getInt64("video-params/w")
        let height = getInt64("video-params/h")
        if width > 0, height > 0 {
            let size = CGSize(width: Double(width), height: Double(height))
            if size != videoSize { videoSize = size }
        }
        progress = PlaybackProgress(
            position: position.isFinite ? position : 0,
            duration: duration.isFinite ? duration : 0
        )
        danmaku.tick(
            positionMs: Int(position * 1000),
            durationMs: (duration.isFinite && duration > 0) ? Int(duration * 1000) : 0
        )
        // 诊断面板关闭时不再每秒去问 mpv 要属性：这些 getProperty 调用
        // 都在主线程，累积起来就是「播放时卡卡的」的来源之一。
        guard diagnosticsEnabled else { return }
        updateDebugInfo(position: position, duration: duration)
    }

    /// 每秒刷新诊断面板：状态、编码、硬解、解密、播放地址。
    /// 只在诊断面板打开时调用（见 tick）。
    private func updateDebugInfo(position: Double, duration: Double) {
        guard diagnosticsEnabled else { return }
        refreshDebugInfo(position: position, duration: duration)
    }

    /// 立即重建一次诊断文本（面板打开时或刚打开时调用）。
    private func refreshDebugInfo(position: Double? = nil, duration: Double? = nil) {
        guard mpv != nil else {
            debugInfo = "无播放器"
            return
        }
        var lines: [String] = []
        let paused = getFlag("pause")
        let buffering = getFlag("paused-for-cache")
        let state = paused ? "已暂停" : (buffering ? "缓冲中" : "播放中")
        lines.append("状态: \(state)")
        lines.append("视频: \(getString("video-codec").orDash) 硬解: \(getString("hwdec-current").orDash)")
        lines.append("画面: \(getInt64("video-params/w"))×\(getInt64("video-params/h")) 自愈: \(recoveryAttempts) 次")
        lines.append("音频: \(getString("audio-codec").orDash)")
        lines.append("进度: \(Int(position ?? progress.position)) / \(Int(duration ?? progress.duration)) 秒")
        lines.append("解密: \(hasDecryptionKey ? "有" : "无")")
        if let url = currentURL {
            lines.append("地址: \(url.host ?? "-")\(url.path)")
        }
        if !lastError.isEmpty {
            lines.append("错误: \(lastError)")
        }
        debugInfo = lines.joined(separator: "\n")
    }

    // MARK: - 后台 / 前台

    private func installBackgroundObservers() {
        guard !backgroundObserversInstalled else { return }
        backgroundObserversInstalled = true
        let center = NotificationCenter.default
        backgroundObservers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.enterBackground() }
        })
        backgroundObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.enterForeground() }
        })
    }

    /// 切后台时只暂停，切回前台恢复播放。
    ///
    /// 这里以前用 `mpv_set_option_string(handle, "vid", "no")` 停视频输出、回前台再设
    /// `"vid", "auto"`。那是**黑屏但有弹幕**的元凶：`vid` 在运行中的实例上是 property，
    /// 用 option 写不会立刻生效，反而残留成「下一次 loadfile 的初始值」；换集、换剧或
    /// 前后台通知没成对时，`vid=no` 就一直留着 —— mpv 照常走时间、出声、发进度，
    /// 弹幕浮层照常滚动，唯独不选视频轨，Metal 层只剩黑底。
    /// tvOS 进后台本来就会挂起渲染，不需要手动切视频轨。
    private func enterBackground() {
        guard mpv != nil else { return }
        wasPlayingBeforeBackground = !getFlag("pause")
        setFlag("pause", true)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func enterForeground() {
        guard mpv != nil else { return }
        if wasPlayingBeforeBackground {
            setFlag("pause", false)
        }
        updateIdleTimer()
        // 回前台是 MoltenVK 上下文最容易丢的时机：延时复查一次，黑了就自愈。
        scheduleVideoHealthCheck(delay: 2.0)
    }

    // MARK: - mpv 属性读写

    private func command(_ args: [String]) {
        guard let handle = mpv else { return }
        // 逐个追加：strdup 返回可变指针，append 的参数类型触发单值隐式转换；
        // 用 map 时闭包返回值类型推断不到不可变指针，编译报错。
        var cArgs: [UnsafePointer<CChar>?] = []
        cArgs.reserveCapacity(args.count + 1)
        for arg in args {
            cArgs.append(strdup(arg))
        }
        cArgs.append(nil)
        cArgs.withUnsafeMutableBufferPointer { buffer in
            _ = mpv_command(handle, buffer.baseAddress)
        }
        for pointer in cArgs {
            if let pointer {
                free(UnsafeMutablePointer(mutating: pointer))
            }
        }
    }

    private func getDouble(_ name: String) -> Double {
        guard let handle = mpv else { return 0 }
        var value = Double(0)
        let status = mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value)
        return status >= 0 ? value : 0
    }

    private func getInt64(_ name: String) -> Int64 {
        guard let handle = mpv else { return 0 }
        var value = Int64(0)
        let status = mpv_get_property(handle, name, MPV_FORMAT_INT64, &value)
        return status >= 0 ? value : 0
    }

    private func getFlag(_ name: String) -> Bool {
        guard let handle = mpv else { return false }
        var value: Int32 = 0
        let status = mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value)
        return status >= 0 && value != 0
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let handle = mpv else { return }
        var flag: Int32 = value ? 1 : 0
        _ = mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag)
    }

    private func getString(_ name: String) -> String {
        guard let handle = mpv else { return "" }
        guard let cString = mpv_get_property_string(handle, name) else { return "" }
        defer { mpv_free(cString) }
        return String(cString: cString)
    }
}

private extension String {
    var orDash: String { isEmpty ? "-" : self }
}
