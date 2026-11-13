import Foundation

// MARK: - HMAC-MD5

/// HMAC-MD5：NTLMv2 算响应需要。
enum HMACMD5 {
    static func authenticate(_ message: [UInt8], key: [UInt8]) -> [UInt8] {
        let blockSize = 64
        var normalizedKey = key
        if normalizedKey.count > blockSize {
            // key 超长先做一次 MD5 摘要（不是 MD4 —— 那是 NT 哈希用的）。
            normalizedKey = MD5.hexDigest(normalizedKey)
        }
        if normalizedKey.count < blockSize {
            normalizedKey.append(contentsOf: [UInt8](repeating: 0, count: blockSize - normalizedKey.count))
        }
        var innerPad = [UInt8](repeating: 0x36, count: blockSize)
        var outerPad = [UInt8](repeating: 0x5c, count: blockSize)
        for index in 0..<blockSize {
            innerPad[index] ^= normalizedKey[index]
            outerPad[index] ^= normalizedKey[index]
        }
        let inner = MD5.hexDigest(innerPad + message)
        return MD5.hexDigest(outerPad + inner)
    }
}

// MARK: - NTLM

/// NTLM 认证（NTLMv2）：SMB2 SESSION_SETUP 用。
enum NTLM {
    /// NTLM 消息类型。
    enum MessageType {
        static let negotiate: UInt32 = 1
        static let challenge: UInt32 = 2
        static let authenticate: UInt32 = 3
    }

    /// 协商消息：告知支持的版本与能力。
    static func negotiateMessage(domain: String, workstation: String) -> [UInt8] {
        var flags: UInt32 = 0x00008206 | 0x00000200  // NEGOTIATE_UNICODE | NEGOTIATE_OEM | NEGOTIATE_NTLM | REQUEST_TARGET
        flags |= 0x00000001  // NEGOTIATE_SIGN
        flags |= 0x00001000  // NEGOTIATE_EXTENDED_SESSIONSECURITY
        flags |= 0x00008000  // NEGOTIATE_VERSION

        var body = [UInt8]()
        body.appendLE(MessageType.negotiate)
        body.appendLE(flags)
        body.appendLE(UInt16(domain.utf16.count))
        body.appendLE(UInt16(workstation.utf16.count))
        // 域与工作站名是 UTF-16LE
        body.append(contentsOf: Array(domain.utf16).flatMap { unit -> [UInt8] in
            [UInt8(unit & 0xff), UInt8((unit >> 8) & 0xff)]
        })
        body.append(contentsOf: Array(workstation.utf16).flatMap { unit -> [UInt8] in
            [UInt8(unit & 0xff), UInt8((unit >> 8) & 0xff)]
        })
        // 版本：Windows 10 风格
        body.append(10)
        body.append(0)
        body.appendLE(UInt16(19041))
        body.append(0)
        body.append(0)
        body.append(0)
        body.append(0)
        body.append(0)
        body.append(0)
        body.append(0)
        return body
    }

