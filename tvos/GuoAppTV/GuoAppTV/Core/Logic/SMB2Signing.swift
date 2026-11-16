import CommonCrypto
import Foundation

/// SMB2 报文签名（MS-SMB2 3.1.4.1 / 3.2.4.1）。
///
/// 群晖、fnOS 默认要求会话签名：不签就在 SESSION_SETUP 之后被直接断开，
/// 表现为「连不上」但看不出原因（NTLMv2 认证本身是对的）。
///
/// 算法按协商到的方言分两种：
/// - **SMB 2.0.2 / 2.1** → HMAC-SHA256(key = 会话密钥, message = 报文前 48 字节 ‖ 报文从偏移 64 起的内容)
/// - **SMB 3.0 / 3.0.2** → AES-128-CMAC(key = 会话密钥, message = 同上)
///
/// 两种算法计算时**签名区（偏移 48-63）都必须全 0** —— 签名覆盖的正是「除签名区以外的全部内容」。
/// 服务端在 SESSION_SETUP 响应里下发会话密钥（Session.Key）。
enum SMB2Signing {
    /// SMB2 头里签名区的偏移与长度。
    static let signatureOffset = 48
    static let signatureLength = 16

    /// 签名算法。
    enum Algorithm {
        case hmacSHA256
        case aesCMAC

        /// 按协商到的方言选算法：SMB 3.0 起默认用 AES-128-CMAC。
        ///
        /// - Parameters:
        ///   - dialect: 服务端选中的方言版本（如 0x0210 = 2.1、0x0302 = 3.0.2）。
        ///   - signingAlgorithmId: SESSION_SETUP 响应里服务端指定的算法 ID（有值时以它为准）。
        static func select(dialect: UInt16, signingAlgorithmId: UInt16?) -> Algorithm {
            // 服务端显式指定了算法就按它来（SMB 3.x 的 negotiate context）。
            if let id = signingAlgorithmId {
                switch id {
                case 0x0000: return .hmacSHA256
                case 0x0001: return .aesCMAC
                default: break
                }
            }
            // SMB 3.0.0（0x0300）起默认 AES-128-CMAC；3.1.1（0x0311）也用它。
            return dialect >= 0x0300 ? .aesCMAC : .hmacSHA256
        }
    }

    /// 用会话密钥给整条 SMB2 报文签名，结果写回报文的签名区。
    ///
    /// - Parameters:
    ///   - message: 完整的 SMB2 报文（头 64 字节 + 负载），不含 NetBIOS 长度前缀。
    ///   - sessionKey: 服务端在 SESSION_SETUP 响应里下发的会话密钥。
    ///   - algorithm: 按方言选出的签名算法。
    /// - Returns: 签名后的报文（原地修改并返回）。
    static func sign(_ message: inout [UInt8], sessionKey: [UInt8], algorithm: Algorithm) {
        guard sessionKey.count >= 16, message.count >= 64 else { return }
        // 签名区先清零 —— 签名覆盖的正是「除签名区以外的全部内容」。
        for index in signatureOffset..<(signatureOffset + signatureLength) {
            message[index] = 0
        }
        let mac = compute(message, sessionKey: sessionKey, algorithm: algorithm)
        let count = min(signatureLength, mac.count)
        for index in 0..<count {
            message[signatureOffset + index] = mac[index]
        }
    }

    /// 校验服务端签名的响应报文（服务端在要求签名时也会给响应签名）。
    /// 校验失败返回 false —— 调用方据此判断是否该信任这个响应。
    static func verify(_ message: [UInt8], sessionKey: [UInt8], algorithm: Algorithm) -> Bool {
        guard sessionKey.count >= 16, message.count >= 64 else { return false }
        let received = Array(message[signatureOffset..<(signatureOffset + signatureLength)])
        // 全 0 表示服务端没签（未要求签名时的正常情况），不当作失败。
        if received.allSatisfy({ $0 == 0 }) { return true }
        var copy = message
        for index in signatureOffset..<(signatureOffset + signatureLength) {
            copy[index] = 0
        }
        let mac = compute(copy, sessionKey: sessionKey, algorithm: algorithm)
        let count = min(signatureLength, mac.count)
        guard count == received.count else { return false }
        // 常量时间比较：签名比对不能用提前返回，避免时序侧信道。
        var difference: UInt8 = 0
        for index in 0..<count {
            difference |= mac[index] ^ received[index]
        }
        return difference == 0
    }

    /// 算出签名值（不含写入报文区的部分）。
    private static func compute(_ message: [UInt8], sessionKey: [UInt8], algorithm: Algorithm) -> [UInt8] {
        switch algorithm {
        case .hmacSHA256:
            // ⚠️ CCHmac 的输出参数是裸指针，不能把 Swift 数组直接传 `&mac` ——
            // 那样写编译能过但函数什么都没写（返回全 0）。必须用
            // withUnsafeMutableBytes 拿到缓冲区指针。
            var mac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            let key = Data(sessionKey)
            let data = Data(message)
            mac.withUnsafeMutableBytes { macBytes in
                key.withUnsafeBytes { keyBytes in
                    data.withUnsafeBytes { messageBytes in
                        CCHmac(
                            CCHmacAlgorithm(kCCHmacAlgSHA256),
                            keyBytes.baseAddress, key.count,
                            messageBytes.baseAddress, message.count,
                            macBytes.baseAddress!
                        )
                    }
                }
            }
            return mac
        case .aesCMAC:
            return aesCMAC(message, key: sessionKey)
        }
    }

