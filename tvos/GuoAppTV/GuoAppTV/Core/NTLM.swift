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

    // MARK: NTLMSSP 的 DER 封装

    /// NTLMSSP 的 OID：1.3.6.1.4.1.311.2.2.10。
    static let ntlmsspOID: [UInt8] = [
        0x06, 0x06, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x02,
    ]

    /// NegTokenInit 的 OID：1.3.6.1.4.1.311.2.2.10。
    static let negTokenInitOID: [UInt8] = [
        0xa0, 0x0e, 0x30, 0x0c,
        0x06, 0x0a, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x02, 0x0a,
    ]

    /// DER 长度编码：短格式（< 0x80）或长格式（0x81/0x82 + 长度字节）。
    private static func derLength(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        if count <= 0xff { return [0x81, UInt8(count)] }
        return [0x82, UInt8((count >> 8) & 0xff), UInt8(count & 0xff)]
    }

    /// 把「标签 + 内容」包成 DER 的 TLV。
    private static func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var out = [tag]
        out.append(contentsOf: derLength(content.count))
        out.append(contentsOf: content)
        return out
    }

    /// 把裸 NTLM 消息包成 NTLMSSP 的 DER 封装（NEGOTIATE 用）。
    ///
    /// 结构（MS-NLMP 2.2.1.1）：
    /// ```
    /// SEQUENCE {
    ///   OID 1.3.6.1.4.1.311.2.2.10
    ///   [0] { SEQUENCE { NegTokenInit { OID, MsvAvFlags, MsvAvTimestamp } } }
    /// }
    /// ```
    /// ⭐ SMB2 的 SecurityBuffer 要的是**这个 DER 结构**，不是裸 OID ——
    /// 只发裸 OID 服务端会返回 STATUS_INVALID_PARAMETER(0xC000000D)。
    static func negotiateSecurityBuffer(domain: String, workstation: String) -> [UInt8] {
        let message = negotiateMessage(domain: domain, workstation: workstation)
        // NegTokenInit：OID + MsvAvFlags(4) + MsvAvTimestamp(8)
        var avPairs = [UInt8]()
        avPairs.append(contentsOf: negTokenInitOID)
        // MsvAvFlags：结构 04 20 + "NTLMSSP\0" + U32(1)
        avPairs.append(0xa2)
        avPairs.append(0x22)
        avPairs.append(0x04)
        avPairs.append(0x20)
        avPairs.append(contentsOf: Array("NTLMSSP\u{0}".utf8))
        avPairs.appendLE(UInt32(1))
        // MsvAvTimestamp：8 字节 0
        avPairs.appendLE(UInt64(0))
        let negToken = der(0x30, avPairs)
        let explicit = der(0xa0, negToken)
        var content = [UInt8]()
        content.append(contentsOf: ntlmsspOID)
        content.append(contentsOf: explicit)
        return der(0x60, content)
    }

    /// 把裸 NTLM 认证消息包成 NTLMSSP 的 DER 封装（AUTHENTICATE 用）。
    ///
    /// 结构与 NEGOTIATE 不同 —— 顶层是 `[1]` 而不是 SEQUENCE：
    /// ```
    /// [1] {
    ///   SEQUENCE {
    ///     [2] { OCTET STRING { "NTLMSSP\0" + NTLM 认证消息 } }
    ///   }
    /// }
    /// ```
    static func authenticateSecurityBuffer(domain: String, username: String, password: String,
                                          serverChallenge: [UInt8], targetInfo: [UInt8],
                                          clientChallenge: [UInt8]) -> [UInt8] {
        let message = authenticateMessage(
            domain: domain,
            username: username,
            password: password,
            serverChallenge: serverChallenge,
            targetInfo: targetInfo,
            clientChallenge: clientChallenge
        )
        // [2] { OCTET STRING { "NTLMSSP\0" + NTLM 消息 } }
        var octet = [UInt8]()
        octet.append(contentsOf: Array("NTLMSSP\u{0}".utf8))
        octet.append(contentsOf: message)
        let explicit2 = der(0xa2, der(0x04, octet))
        let sequence = der(0x30, explicit2)
        return der(0xa1, sequence)
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
    ///
    /// 服务端的响应里，NTLMSSP 消息带 DER 封装：
    /// ```
    /// SEQUENCE { OID, [0] { SEQUENCE { NegTokenInit { OID, MsvAvFlags, MsvAvTimestamp },
    ///                          [1] { type2 消息 } } } }
    /// ```
    ///
    /// ⚠️ **type2 消息以 `"NTLMSSP\0"` 开头，MessageType 在标志之后** ——
    /// 之前按「先找 MessageType=2」定位会找错位置（DER 里到处是 0x02 0x00 0x00 0x00）。
    /// 正确做法：先找 `"NTLMSSP\0"` 标志，字段偏移都以标志起点为基准
    /// （MS-NLMP 2.2.2.1）：
    /// ```
    /// 0  "NTLMSSP\0"(8)   24 ServerChallenge(8)     40 TargetInfoLen(2)
    /// 8  MessageType(4)   32 Reserved(8)            42 TargetInfoMaxLen(2)
    /// 12 TargetNameLen(2)                            44 TargetInfoOffset(4)
    /// 16 TargetNameOffset(4)  20 Flags(4)            48 Version(8)
    /// ```
    static func parseChallenge(_ data: [UInt8]) -> (serverChallenge: [UInt8], targetInfo: [UInt8], flags: UInt32)? {
        func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        }
        func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        // 定位 "NTLMSSP\0" 标志（type2 消息的真正起点）。
        let marker: [UInt8] = Array("NTLMSSP\u{0}".utf8)
        guard let markerRange = data.firstRange(of: marker) else { return nil }
        let start = markerRange.lowerBound
        guard data.count >= start + 48 else { return nil }
        let message = Array(data[start...])
        guard read32(message, 8) == MessageType.challenge else { return nil }
        let targetInfoLen = Int(read16(message, 40))
        let targetInfoOffset = Int(read32(message, 44))
        let serverChallengeOffset = 24
        guard message.count >= serverChallengeOffset + 8 else { return nil }
        let challenge = Array(message[serverChallengeOffset..<(serverChallengeOffset + 8)])
        var targetInfo = [UInt8]()
        if targetInfoLen > 0, message.count >= targetInfoOffset + targetInfoLen {
            targetInfo = Array(message[targetInfoOffset..<(targetInfoOffset + targetInfoLen)])
        }
        return (challenge, targetInfo, read32(message, 20))
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

        // NTOWFv2 = HMAC-MD5(NTHash, UTF16LE(Uppercase(User) + Domain))
        let identity = Array((username.uppercased() + domain).utf16).flatMap { unit -> [UInt8] in
            [UInt8(unit & 0xff), UInt8((unit >> 8) & 0xff)]
        }
        let ntowf = HMACMD5.authenticate(identity, key: ntHash)

        // blob（MS-NLMP 2.2.2.7.1 / impacket 的 computeResponseNTLMv2）：
        // 0 RespType(1) + HiRespType(1) + Reserved1(2) + Reserved2(4)
        // 8 Timestamp(8) · 16 ClientChallenge(8) · 24 Reserved(4) · 28 AvPairs
        //
        // ⚠️ Reserved2 是 **4 字节**（之前只写了 2 字节，导致后面所有字段错位）。
        var blob = [UInt8]()
        blob.append(0x01)              // RespType
        blob.append(0x01)              // HiRespType
        blob.appendLE(UInt16(0))       // Reserved1 (2)
        blob.appendLE(UInt32(0))       // Reserved2 (4)
        // 时间戳（Windows FILETIME）
        let timestamp = UInt64(Date().timeIntervalSince1970 * 10_000_000) + 116_444_736_000_000_000
        blob.appendLE(timestamp)
        blob.append(contentsOf: clientChallenge)
        blob.appendLE(UInt32(0))       // Reserved (4)
        blob.append(contentsOf: targetInfo)

        // NTProof = HMAC-MD5(NTOWFv2, ServerChallenge || blob)
        let ntProof = HMACMD5.authenticate(serverChallenge + blob, key: ntowf)

        // ⭐ NT 响应 = NTProof || blob（**不能只发 NTProof** ——
        // 服务端要靠 blob 里的 timestamp / clientChallenge / targetInfo 复算校验）。
        let ntResponse = ntProof + blob

        // 会话密钥 = HMAC-MD5(NTOWFv2, NTProof)
        let sessionKey = HMACMD5.authenticate(ntProof, key: ntowf)

        // 客户端证明：加密的时间戳
        var clientProof = [UInt8]()
        clientProof.appendLE(timestamp)
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

        // 各字段的 UTF-16LE 字节串
        func utf16Bytes(_ units: [UInt16]) -> [UInt8] {
            units.flatMap { unit -> [UInt8] in
                [UInt8(unit & 0xff), UInt8((unit >> 8) & 0xff)]
            }
        }
        let domainBytes = utf16Bytes(domainUTF16)
        let usernameBytes = utf16Bytes(usernameUTF16)
        let workstationBytes = utf16Bytes(workstation)

        // MS-NLMP 2.2.2.3 AUTHENTICATE_MESSAGE。
        //
        // ⭐ 关键：**每个字段都是「长度 + 偏移」分离的**，偏移是相对消息起点
        // （这里以 "NTLMSSP\0" 标志起算）的**绝对位置**，字段顺序可以任意 ——
        // 服务端完全按 offset 指路去取数据。之前用「按顺序拼接」的方式，
        // 群晖解析出来的长度/偏移全是错的 → STATUS_INVALID_PARAMETER。
        //
        // 布局（以 "NTLMSSP\0" 起点算，与 impacket 的 NTLMAuthChallengeResponse 一致）：
        // 0  "NTLMSSP\0"(8)   16 lanmanOffset(4)  28 domainLen(2)   40 userOffset(4)
        // 8  MessageType(4)   20 ntlmLen(2)      30 domainMax(2)  44 hostLen(2)
        // 12 lanmanLen(2)     22 ntlmMax(2)      32 domainOffset(4) 46 hostMax(2)
        // 14 lanmanMax(2)     24 ntlmOffset(4)   36 userLen(2)     48 hostOffset(4)
        // 52 sessionKeyLen(2) · 54 sessionKeyMax(2) · 56 sessionKeyOffset(4) · 60 flags(4)
        //
        // ⚠️ 数据区从 **64** 开始（Version / MIC 字段不写）——
        // 多写这 24 字节会让所有 offset 整体后移 24，服务端按 offset 取到错位置。
        let headerSize = 64
        var data = [UInt8]()
        let userOffset = headerSize
        data.append(contentsOf: usernameBytes)
        let ntlmOffset = data.count + headerSize
        data.append(contentsOf: ntResponse)
        let domainOffset = data.count + headerSize
        let hostOffset = data.count + headerSize
        let sessionKeyOffset = data.count + headerSize
        data.append(contentsOf: [UInt8](repeating: 0, count: 16))
        let lanmanOffset = data.count + headerSize
        data.append(contentsOf: lmResponse)

        var body = [UInt8]()
        body.append(contentsOf: Array("NTLMSSP\u{0}".utf8))
        body.appendLE(MessageType.authenticate)
        body.appendLE(UInt16(lmResponse.count))   // 12 lanmanLen
        body.appendLE(UInt16(lmResponse.count))   // 14 lanmanMaxLen
        body.appendLE(UInt32(lanmanOffset))       // 16 lanmanOffset
        body.appendLE(UInt16(ntResponse.count))    // 20 ntlmLen
        body.appendLE(UInt16(ntResponse.count))    // 22 ntlmMaxLen
        body.appendLE(UInt32(ntlmOffset))         // 24 ntlmOffset
        body.appendLE(UInt16(domainBytes.count))  // 28 domainLen
        body.appendLE(UInt16(domainBytes.count))  // 30 domainMaxLen
        body.appendLE(UInt32(domainOffset))       // 32 domainOffset
        body.appendLE(UInt16(usernameBytes.count))// 36 userLen
        body.appendLE(UInt16(usernameBytes.count))// 38 userMaxLen
        body.appendLE(UInt32(userOffset))         // 40 userOffset
        body.appendLE(UInt16(workstationBytes.count)) // 44 hostLen
        body.appendLE(UInt16(workstationBytes.count)) // 46 hostMaxLen
        body.appendLE(UInt32(hostOffset))         // 48 hostOffset
        body.appendLE(UInt16(16))                 // 52 sessionKeyLen
        body.appendLE(UInt16(16))                 // 54 sessionKeyMaxLen
        body.appendLE(UInt32(sessionKeyOffset))   // 56 sessionKeyOffset
        body.appendLE(flags)                      // 60 flags
        body.append(contentsOf: data)
        _ = encryptedTimestamp
        return body
    }
}
