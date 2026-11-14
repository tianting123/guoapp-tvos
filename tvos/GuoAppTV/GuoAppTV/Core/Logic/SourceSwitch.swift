import Foundation

/// 站源开关：判断某个站源当前是否启用。
///
/// 上游 Dart 侧的语义（`LocalStore.sourceEnabled`）：
/// - 用户显式改过的开关，以用户设置为准；
/// - 没改过的，按站源自身的 `defaultOff` 取默认值 —— 默认关闭的源要手动打开。
///
/// tvOS 版之前没接 `defaultOff`，导致核心上报的十几个站源里，
/// 那批「默认关闭」的源既不显示、也无处可开。
enum SourceSwitch {
    /// 某个站源是否启用。
    ///
    /// - Parameters:
    ///   - id: 站源 id。
    ///   - switches: 用户显式设置过的开关（键是站源 id）。
    ///   - defaultOff: 该站源是否默认关闭。
    static func isEnabled(id: String, switches: [String: Bool], defaultOff: Bool) -> Bool {
        if let explicit = switches[id] { return explicit }
        return !defaultOff
    }

    /// 从站源清单里筛出已启用的那些。
    ///
    /// 站源用最小描述表示（Core 那边只保证 id / 默认关闭标记），
    /// 这样这个纯逻辑不依赖应用层模型。
    static func enabled<T>(
        _ sites: [T],
        switches: [String: Bool],
        id: (T) -> String,
        defaultOff: (T) -> Bool
    ) -> [T] {
        sites.filter { isEnabled(id: id($0), switches: switches, defaultOff: defaultOff($0)) }
    }
}
