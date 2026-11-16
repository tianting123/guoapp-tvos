import Foundation
import Testing
@testable import GuoAppLogic

struct UserFacingErrorTests {
    @Test func networkGoErrors() {
        #expect(UserFacingError.message(for: "Get \"https://x\": dial tcp: lookup x: no such host") == UserFacingError.network)
        #expect(UserFacingError.message(for: "context deadline exceeded (Client.Timeout exceeded while awaiting headers)")
            == UserFacingError.network)
        #expect(UserFacingError.message(for: "read tcp 10.0.0.2:5000->1.2.3.4:443: read: connection reset by peer")
            == UserFacingError.network)
        #expect(UserFacingError.network == "网络连接失败，请检查网络后重试")
    }

    @Test func chineseCoreMessageKept() {
        #expect(UserFacingError.message(for: "该剧暂时没有可播放的分集") == "该剧暂时没有可播放的分集")
    }

    @Test func technicalEnglishBecomesGeneric() {
        #expect(UserFacingError.message(for: "json: cannot unmarshal number into Go value") == UserFacingError.generic)
        #expect(UserFacingError.generic == "加载失败，请稍后重试")
    }

    @Test func emptyBecomesGeneric() {
        #expect(UserFacingError.message(for: "") == UserFacingError.generic)
        #expect(UserFacingError.message(for: "   ") == UserFacingError.generic)
    }

    @Test func urlErrorIsNetwork() {
        #expect(UserFacingError.message(for: URLError(.notConnectedToInternet)) == UserFacingError.network)
    }

    /// 诊断模式：网络类错误仍给出人话，但后面补上原始错误，便于排障。
    @Test func diagnosticKeepsFriendlyTextAndAppendsRaw() {
        let raw = "dial tcp 1.2.3.4:443: connect: connection refused"
        let shown = UserFacingError.diagnosticMessage(for: raw)
        #expect(shown.contains(UserFacingError.network))
        #expect(shown.contains(raw))
    }

    /// 诊断模式：核心给的中文报错原样保留，不重复追加。
    @Test func diagnosticKeepsChineseMessageUnchanged() {
        let raw = "红果 App 接口未返回有效数据"
        #expect(UserFacingError.diagnosticMessage(for: raw) == raw)
    }

    /// 诊断模式：英文技术报错平时变通用句，诊断时能看到原文。
    @Test func diagnosticExposesEnglishTechnicalError() {
        let raw = "json: cannot unmarshal number into Go value"
        let shown = UserFacingError.diagnosticMessage(for: raw)
        #expect(shown.contains(UserFacingError.generic))
        #expect(shown.contains(raw))
    }
}
