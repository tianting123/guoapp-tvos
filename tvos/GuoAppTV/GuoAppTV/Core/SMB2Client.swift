import Foundation
import Network

/// SMB2 客户端：tvOS 没有现成的 SMB API，只能自己实现最小可用的那部分。
///
/// 支持的流程：NEGOTIATE → SESSION_SETUP（NTLMv2）→ TREE_CONNECT →
/// CREATE → READ / WRITE → CLOSE。够用来读写共享目录里的一个状态文件。
///
/// 只做 SMB 2.0.2 / 2.1，不支持 SMB1、不支持加密、不支持多通道。
/// Swift 6：连接、握手状态、收发缓冲都是可变状态，
/// 用 actor 隔离，避免跨隔离域传递时报并发错误。
actor SMB2Client {
    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private let domain: String

    private var connection: NWConnection?
    private var sessionId: UInt64 = 0
    private var treeId: UInt32 = 0
    /// 消息 ID：第一条请求用 0，之后每条递增 1。
    ///
    /// 实测群晖会拒绝 MessageId 从 1 开始的连接（直接断开），必须从 0 起。
    private var messageId: UInt64 = 0
    /// 服务端在 NEGOTIATE 响应里给出的会话密钥与签名算法。
    private var sessionKey: [UInt8] = []
    private var signingRequired = false
    /// 服务端选中的方言版本。
    private var serverDialect: UInt16 = 0

    init(host: String, port: Int, username: String, password: String, domain: String = "") {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.domain = domain
    }

    // MARK: - 连接

    /// 建立连接并完成认证。
    func connect() async throws {
        try await openConnection()
        try await negotiate()
        try await sessionSetup()
    }

    /// 断开连接。
    func disconnect() {
        connection?.cancel()
        connection = nil
        sessionId = 0
        treeId = 0
    }

    /// 建立 TCP 连接。
    private func openConnection() async throws {
        let parameters = NWParameters.tcp
        parameters.prohibitExpensivePaths = false
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 445
        )
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // 用一次性门闩保证 continuation 只恢复一次：状态回调可能被多次触发
            // （如 .ready 之后又 .failed），重复恢复会崩。用线程安全的引用计数，
            // 避免在并发闭包里捕获并修改 var（Swift 6 下是错误）。
            let gate = ContinuationGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume()
                case .failed(let error):
                    gate.resume(throwing: error)
                case .cancelled:
                    gate.resume(throwing: SMBError.connectionClosed)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "app.duanju.smb"))
        }
    }

    // MARK: - NEGOTIATE

    private func negotiate() async throws {
        // MS-SMB2 2.2.3.1 NEGOTIATE Request。
        //
        // 布局（少一个字段服务端就会直接断开）：
        // 0 StructureSize(36) · 2 DialectCount · 4 SecurityMode · 6 Reserved
        // 8 Capabilities · 12 ClientGuid(16) · 28 ClientStartTime(8) · 36 Dialects[]
        //
        // ⭐ 只声明到 0x0302（见 SMB2.supportedDialects），所以不需要
        // negotiate context —— 偏移 28 之后是 ClientStartTime，不是
        // ContextOffset/ContextCount。
        var body = [UInt8](repeating: 0, count: 36)
        body[0] = 0x24   // StructureSize = 36
        body[2] = UInt8(SMB2.supportedDialects.count)
        body[4] = 0x01   // SecurityMode: signing enabled
        body[8] = 0x40   // Capabilities = SMB2_GLOBAL_CAP_ENCRYPTION
        // ClientGuid：必须是合法的 RFC 4122 UUID（版本 4），服务端会校验格式。
        var guid = (0..<16).map { _ in UInt8.random(in: 0...255) }
        guid[6] = (guid[6] & 0x0f) | 0x40
        guid[8] = (guid[8] & 0x3f) | 0x80
        for index in 0..<16 {
            body[12 + index] = guid[index]
        }
        // 偏移 28-35：ClientStartTime（8 字节，0 即可）
        // dialect 数组从偏移 36 开始
        for dialect in SMB2.supportedDialects {
            body.append(UInt8(dialect & 0xff))
            body.append(UInt8((dialect >> 8) & 0xff))
        }

        let response = try await send(
            command: SMB2.commandNEGOTIATE,
            body: body,
            treeId: 0,
            sessionId: 0
        )
        guard response.header.command == SMB2.commandNEGOTIATE else {
            throw SMBError.unexpectedResponse
        }
        let status = response.status
        guard status == 0 else { throw SMBError.status(status) }
        // NEGOTIATE 响应结构（MS-SMB2 2.2.3.2）：
        // 0 StructureSize(65) · 2 SecurityMode(2) · 4 DialectRevision(2)
        // 6 NegotiateContextCount/Reserved(2) · 8 ServerGuid(16)
        // 24 Capabilities(4) · 28 MaxTransact(4) · 32 MaxRead(4)
        // 36 MaxWrite(4) · 40 SystemTime(8) · 48 ServerStartTime(8)
        // 56 SecurityBufferOffset(2) · 58 SecurityBufferLength(2)
        // 相对报文头起点，SecurityMode 在 64+2=66，DialectRevision 在 68。
        let responseBytes = [UInt8](response.data)
        if responseBytes.count >= 66 {
            let mode = UInt16(responseBytes[66]) | (UInt16(responseBytes[67]) << 8)
            signingRequired = (mode & 0x0001) != 0
        }
        if responseBytes.count >= 70 {
            let dialect = UInt16(responseBytes[68]) | (UInt16(responseBytes[69]) << 8)
            serverDialect = dialect
        }
        #if DEBUG
        print("[SMB2] NEGOTIATE 成功：方言 0x\(String(serverDialect, radix: 16))，要求签名 \(signingRequired)")
        #endif
    }

    // MARK: - SESSION_SETUP（NTLMv2）

    private func sessionSetup() async throws {
        // MS-SMB2 2.2.5.1 SESSION_SETUP Request：
        // 0 StructureSize(25) · 2 Flags(1) · 3 SecurityMode(1) · 4 Capabilities(4)
        // 8 Channel(4) · 12 SecurityBufferOffset(2) · 14 SecurityBufferLength(2)
        // 16 PreviousSessionId(8) · 24 ← SecurityBuffer 从这里开始（紧跟结构体）
        //
        // ⭐ 两个关键点（都实测过，否则服务端一律回 0xC000000D）：
        // 1. SecurityBufferOffset = 64（头）+ 24（结构体）= **88**，
        //    buffer 必须**紧跟** 24 字节结构体，中间不能有填充。
        // 2. SecurityBuffer 里是 **NTLMSSP 的 DER 封装**，不是裸 NTLM 消息。
        //
        /// 第一步：发送 NTLMSSP NEGOTIATE（DER 封装）。
        let negotiateBuffer = NTLM.negotiateSecurityBuffer(domain: domain, workstation: "TV")
        var firstBody = [UInt8](repeating: 0, count: 24)
        firstBody[0] = 0x19  // StructureSize = 25
        firstBody[2] = 0x00  // Flags
        firstBody[3] = 0x01  // SecurityMode = SMB2_NEGOTIATE_SIGNING_ENABLED
        putLE(&firstBody, 12, UInt16(SMB2.headerSize + 24))   // = 88
        putLE(&firstBody, 14, UInt16(negotiateBuffer.count))
        firstBody.append(contentsOf: negotiateBuffer)

        let first = try await send(
            command: SMB2.commandSESSION_SETUP,
            body: firstBody,
            treeId: 0,
            sessionId: 0
        )
        // 服务端可能直接返回成功（无认证）
        if first.status == 0 {
            sessionId = first.header.sessionId
            return
        }
        guard first.status == 0xc0000016 else { throw SMBError.status(first.status) }
        // 从响应里取出 NTLM 挑战
        let firstBytes = [UInt8](first.data)
        let payload = firstBytes.count > 64 ? Array(firstBytes[64...]) : []
        guard let challenge = NTLM.parseChallenge(payload) else {
            throw SMBError.authenticationFailed
        }

        // 第二步：发送 NTLMSSP AUTHENTICATE（DER 封装）。
        let clientChallenge = (0..<8).map { _ in UInt8.random(in: 0...255) }
        let authenticateBuffer = NTLM.authenticateSecurityBuffer(
            domain: domain,
            username: username,
            password: password,
            serverChallenge: challenge.serverChallenge,
            targetInfo: challenge.targetInfo,
            clientChallenge: clientChallenge
        )
        var secondBody = [UInt8](repeating: 0, count: 24)
        secondBody[0] = 0x19
        secondBody[3] = 0x01  // SecurityMode = signing enabled
        putLE(&secondBody, 12, UInt16(SMB2.headerSize + 24))   // = 88
        putLE(&secondBody, 14, UInt16(authenticateBuffer.count))
        secondBody.append(contentsOf: authenticateBuffer)

        let second = try await send(
            command: SMB2.commandSESSION_SETUP,
            body: secondBody,
            treeId: 0,
            sessionId: first.header.sessionId
        )
        guard second.status == 0 else {
            if second.status == 0xc000006a || second.status == 0xc0000064 {
                throw SMBError.authenticationFailed
            }
            throw SMBError.status(second.status)
        }
        sessionId = second.header.sessionId
        // 解析会话密钥（若服务端下发）
        let secondBytes = [UInt8](second.data)
        if secondBytes.count > 64 {
            let payload = Array(secondBytes[64...])
            // SessionKey 在响应结构偏移 12（Length）+ 16（Offset）
            if payload.count >= 20 {
                let keyLength = Int(UInt16(payload[12]) | (UInt16(payload[13]) << 8))
                let keyOffset = Int(UInt16(payload[16]) | (UInt16(payload[17]) << 8))
                if keyLength > 0, payload.count >= keyOffset + keyLength {
                    sessionKey = Array(payload[keyOffset..<(keyOffset + keyLength)])
                }
            }
        }
    }

    // MARK: - TREE_CONNECT

    /// 连接共享目录。
    func connectShare(_ share: String) async throws {
        let path = "\\\\\(host)\\\(share)"
        // MS-SMB2 2.2.19.1 TREE_CONNECT Request（结构体 8 字节）：
        // 0 StructureSize(9) · 2 Reserved(2) · 4 PathOffset(2) · 6 PathLength(2)
        // 8 路径（UTF-16LE，不含结尾 null）
        //
        // ⚠️ PathOffset 是**相对整个 SMB2 报文起点**（含 64 字节头）的偏移，
        // 必须是 64 + 8 = 72。之前误写成 9（且写进了偏移 6 的 PathLength 字段），
        // 服务端会把报文头当成路径解析，返回 STATUS_INVALID_PARAMETER(0xC000000D)。
        var body = [UInt8](repeating: 0, count: 8)
        body[0] = 0x09  // StructureSize = 9
        // 偏移 2-3：Reserved，保持 0
        // 偏移 4-5：PathOffset = 64（头）+ 8（结构体）= 72
        putLE(&body, 4, UInt16(SMB2.headerSize + 8))
        // 路径字节
        let pathBytes = Array(path.utf16).flatMap { unit -> [UInt8] in
            [UInt8(unit & 0xff), UInt8((unit >> 8) & 0xff)]
        }
        // 偏移 6-7：PathLength
        putLE(&body, 6, UInt16(pathBytes.count))
        body.append(contentsOf: pathBytes)

        let response = try await send(
            command: SMB2.commandTREE_CONNECT,
            body: body,
            treeId: 0,
            sessionId: sessionId
        )
        guard response.status == 0 else {
            if response.status == 0xc0000034 || response.status == 0xc00000cc {
                throw SMBError.shareNotFound(share)
            }
            if response.status == 0xc000006a || response.status == 0xc0000064 {
                throw SMBError.authenticationFailed
            }
            throw SMBError.status(response.status)
        }
        // TreeId 在响应头的偏移 36
        let bytes = [UInt8](response.data)
        guard bytes.count >= 40 else { throw SMBError.unexpectedResponse }
        treeId = UInt32(bytes[36])
            | (UInt32(bytes[37]) << 8)
            | (UInt32(bytes[38]) << 16)
            | (UInt32(bytes[39]) << 24)
    }

    // MARK: - 文件读写

    /// 打开（若不存在则创建）一个文件，返回文件句柄。
    ///
    /// `forWriting` 决定 CreateDisposition：
    /// - 读：OPEN(1) —— 文件不存在就报 STATUS_OBJECT_NAME_NOT_FOUND，
    ///   调用方据此判断「远端还没有数据」；不能建成「不存在则创建」，
    ///   否则读一个不存在的文件反而会把它创建出来，永远等不到 fileNotFound。
    /// - 写：OVERWRITE_IF(4) —— 存在则截断重写，不存在则创建。
    func openFile(_ path: String, forWriting: Bool) async throws -> SMB2FileId {
        // MS-SMB2 2.2.13.1 CREATE Request（结构体 56 字节 + 文件名）：
        // 0  StructureSize(57) · 2 SecurityFlags(1) · 3 RequestedOplockLevel(1)
        // 4  ImpersonationLevel(4) · 8 SmbCreateFlags(8) · 16 Reserved(8)
        // 24 DesiredAccess(4) · 28 FileAttributes(4) · 32 ShareAccess(4)
        // 36 CreateDisposition(4) · 40 CreateOptions(4)
        // 44 NameOffset(2) · 46 NameLength(2)
        // 48 CreateContextsOffset(4) · 52 CreateContextsLength(4)
        // 文件名从 56 开始（NameOffset = 64 + 56 = 120）。
        //
        // 字段必须按下标填：先预分配再 append 会把字段整体推到后面去。
        let nameBytes = Array(path.utf16).flatMap { unit -> [UInt8] in
            [UInt8(unit & 0xff), UInt8((unit >> 8) & 0xff)]
        }
        var body = [UInt8](repeating: 0, count: 56)
        body[0] = 0x39  // StructureSize = 57
        putLE(&body, 24, forWriting ? SMB2.accessReadWrite : SMB2.accessRead) // DesiredAccess
        putLE(&body, 28, SMB2.fileAttributesNormal)  // FileAttributes
        putLE(&body, 32, SMB2.shareReadWrite)        // ShareAccess
        putLE(&body, 36, forWriting ? SMB2.createOverwriteIf : SMB2.createOpen) // CreateDisposition
        putLE(&body, 40, SMB2.createOptions)         // CreateOptions
        putLE(&body, 44, UInt16(120))                // NameOffset
        putLE(&body, 46, UInt16(nameBytes.count))    // NameLength
        body.append(contentsOf: nameBytes)

        let response = try await send(
            command: SMB2.commandCREATE,
            body: body,
            treeId: treeId,
            sessionId: sessionId
        )
        if response.status == 0xc0000034 {
            throw SMBError.fileNotFound(path)
        }
        guard response.status == 0 else {
            throw SMBError.status(response.status)
        }
        // CREATE 响应：FileId 在响应结构偏移 8（Persistent 8 + Volatile 8），
        // 相对报文头起点是 64 + 8 = 72，共 16 字节。
        let bytes = [UInt8](response.data)
        guard bytes.count >= 88 else { throw SMBError.unexpectedResponse }
        return Array(bytes[72..<88])
    }

    /// 关闭文件句柄。
    func closeFile(_ fileId: SMB2FileId) async throws {
        // MS-SMB2 2.2.15.1 CLOSE Request（结构体 24 字节）：
        // 0 StructureSize(25) · 2 Flags(2) · 4 Reserved(4) · 8 FileId(16)
        var body = [UInt8](repeating: 0, count: 24)
        body[0] = 0x19  // StructureSize = 25
        putBytes(&body, 8, fileId)
        _ = try await send(command: SMB2.commandCLOSE, body: body, treeId: treeId, sessionId: sessionId)
    }

    /// 读文件内容。
    func readFile(_ fileId: SMB2FileId, length: Int) async throws -> Data {
        // MS-SMB2 2.2.19.1 READ Request（结构体 48 字节）：
        // 0  StructureSize(49) · 2 Padding(1) · 3 Reserved(1) · 4 Length(4)
        // 8  Offset(8) · 16 FileId(16) · 32 MinimumCount(4) · 36 Channel(4)
        // 40 RemainingBytes(4) · 44 ReadChannelInfoOffset(2) · 46 ReadChannelInfoLength(2)
        var body = [UInt8](repeating: 0, count: 48)
        body[0] = 0x31  // StructureSize = 49
        putLE(&body, 4, UInt32(length))  // Length
        putLE(&body, 8, UInt64(0))       // Offset
        putBytes(&body, 16, fileId)       // FileId（16 字节）
        putLE(&body, 32, UInt32(0))       // MinimumCount
        putLE(&body, 36, UInt32(0))       // Channel
        putLE(&body, 40, UInt32(0))       // RemainingBytes
        putLE(&body, 44, UInt16(0))       // ReadChannelInfoOffset
        putLE(&body, 46, UInt16(0))       // ReadChannelInfoLength

        let response = try await send(
            command: SMB2.commandREAD,
            body: body,
            treeId: treeId,
            sessionId: sessionId
        )
        // STATUS_END_OF_FILE 不算错误
        if response.status == 0xc0000011 {
            return Data()
        }
        guard response.status == 0 else {
            throw SMBError.status(response.status)
        }
        // DataOffset 在结构偏移 12（偏移 64+12 = 76）
        // READ 响应：DataOffset 在结构偏移 12（=64+12=76），DataLength 在 14。
        let bytes = [UInt8](response.data)
        guard bytes.count >= 80 else { return Data() }
        let dataOffset = Int(UInt16(bytes[76]) | (UInt16(bytes[77]) << 8))
        let dataLength = Int(UInt16(bytes[78]) | (UInt16(bytes[79]) << 8))
        guard bytes.count >= dataOffset + dataLength else { return Data() }
        return Data(bytes[dataOffset..<(dataOffset + dataLength)])
    }

    /// 写文件内容（从偏移 0 开始，覆盖写）。
    /// 把文件长度设为指定值（截断或补零）。
    ///
    /// 用 SET_INFO 命令 + FileEndOfFileInformation（信息级别 6）。
    /// 覆盖写时若新内容比旧的短，不截断的话尾部会残留旧字节，
    /// 下次读回来就不是合法 JSON 了。
    func setEndOfFile(_ fileId: SMB2FileId, length: UInt64) async throws {
        // MS-SMB2 2.2.37.5 SET_INFO Request：
        // 0  StructureSize(33) · 2 InfoType(1) · 3 FileInfoClass(1)
        // 4  BufferLength(4) · 8 BufferOffset(2) · 10 Reserved(2)
        // 12 AdditionalInformation(4) · 16 FileId(16)
        // 32 缓冲区（FileEndOfFileInformation：EndOfFile 8 字节）
        //
        // 注意 FileInfoClass 只占 1 字节、InfoType 另占 1 字节：
        //   InfoType = 1 (SMB2_0_INFO_FILE)
        //   FileInfoClass = 6 (FileEndOfFileInformation)
        // 缓冲区偏移 = 64 字节头 + 32 字节结构体 = 96。
        // 布局对照 impacket 的 SMB2SetInfo（smb3structs.py）。
        // 结构体 32 字节 + 8 字节缓冲区 = 40 字节，字段按下标填（不能追加，
        // 追加会整体错位）。
        var body = [UInt8](repeating: 0, count: 40)
        body[0] = 0x21  // StructureSize = 33
        body[2] = 0x01  // InfoType = FILE
        body[3] = 0x06  // FileInfoClass = FileEndOfFileInformation
        putLE(&body, 4, UInt32(8))    // BufferLength
        putLE(&body, 8, UInt16(96))   // BufferOffset = 64 头 + 32 结构体
        // Reserved（10-11）与 AdditionalInformation（12-15）保持 0
        putBytes(&body, 16, fileId)   // FileId（16 字节）
        putLE(&body, 32, length)      // EndOfFile

        let response = try await send(
            command: SMB2.commandSET_INFO,
            body: body,
            treeId: treeId,
            sessionId: sessionId
        )
        guard response.status == 0 else {
            throw SMBError.status(response.status)
        }
    }

    func writeFile(_ fileId: SMB2FileId, data: Data) async throws {
        // MS-SMB2 2.2.23.1 WRITE Request（结构体 48 字节 + 数据）：
        // 0  StructureSize(49) · 2 DataOffset(2) · 4 Length(4) · 8 Offset(8)
        // 16 FileId(16) · 32 Channel(4) · 36 RemainingBytes(4)
        // 40 WriteChannelInfoOffset(2) · 42 WriteChannelInfoLength(2)
        // 44 Flags(4)，数据从 112（=64+48）开始。
        var body = [UInt8](repeating: 0, count: 48)
        body[0] = 0x31  // StructureSize = 49
        putLE(&body, 2, UInt16(112))        // DataOffset
        putLE(&body, 4, UInt32(data.count)) // Length
        putLE(&body, 8, UInt64(0))          // Offset
        putBytes(&body, 16, fileId)         // FileId（16 字节）
        putLE(&body, 32, UInt32(0))         // Channel
        putLE(&body, 36, UInt32(0))         // RemainingBytes
        body.append(contentsOf: data)

        let response = try await send(
            command: SMB2.commandWRITE,
            body: body,
            treeId: treeId,
            sessionId: sessionId
        )
        guard response.status == 0 else {
            throw SMBError.status(response.status)
        }
    }

    // MARK: - 收发

    /// SMB 响应。
    private struct Response {
        var header: SMB2Header
        var status: UInt32
        var data: Data
    }

    /// 发一条请求并等响应。
    private func send(command: UInt16, body: [UInt8], treeId: UInt32, sessionId: UInt64) async throws -> Response {
        guard connection != nil else { throw SMBError.notConnected }
        let currentMessageId = messageId
        messageId &+= 1
        // Flags：请求里一律置 0。签名能力由 NEGOTIATE 的 SecurityMode 声明，
        // 不是靠 Flags —— 设了 SMB2_FLAGS_SIGNING_ENABLED(0x02) 这类旧标志
        // 反而会被服务端当作未知位而直接断开连接。
        let header = SMB2Header(command: command, messageId: currentMessageId, credits: 0, flags: 0)
        // SMB2 头是固定 64 字节，偏移 48-63 是 Signature（16 字节），
        // **没有 BodyLength 字段**（impacket 的 SMB2Packet 也证实）。
        var message = header.encoded()
        message.append(contentsOf: body)
        // NetBIOS over TCP：4 字节长度前缀（1 字节类型 0x00 + 3 字节大端长度）。
        // 必须带长度前缀，否则服务端无法确定报文边界，会直接断开连接。
        var packet = [UInt8](repeating: 0, count: 4)
        let messageLength = UInt32(message.count)
        packet[1] = UInt8((messageLength >> 16) & 0xff)
        packet[2] = UInt8((messageLength >> 8) & 0xff)
        packet[3] = UInt8(messageLength & 0xff)
        packet.append(contentsOf: message)

        #if DEBUG
        print("[SMB2] 发送 \(packet.count) 字节: " + packet.prefix(48).map { String(format: "%02x", $0) }.joined(separator: " "))
        #endif
        try await sendRaw(packet)

        // 读响应。
        // 有些服务端（如群晖的 445 端口）会在客户端发包之前先主动发一个
        // SMB1 的多协议协商邀请（NT LMSSP negotiate），那不是我们要的响应，
        // 跳过它继续读，直到拿到真正的 SMB2 报文。
        var raw = Data()
        for _ in 0..<8 {
            raw = try await receiveRaw()
            if raw.count >= 4, Array(raw.prefix(4)) == SMB2.protocolIdentifier {
                break
            }
            #if DEBUG
            print("[SMB2] 跳过非 SMB2 报文（\(raw.count) 字节）")
            #endif
        }
        #if DEBUG
        print("[SMB2] 收到 \(raw.count) 字节: " + raw.prefix(48).map { String(format: "%02x", $0) }.joined(separator: " "))
        #endif
        guard let parsed = SMB2Header(data: raw) else { throw SMBError.unexpectedResponse }
        // 状态码在头偏移 8。用 [UInt8] 数组取值，不用 Data 的下标：
        // Data 的索引起点不保证是 0（切片后会是 4），下标取值容易踩坑。
        let rawBytes = [UInt8](raw)
        guard rawBytes.count >= 12 else { throw SMBError.unexpectedResponse }
        let status = UInt32(rawBytes[8]) | (UInt32(rawBytes[9]) << 8)
            | (UInt32(rawBytes[10]) << 16) | (UInt32(rawBytes[11]) << 24)
        let result = Response(header: parsed, status: status, data: raw)
        return result
    }

    private func sendRaw(_ bytes: [UInt8]) async throws {
        guard let connection else { throw SMBError.notConnected }
        let content = Data(bytes)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: content, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// 接收缓冲区：NWConnection 一次可能返回多个 SMB2 报文，剩余部分留在这里。
    private var receiveBuffer = Data()

    /// 收一个完整的 SMB2 报文。
    ///
    /// 注意：不能「先读 4 字节长度头，再读 body」—— NWConnection 的 receive
    /// 会一次把能拿到的数据都返回，可能连带把后面的报文也取走。用一个
    /// 缓冲区把多出来的字节留住，下一次从这里接着取。
    private func receiveRaw() async throws -> Data {
        // 缓冲区里已经有完整报文时直接切出来。
        while true {
            if let message = try extractMessageFromBuffer() {
                return message
            }
            let chunk = try await receiveChunk(minimumBytes: 1)
            #if DEBUG
            print("[SMB2] 收到 \(chunk.count) 字节: " + chunk.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " "))
            #endif
            guard !chunk.isEmpty else { throw SMBError.connectionClosed }
            receiveBuffer.append(chunk)
        }
    }

    /// 从缓冲区里切出一个完整报文（NetBIOS 长度前缀 + SMB2 内容）。
    private func extractMessageFromBuffer() throws -> Data? {
        guard receiveBuffer.count >= 4 else { return nil }
        let bytes = [UInt8](receiveBuffer)
        // NetBIOS over TCP：1 字节类型 + 3 字节大端长度。
        var length = 0
        if bytes[0] == 0 {
            length = Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        } else {
            // 1 字节长度格式
            length = Int(bytes[0])
            if length > 0, receiveBuffer.count >= 1 + length {
                let message = Data(receiveBuffer.prefix(1 + length).dropFirst(1))
                receiveBuffer.removeFirst(1 + length)
                return message
            }
            return nil
        }
        guard length > 0, length < 8 * 1024 * 1024 else {
            throw SMBError.unexpectedResponse
        }
        guard receiveBuffer.count >= 4 + length else { return nil }
        // 用 removeFirst 而不是 removeSubrange：Data 的索引起点不保证是 0，
        // removeSubrange(0..<n) 在起点非 0 时会越界崩溃。
        let message = Data(receiveBuffer.prefix(4 + length).dropFirst(4))
        receiveBuffer.removeFirst(4 + length)
        return message
    }

    /// 从连接上读一批数据。
    private func receiveChunk(minimumBytes: Int) async throws -> Data {
        guard let connection else { throw SMBError.notConnected }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: minimumBytes, maximumLength: 65536) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }
}