    /// AES-128-CMAC（RFC 4493）。
    ///
    /// CommonCrypto 没有暴露 CMAC，这里按 RFC 4493 自己实现：
    /// 子密钥 K1 / K2 由 AES-128 加密全 0 块派生，消息按 16 字节分块做 CBC-MAC，
    /// 最后一块用 K2 异或后加密，完整块用 K1 异或后加密。
    static func testAESCMAC(_ message: [UInt8], key: [UInt8]) -> [UInt8] {
        aesCMAC(message, key: key)
    }

    /// 算签名但不写进报文区（测试用）。
    static func testSign(_ message: [UInt8], sessionKey: [UInt8], algorithm: Algorithm) -> [UInt8] {
        var copy = message
        for index in signatureOffset..<(signatureOffset + signatureLength) {
            copy[index] = 0
        }
        return compute(copy, sessionKey: sessionKey, algorithm: algorithm)
    }

    private static func aesCMAC(_ message: [UInt8], key: [UInt8]) -> [UInt8] {
        guard key.count == 16 else { return [] }
        let zero = [UInt8](repeating: 0, count: 16)
        let l = aesEncrypt(zero, key: key)
        // NIST SP 800-38B §5.3 的子密钥生成：
        //   K1 = shift(L)  （若 L 的最高位为 1，再异或 const_Rb = 0x87）
        //   K2 = shift(K1) （若 K1 的最高位为 1，再异或 const_Rb）
        let k1 = shift(l)
        let k2 = shift(k1)
        // RFC 4493 §2.4：最后一块不足 16 字节时先做 padding(x) = x || 10^i
        //（补一个 1 再补 0 到 16 字节），完整块则直接异或 K1。
        let complete = message.count > 0 && message.count % 16 == 0
        let blocks = complete ? message.count / 16 : message.count / 16 + 1
        // CBC-MAC：除最后一块外逐块异或并加密。
        var x = [UInt8](repeating: 0, count: 16)
        for block in 0..<(blocks - 1) {
            let start = block * 16
            for index in 0..<16 {
                x[index] ^= message[start + index]
            }
            x = aesEncrypt(x, key: key)
        }
        // 最后一块。
        let lastStart = (blocks - 1) * 16
        let tail = Array(message[lastStart..<message.count])
        var last = [UInt8](repeating: 0, count: 16)
        for index in 0..<16 {
            last[index] = index < tail.count ? tail[index] : 0
        }
        if !complete {
            // padding(x) = x || 10^i：补一个 1 再补 0。
            last[tail.count] = 0x80
        }
        // RFC 4493 §2.4 第 6 步：Y := M_last XOR X（X 是前面各块 CBC 后的值）。
        // ⚠️ 少了这一步异或，单块消息仍算对（X 为 0），多块消息就会全错。
        for index in 0..<16 {
            last[index] ^= x[index]
        }
        let mask = complete ? k1 : k2
        for index in 0..<16 {
            last[index] ^= mask[index]
        }
        return aesEncrypt(last, key: key)
    }

    /// CMAC 的子密钥移位：把 16 字节当成**大端整数**左移一位。
    ///
    /// 字节级等价于：`out[i] = (b[i] << 1) | (b[i+1] >> 7)`（i < 15）、`out[15] = b[15] << 1`
    /// —— 最低字节补 0、最高位丢弃。
    /// 当输入的最高字节最高位为 1（进位被丢弃）时，异或 const_Rb = 0x87 到最低字节。
    ///
    /// ⚠️ 这里是**大端**移位，与直觉里「数组下标越大越高位」相反 —— 写反了
    /// 会得到完全不同的 K1/K2，但 CMAC 的中间步骤仍自洽，测试很难一眼看出来。
    private static func shift(_ input: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 16)
        for index in 0..<15 {
            output[index] = (input[index] << 1) | (input[index + 1] >> 7)
        }
        output[15] = input[15] << 1
        // 进位（最高位）被丢弃时，按 RFC 4493 异或 const_Rb。
        if input[0] & 0x80 != 0 {
            output[15] ^= 0x87
        }
        return output
    }

    /// 单块 AES-128 加密（ECB，无填充）。
    private static func aesEncrypt(_ block: [UInt8], key: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 16)
        let input = block
        let outputCount = output.count
        key.withUnsafeBytes { keyBytes in
            input.withUnsafeBytes { inputBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress, key.count,
                        nil,
                        inputBytes.baseAddress, input.count,
                        outputBytes.baseAddress, outputCount,
                        nil
                    )
                }
            }
        }
        return output
    }
}
