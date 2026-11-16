import Testing
@testable import GuoAppLogic

/// SMB2 报文签名（MS-SMB2 3.1.4.1 / 3.2.4.1）。
///
/// 群晖、fnOS 默认要求会话签名：不签就在 SESSION_SETUP 之后被直接断开。
/// 这里用 RFC 4493 的标准 AES-CMAC 测试向量验证实现，再用报文级用例验证
/// 「签名区置零 + 覆盖除签名区以外全部内容」这条规则。
struct SMB2SigningTests {
    private func hex(_ string: String) -> [UInt8] {
        let cleaned = string.replacingOccurrences(of: " ", with: "")
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            bytes.append(UInt8(cleaned[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    /// RFC 4493 §4 的 AES-128-CMAC 测试向量。
    @Test func aesCMACMatchesRFC4493() {
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c")
        let expected = [
            hex("bb1d6929e95937287fa37d129b756746"),
            hex("070a16b46b4d4144f79bdd9dd04a287c"),
            hex("dfa66747de9ae63030ca32611497c827"),
            hex("51f0bebf7e3b9d92fc49741779363cfe"),
        ]
        let messages = [
            hex(""),
            hex("6bc1bee22e409f96e93d7e117393172a"),
            hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411"),
            hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710"),
        ]
        for (message, want) in zip(messages, expected) {
            let got = SMB2Signing.testAESCMAC(message, key: key)
            #expect(got == want, "AES-CMAC 向量不匹配")
        }
    }

    /// 签名覆盖「除签名区以外的全部内容」，且计算时签名区必须为零。
    @Test func signatureCoversAllButSignatureField() {
        let key = [UInt8](repeating: 0x42, count: 16)
        var message = [UInt8](repeating: 0, count: 64)
        for index in 0..<48 { message[index] = UInt8(index) }
        // 偏移 52-63 属于签名区，放内容不影响签名结果。
        message[52] = 0xAA
        message[60] = 0xBB
        let before = SMB2Signing.testSign(message, sessionKey: key, algorithm: .hmacSHA256)
        // 同样内容、签名区再换别的值：签名应完全相同。
        var other = message
        other[52] = 0x11
        other[60] = 0x22
        let after = SMB2Signing.testSign(other, sessionKey: key, algorithm: .hmacSHA256)
        #expect(before == after)
        // 改了签名区之外的内容：签名必须不同。
        var changed = message
        changed[10] = 0x99
        let different = SMB2Signing.testSign(changed, sessionKey: key, algorithm: .hmacSHA256)
        #expect(before != different)
    }

    /// 签名与校验自洽：签过的报文能校验通过，改一个字节就校验不过。
    @Test func signThenVerify() {
        let key = [UInt8](repeating: 0x11, count: 16)
        var message = [UInt8](repeating: 0, count: 64 + 16)
        for index in 0..<64 { message[index] = UInt8(index % 251) }
        for index in 64..<80 { message[index] = UInt8(index % 199) }

        for algorithm in [SMB2Signing.Algorithm.hmacSHA256, .aesCMAC] {
            SMB2Signing.sign(&message, sessionKey: key, algorithm: algorithm)
            #expect(SMB2Signing.verify(message, sessionKey: key, algorithm: algorithm))
            var tampered = message
            tampered[20] = tampered[20] ^ 0xFF
            #expect(!SMB2Signing.verify(tampered, sessionKey: key, algorithm: algorithm))
        }
    }

    /// 算法按方言选：SMB 3.0 起是 AES-128-CMAC，2.x 是 HMAC-SHA256。
    @Test func algorithmFollowsDialect() {
        #expect(SMB2Signing.Algorithm.select(dialect: 0x0202, signingAlgorithmId: nil) == .hmacSHA256)
        #expect(SMB2Signing.Algorithm.select(dialect: 0x0210, signingAlgorithmId: nil) == .hmacSHA256)
        #expect(SMB2Signing.Algorithm.select(dialect: 0x0300, signingAlgorithmId: nil) == .aesCMAC)
        #expect(SMB2Signing.Algorithm.select(dialect: 0x0302, signingAlgorithmId: nil) == .aesCMAC)
        // 服务端显式指定算法时以它为准。
        #expect(SMB2Signing.Algorithm.select(dialect: 0x0302, signingAlgorithmId: 0x0000) == .hmacSHA256)
        #expect(SMB2Signing.Algorithm.select(dialect: 0x0210, signingAlgorithmId: 0x0001) == .aesCMAC)
    }

    /// 密钥太短或报文太短时不该算签名（否则会写出垃圾签名）。
    @Test func rejectsShortKeyOrMessage() {
        var message = [UInt8](repeating: 0, count: 64)
        let shortKey = [UInt8](repeating: 0, count: 8)
        SMB2Signing.sign(&message, sessionKey: shortKey, algorithm: .hmacSHA256)
        #expect(message[48..<64].allSatisfy { $0 == 0 })
        #expect(!SMB2Signing.verify(message, sessionKey: shortKey, algorithm: .hmacSHA256))
    }
}
