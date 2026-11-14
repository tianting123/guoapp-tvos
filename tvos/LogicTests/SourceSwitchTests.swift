import Testing
@testable import GuoAppLogic

/// 站源开关：上游把一批站源标成「默认关闭」（defaultOff），
/// 需要用户在设置里手动打开；用户显式改过的开关以用户设置为准。
struct SourceSwitchTests {
    @Test func defaultOffSourcesStartDisabled() {
        #expect(!SourceSwitch.isEnabled(id: "huangdou", switches: [:], defaultOff: true))
        #expect(SourceSwitch.isEnabled(id: "hongguo", switches: [:], defaultOff: false))
    }

    @Test func explicitSwitchWinsOverDefault() {
        let switches = ["huangdou": true, "hongguo": false]
        #expect(SourceSwitch.isEnabled(id: "huangdou", switches: switches, defaultOff: true))
        #expect(!SourceSwitch.isEnabled(id: "hongguo", switches: switches, defaultOff: false))
    }

    @Test func enabledFiltersOutDisabledSources() {
        struct Site { let id: String; let defaultOff: Bool }
        let sites = [
            Site(id: "hongguo", defaultOff: false),
            Site(id: "huangdou", defaultOff: true),
            Site(id: "huangju", defaultOff: true),
        ]
        let none = SourceSwitch.enabled(sites, switches: [:], id: { $0.id }, defaultOff: { $0.defaultOff })
        #expect(none.map { $0.id } == ["hongguo"])

        let some = SourceSwitch.enabled(
            sites,
            switches: ["huangdou": true],
            id: { $0.id },
            defaultOff: { $0.defaultOff }
        )
        #expect(some.map { $0.id } == ["hongguo", "huangdou"])
    }
}
