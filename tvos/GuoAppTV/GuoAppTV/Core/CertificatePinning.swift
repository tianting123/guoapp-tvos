import Foundation
import Security
import CommonCrypto

/// 证书固定（certificate pinning）：只信任**指定的那一张**服务器证书。
///
/// 家庭 NAS（fnOS / 群晖）常用自签名证书，而且用 IP 直连时证书的 CN / SAN
/// 里根本没有那个 IP（fnOS 是 `CN=fnOS`，SAN 只有 `DNS:fnOS`），
/// 系统会直接拒绝握手、报「证书无效 / 可能伪装成 …」。
///
/// 为什么这里只做固定指纹、不提供「跳过证书校验」：后者等于放弃中间人防护，
/// 账号密码会裸奔给任何能劫持连接的人（同一个 WiFi 下的设备就能做）。
/// 固定指纹则只放行**这一张**证书 —— 换成别的证书（伪造的）照样被拒。
/// 用户若确实要禁用校验，需要在自己的开发环境里自行改动，本仓库不内置该开关。
///
/// 指纹是证书 DER 字节的 SHA-256（十六进制，不含冒号）。
/// 取指纹（在 Mac 上，cert 是从浏览器导出的 .cer）：
/// ```sh
/// openssl x509 -inform DER -in cert.cer -noout -fingerprint -sha256
/// ```
enum CertificatePinning {
    /// 归一化用户填写的指纹：去掉冒号、空格，转大写。
    static func normalize(_ text: String) -> String {
        text.uppercased().filter { $0.isHexDigit }
    }

    /// 计算证书 DER 字节的 SHA-256 指纹（大写十六进制）。
    static func fingerprint(of certificate: SecCertificate) -> String? {
        guard let data = SecCertificateCopyData(certificate) as Data? else { return nil }
        return fingerprint(of: data)
    }

    /// 计算 DER 字节的 SHA-256 指纹（大写十六进制）。
    static func fingerprint(of data: Data) -> String? {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            _ = CC_SHA256(base, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    /// 校验挑战里的证书是否是我们指定的那张。
    ///
    /// - Parameters:
    ///   - challenge: 服务端的 TLS 挑战。
    ///   - expected: 用户填的指纹（已归一化）。
    /// - Returns: 匹配返回 true。
    static func matches(challenge: URLAuthenticationChallenge, expected: String) -> Bool {
        let wanted = normalize(expected)
        guard !wanted.isEmpty else { return false }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return false
        }
        // 取证书链里的全部证书，任一张的指纹匹配即通过。
        // （自签名证书的链通常只有一张；有些服务器会多带一张中间证书。）
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] {
            for certificate in chain {
                if let actual = fingerprint(of: certificate), actual == wanted {
                    return true
                }
            }
        }
        return false
    }
}

/// 放行固定指纹证书的 URLSession delegate。
///
/// 只在用户**明确填写了指纹**时使用；未填写就走系统默认校验，
/// 不会因为这个类而降低任何安全性。
final class PinnedCertificateDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    /// 用户填写的指纹（归一化后的大写十六进制）。
    private let expected: String

    init(expected: String) {
        self.expected = CertificatePinning.normalize(expected)
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard !expected.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard CertificatePinning.matches(challenge: challenge, expected: expected),
              let trust = challenge.protectionSpace.serverTrust else {
            // 指纹对不上 → 按系统默认处理（拒绝）。宁可连不上，也不能
            // 在用户以为是 A 服务器的时候连上 B 服务器。
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