    /// 从服务端挑战消息里取出 server challenge 与 target info。
    static func parseChallenge(_ data: [UInt8]) -> (serverChallenge: [UInt8], targetInfo: [UInt8], flags: UInt32)? {
        guard data.count >= 32 else { return nil }
        func read32(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
        }
        func read16(_ offset: Int) -> UInt16 {
            UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
        guard read32(0) == MessageType.challenge else { return nil }
        let targetNameLen = Int(read16(12))
        let targetInfoLen = Int(read16(40))
        let serverChallengeOffset = 24
        let targetInfoOffset = 48
        guard data.count >= serverChallengeOffset + 8 else { return nil }
        let challenge = Array(data[serverChallengeOffset..<(serverChallengeOffset + 8)])
        var targetInfo = [UInt8]()
        if targetInfoLen > 0, data.count >= targetInfoOffset + targetInfoLen {
            targetInfo = Array(data[targetInfoOffset..<(targetInfoOffset + targetInfoLen)])
        }
        _ = targetNameLen
        return (challenge, targetInfo, read32(20))
    }

    /// 生成认证消息（NTLMv2）。
    static func authenticateMessage(
        domain: String,
        username: String,
        password: String,
        serverChallenge: [UInt8],
        targetInfo: [UInt8],
        clientChallenge: [UInt8]
    ) -> [UInt8] {
        // NT 哈希 = MD4(UTF-16LE(password))
        let passwordUTF16 = Array(password.utf16).flatMap { unit -> [UInt8] in
            [UInt8(unit & 0xff), UInt8((unit >> 8) & 0xff)]
        }
        let ntHash = MD4.hexDigest(passwordUTF16)

        // NT 响应 = HMAC-MD5(NT hash, server challenge || blob)
        var blob = [UInt8]()
        blob.appendLE(UInt16(0x0101))  // ResponseType 1, version 1
        blob.appendLE(UInt16(0))       // HiResponse
        blob.appendLE(UInt16(0))       // HiDomain
        // 时间戳（Windows FILETIME）
        let timestamp = UInt64(Date().timeIntervalSince1970 * 10_000_000) + 116_444_736_000_000_000
        blob.appendLE(timestamp)
        blob.append(contentsOf: clientChallenge)
        blob.appendLE(UInt32(0))       // AvPairs 数量
        blob.appendLE(UInt32(0))       // Reserved
        blob.append(contentsOf: targetInfo)

        let ntResponse = HMACMD5.authenticate(serverChallenge + blob, key: ntHash)

        // 会话密钥 = HMAC-MD5(NT hash, NT response)
        let sessionKey = HMACMD5.authenticate(ntResponse, key: ntHash)

        // 客户端挑战：用 client challenge 加密时间戳
        let timestampLittleEndian = UInt64(timestamp & 0xffffffffffffffff)
        var clientProof = [UInt8]()
        clientProof.appendLE(timestampLittleEndian)
        clientProof.append(contentsOf: clientChallenge)
        clientProof.appendLE(UInt32(0))
        clientProof.appendLE(UInt32(0))
        let encryptedTimestamp = HMACMD5.authenticate(clientProof, key: sessionKey)

        // LM 响应：留空
        let lmResponse = [UInt8](repeating: 0, count: 24)

        // 各种字段
        let domainUTF16 = Array(domain.utf16)
        let usernameUTF16 = Array(username.utf16)
        let workstation = Array("TV".utf16)

        var flags: UInt32 = 0x00008206 | 0x00000200
        flags |= 0x00000001
        flags |= 0x00001000
        flags |= 0x00008000

        var body = [UInt8]()
        body.appendLE(MessageType.authenticate)
        body.appendLE(lmResponse.count)
        body.appendLE(ntResponse.count)
        body.appendLE(domainUTF16.count)
        body.appendLE(usernameUTF16.count)
        body.appendLE(workstation.count)
        body.appendLE(encryptedTimestamp.count)
        body.appendLE(flags)
        body.appendLE(UInt16(0))  // VersionMajor
        body.appendLE(UInt16(10)) // VersionMinor
        body.appendLE(UInt16(19041)) // BuildNumber
        body.append(0)  // Reserved
        body.append(0)
        body.appendLE(UInt16(0))  // PayloadLength

        // NT 响应放在最前
        body.append(contentsOf: ntResponse)
        // 其余按偏移顺序：加密时间戳、域、用户、工作站
        body.append(contentsOf: encryptedTimestamp)
        body.append(contentsOf: domainUTF16.flatMap { unit -> [UInt8] in
            [UInt8(unit & 0xff), UInt8((unit >> 8) & 0xff)]
        })
        body.append(contentsOf: usernameUTF16.flatMap { unit -> [UInt8] in
            [UInt8(unit & 0xff), UInt8((unit >> 8) & 0xff)]
        })
        body.append(contentsOf: workstation.flatMap { unit -> [UInt8] in
            [UInt8(unit & 0xff), UInt8((unit >> 8) & 0xff)]
        })
        return body
    }
}
