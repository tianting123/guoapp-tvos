import Foundation

/// 站源账号状态。
///
/// 对应 Go 核心的 `soraniAccountStatus`（fork/sources/provider_sorani_account.go）：
/// `loggedIn` 表示是否已登录，`name` 是账号昵称。
struct SourceAccountStatus: Equatable {
    var loggedIn: Bool
    var name: String

    init(loggedIn: Bool = false, name: String = "") {
        self.loggedIn = loggedIn
        self.name = name
    }

    init(dict: [String: Any]) {
        loggedIn = (dict["loggedIn"] as? NSNumber)?.boolValue ?? (dict["loggedIn"] as? Bool) ?? false
        name = dict["name"] as? String ?? ""
    }
}

/// 滑块验证码。
///
/// 对应 Go 核心的 `soraniCaptcha`：背景图（带缺口的图）+ 拼图模板（要拖的那块），
/// 两张图都是 `data:image/...` 的 base64 内联数据。
struct SourceCaptcha {
    var id: String
    var backgroundImage: String
    var templateImage: String
    var backgroundWidth: Int
    var backgroundHeight: Int
    var templateWidth: Int
    var templateHeight: Int

    init(dict: [String: Any]) {
        id = dict["id"] as? String ?? ""
        backgroundImage = dict["backgroundImage"] as? String ?? ""
        templateImage = dict["templateImage"] as? String ?? ""
        backgroundWidth = (dict["backgroundWidth"] as? NSNumber)?.intValue ?? 0
        backgroundHeight = (dict["backgroundHeight"] as? NSNumber)?.intValue ?? 0
        templateWidth = (dict["templateWidth"] as? NSNumber)?.intValue ?? 0
        templateHeight = (dict["templateHeight"] as? NSNumber)?.intValue ?? 0
    }

    /// 验证码数据是否完整（缺字段时核心会直接拒绝）。
    var isValid: Bool {
        !id.isEmpty
            && backgroundImage.hasPrefix("data:image/")
            && templateImage.hasPrefix("data:image/")
            && backgroundWidth > 0 && backgroundHeight > 0
            && templateWidth > 0 && templateHeight > 0
    }
}

/// 滑块拖动轨迹上的一个点。
///
/// 坐标是相对按下位置的偏移（不是绝对坐标），`type` 取值 down / move / up，
/// `t` 是相对开始时刻的毫秒数。
struct CaptchaPoint: Equatable {
    var x: Int
    var y: Int
    var type: String
    var t: Int64

    var dictionary: [String: Any] {
        ["x": x, "y": y, "type": type, "t": t]
    }
}

/// 滑块拖动轨迹。
///
/// 对应 Go 核心的 `soraniCaptchaTrack`。核心会校验：
/// - 各尺寸字段都在 1...4000 之间；
/// - `startTime > 0` 且 `stopTime >= startTime`；
/// - 点数在 2...5000 之间；
/// - 每个点的 type 必须是 down / move / up，t 不能为负。
struct CaptchaTrack {
    var backgroundWidth: Int
    var backgroundHeight: Int
    var templateWidth: Int
    var templateHeight: Int
    var startTime: Int64
    var stopTime: Int64
    var points: [CaptchaPoint]

    /// 序列化成核心要求的 JSON 结构（键名与 Go 端 struct tag 一致）。
    var dictionary: [String: Any] {
        [
            "bgImageWidth": backgroundWidth,
            "bgImageHeight": backgroundHeight,
            "templateImageWidth": templateWidth,
            "templateImageHeight": templateHeight,
            "startTime": startTime,
            "stopTime": stopTime,
            "trackList": points.map(\.dictionary),
        ]
    }