/// 一次性 continuation 门闩：保证只恢复一次。
///
/// NWConnection 的状态回调可能被多次触发（.ready 之后又 .failed 等），
/// 重复 resume continuation 会崩。这里用锁保证只恢复一次。
private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    /// 恢复（成功）。
    func resume() {
        finish(.success(()))
    }

    /// 恢复（失败）。
    func resume(throwing error: Error) {
        finish(.failure(error))
    }

    private func finish(_ value: Result<Void, Error>) {
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            return
        }
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: value)
    }
}

/// SMB 错误。
enum SMBError: LocalizedError {
    case notConnected
    case connectionClosed
    case unexpectedResponse
    case authenticationFailed
    case shareNotFound(String)
    case fileNotFound(String)
    case status(UInt32)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "尚未连接到服务器"
        case .connectionClosed:
            return "连接被关闭"
        case .unexpectedResponse:
            return "服务器返回了无法识别的响应"
        case .authenticationFailed:
            return "认证失败，请检查用户名与密码"
        case .shareNotFound(let name):
            return "找不到共享「\(name)」"
        case .fileNotFound(let path):
            return "找不到文件 \(path)"
        case .status(let code):
            return "SMB 错误状态 0x\(String(code, radix: 16, uppercase: true))"
        }
    }
}