    /// 本地预校验：不通过就别发给核心，省一次往返。
    var isValid: Bool {
        func inRange(_ value: Int) -> Bool { value > 0 && value <= 4000 }
        guard inRange(backgroundWidth), inRange(backgroundHeight),
              inRange(templateWidth), inRange(templateHeight),
              startTime > 0, stopTime >= startTime,
              points.count >= 2, points.count <= 5000
        else { return false }
        return points.allSatisfy { point in
            (point.type == "down" || point.type == "move" || point.type == "up") && point.t >= 0
        }
    }
}

/// 验证码轨迹采集器：记录遥控器按方向键时的拖动过程。
///
/// tvOS 没有触摸屏，滑块只能靠方向键拖 —— 上游 Flutter 端在电视上也是这么做的
/// （左右键每次 4 像素）。这里记录下每次移动的坐标与时间，最后连同一个 up 点
/// 一起交给核心校验。
@MainActor
final class CaptchaTrackRecorder {
    /// 每次按键移动的像素数（与 Flutter 端一致）。
    static let keyStep: Double = 4

    private var originX: Double?
    private var startedAt: Date?
    private var points: [CaptchaPoint] = []
    private(set) var currentOffset: Double = 0

    /// 开始一次拖动（首次按下方向键时调用）。
    func begin(at time: Date = Date()) {
        guard originX == nil else { return }
        originX = 0
        startedAt = time
        points = []
        currentOffset = 0
        append(x: 0, y: 0, type: "down", at: time)
    }

    /// 移动一步。
    func move(by delta: Double, at time: Date = Date()) {
        guard originX != nil, startedAt != nil else { return }
        let next = max(0, currentOffset + delta)
        currentOffset = next
        append(x: next, y: 0, type: "move", at: time)
    }

    /// 结束拖动，返回完整轨迹。点数不足（没真正拖动）时返回 nil。
    func finish(at time: Date = Date()) -> CaptchaTrack? {
        guard originX != nil, let startedAt, points.count >= 1 else { return nil }
        append(x: currentOffset, y: 0, type: "up", at: time)
        let track = CaptchaTrack(
            backgroundWidth: 0,
            backgroundHeight: 0,
            templateWidth: 0,
            templateHeight: 0,
            startTime: Int64(startedAt.timeIntervalSince1970 * 1000),
            stopTime: Int64(time.timeIntervalSince1970 * 1000),
            points: points
        )
        originX = nil
        self.startedAt = nil
        points = []
        currentOffset = 0
        return track
    }

    /// 取消本次拖动。
    func cancel() {
        originX = nil
        startedAt = nil
        points = []
        currentOffset = 0
    }

    var isDragging: Bool { originX != nil }

    private func append(x: Double, y: Double, type: String, at time: Date) {
        guard let startedAt else { return }
        let elapsed = Int64(time.timeIntervalSince(startedAt) * 1000)
        points.append(CaptchaPoint(x: Int(x.rounded()), y: Int(y.rounded()), type: type, t: elapsed))
    }
}


/// 核心的资源设置（目前只有代理相关）。
///
/// 对应 Go 核心的 `nativeResourceSettings`。代理模式三种：
/// - auto：自动读取系统静态代理与环境变量（默认）
/// - direct：直连，不走代理
/// - manual：使用手动填写的代理地址
struct ResourceSettings {
    var proxyMode: String
    var proxyURL: String
    /// 系统代理状态说明（核心自动检测后给的提示文案）。
    var systemProxyStatus: String
    /// 核心返回的警告（例如代理配置有问题）。
    var warning: String

    init(dict: [String: Any]) {
        proxyMode = dict["proxyMode"] as? String ?? "auto"
        proxyURL = dict["proxyUrl"] as? String ?? ""
        systemProxyStatus = dict["systemProxyStatus"] as? String ?? ""
        warning = dict["warning"] as? String ?? ""
    }

    /// 代理模式的中文名。
    var modeLabel: String {
        switch proxyMode {
        case "direct": return "直连"
        case "manual": return "手动代理"
        default: return "自动（跟随系统）"
        }
    }
}
