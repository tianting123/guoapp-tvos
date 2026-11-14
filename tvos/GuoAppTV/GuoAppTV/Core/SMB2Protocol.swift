import Foundation

// MARK: - SMB2 协议常量

/// SMB2 协议常量。
enum SMB2 {
    /// NetBIOS over TCP 会话前导：4 字节 0（表示直接 TCP，无会话头）。
    static let netBIOSPreamble: [UInt8] = [0, 0, 0, 0]

    static let commandNEGOTIATE: UInt16 = 0x0000
    static let commandSESSION_SETUP: UInt16 = 0x0001
    static let commandLOGOFF: UInt16 = 0x0002
    static let commandTREE_CONNECT: UInt16 = 0x0003
    static let commandCREATE: UInt16 = 0x0005
    static let commandCLOSE: UInt16 = 0x0006
    static let commandREAD: UInt16 = 0x0008
    static let commandWRITE: UInt16 = 0x0009
    static let commandIOCTL: UInt16 = 0x000B
    static let commandQUERY_DIRECTORY: UInt16 = 0x000E
    static let commandQUERY_INFO: UInt16 = 0x0010
    static let commandSET_INFO: UInt16 = 0x0011

    /// SMB2 header 长度。
    static let headerSize = 64
    /// 协议标识。
    static let protocolIdentifier: [UInt8] = [0xFE, 0x53, 0x4D, 0x42]
    /// 协议版本 2.1。
    static let dialectRevision: UInt16 = 0x0210
    /// 预认证完整性哈希用的 salt（32 字节）。固定值即可，不必每次随机。
    static let preauthSalt: [UInt8] = [
        0x77, 0x48, 0x49, 0x6b, 0x68, 0x46, 0x7a, 0x58,
        0x4d, 0x49, 0x7a, 0x49, 0x6a, 0x4b, 0x75, 0x4c,
        0x69, 0x6f, 0x55, 0x51, 0x78, 0x50, 0x67, 0x54,
        0x4a, 0x49, 0x70, 0x57, 0x52, 0x7a, 0x49, 0x6a,
    ]
    /// 一次声明多个方言：部分 NAS 只在列表包含多个版本时才接受。
    ///
    /// 声明 0x0311（SMB 3.1.1）时必须在 NEGOTIATE 里附带 negotiate context
    /// （预认证完整性哈希 + 加密能力），少一个字段服务端就会直接断开连接。
    static let supportedDialects: [UInt16] = [0x0202, 0x0210, 0x0300, 0x0302, 0x0311]

    /// NTLMSSP 相关。
    static let ntlmsspOID: [UInt8] = [
        0x06, 0x06, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x02,
        0x00, 0x00, 0x00, 0x0A,
    ]

    /// Flags：服务端到重定向。
    static let flagsServerToRedir: UInt32 = 0x0001
    /// Flags：启用签名。
    static let flagsSigningEnabled: UInt32 = 0x0002

    /// 文件属性：正常文件。
    static let fileAttributesNormal: UInt32 = 0x80
    /// 访问权限：读 + 写 + 删除。
    static let accessReadWrite: UInt32 = 0x00000003
    /// 共享访问：读 + 写。
    static let shareReadWrite: UInt32 = 0x00000003
    /// 创建选项。
    static let createOptions: UInt32 = 0x00000040
    /// 文件属性：覆盖已存在的文件。
    static let fileAttributesOverwrite: UInt32 = 0x00000002
}

// MARK: - SMB2 头部

/// SMB2 报文头。
///
/// 字段偏移严格按 MS-SMB2 2.2.1.2：
/// 0 ProtocolId · 4 StructureSize · 6 CreditCharge · 8 Status ·
/// 12 Command · 14 Credits · 16 Flags · 20 NextCommand · 24 MessageId ·
/// 32 Reserved · 36 TreeId · 40 SessionId · 48 Signature
struct SMB2Header {
    var command: UInt16
    var messageId: UInt64
    var credits: UInt16 = 1
    var flags: UInt32 = 0
    var treeId: UInt32 = 0
    var sessionId: UInt64 = 0
    /// 各命令结构体的长度（偏移 60-63）。
    var bodyLength: UInt32 = 0

    /// 构造请求头。
    init(command: UInt16, messageId: UInt64, credits: UInt16, flags: UInt32) {
        self.command = command
        self.messageId = messageId
        self.credits = credits
        self.flags = flags
    }

    /// 从字节数组解析头部。
    init?(data: Data) {
        guard data.count >= SMB2.headerSize else { return nil }
        let bytes = [UInt8](data)
        guard Array(bytes.prefix(4)) == SMB2.protocolIdentifier else {
            return nil
        }
        command = UInt16(bytes[12]) | (UInt16(bytes[13]) << 8)
        credits = UInt16(bytes[14]) | (UInt16(bytes[15]) << 8)
        flags = UInt32(bytes[16]) | (UInt32(bytes[17]) << 8) | (UInt32(bytes[18]) << 16) | (UInt32(bytes[19]) << 24)
        var message: UInt64 = 0
        for index in 0..<8 {
            message |= UInt64(bytes[24 + index]) << UInt64(8 * index)
        }
        messageId = message
        let tree = UInt32(bytes[36]) | (UInt32(bytes[37]) << 8) | (UInt32(bytes[38]) << 16) | (UInt32(bytes[39]) << 24)
        treeId = tree == 0xffffffff ? 0 : tree
        var session: UInt64 = 0
        for index in 0..<8 {
            session |= UInt64(bytes[40 + index]) << UInt64(8 * index)
        }
        sessionId = session == 0xffffffffffffffff ? 0 : session
        bodyLength = UInt32(bytes[60]) | (UInt32(bytes[61]) << 8) | (UInt32(bytes[62]) << 16) | (UInt32(bytes[63]) << 24)
    }

    /// 序列化成字节。
    ///
    /// 用 append 而不是下标赋值：下标写错会直接 crash，且不好定位。
    func encoded(bodyLength: UInt32) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(SMB2.headerSize)
        bytes.append(contentsOf: SMB2.protocolIdentifier)
        bytes.appendLE(UInt16(64))          // StructureSize
        bytes.appendLE(UInt16(1))           // CreditCharge
        bytes.appendLE(UInt32(0))           // Status
        bytes.appendLE(command)             // Command
        bytes.appendLE(credits)             // Credits
        bytes.appendLE(flags)               // Flags
        bytes.appendLE(UInt32(0))           // NextCommand
        bytes.appendLE(messageId)           // MessageId（8 字节）
        bytes.appendLE(UInt32(0))           // Reserved
        bytes.appendLE(treeId)              // TreeId
        bytes.appendLE(sessionId)           // SessionId（8 字节）
        // Signature 等字段补到偏移 60
        bytes.append(contentsOf: [UInt8](repeating: 0, count: max(0, 60 - bytes.count)))
        // 各命令结构体的长度在头内偏移 60-63
        bytes.appendLE(bodyLength)
        return bytes
    }
}

// MARK: - 字节工具

/// 按下标把小端整数写进字节数组。
///
/// SMB2 的各命令结构体字段位置固定，**必须按下标填**：先预分配一段零再
/// `append` 字段会把字段整体推到后面去（曾导致 WRITE 的 DataOffset 落到
/// 结构体外面，服务端直接报错）。
func putLE(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt16) {
    bytes[offset] = UInt8(value & 0xff)
    bytes[offset + 1] = UInt8((value >> 8) & 0xff)
}

func putLE(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
    bytes[offset] = UInt8(value & 0xff)
    bytes[offset + 1] = UInt8((value >> 8) & 0xff)
    bytes[offset + 2] = UInt8((value >> 16) & 0xff)
    bytes[offset + 3] = UInt8((value >> 24) & 0xff)
}

func putLE(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt64) {
    for index in 0..<8 {
        bytes[offset + index] = UInt8((value >> UInt64(8 * index)) & 0xff)
    }
}

/// 按下标写入一段字节。
func putBytes(_ bytes: inout [UInt8], _ offset: Int, _ value: [UInt8]) {
    for (index, byte) in value.enumerated() where offset + index < bytes.count {
        bytes[offset + index] = byte
    }
}

/// SMB2 文件句柄：16 字节（Persistent 8 + Volatile 8）。
///
/// 之前用 UInt64 只带低 8 字节，服务端会认成无效句柄。
typealias SMB2FileId = [UInt8]


extension Data {
    /// 按小端读 UInt16。
    func readUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let bytes = [UInt8](self)
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    /// 按小端读 UInt32。
    func readUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let bytes = [UInt8](self)
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    /// 按小端读 UInt64。
    func readUInt64(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        let bytes = [UInt8](self)
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << UInt64(8 * index)
        }
        return value
    }

    /// 按小端读 Int16。
    func readInt16(at offset: Int) -> Int16? {
        guard let value = readUInt16(at: offset) else { return nil }
        return Int16(bitPattern: value)
    }

    /// 按小端读 Int32。
    func readInt32(at offset: Int) -> Int32? {
        guard let value = readUInt32(at: offset) else { return nil }
        return Int32(bitPattern: value)
    }

    /// 按 UTF-16LE 读字符串。
    func readUTF16String(at offset: Int, length: Int) -> String? {
        guard offset >= 0, offset + length * 2 <= count else { return nil }
        let bytes = [UInt8](self)
        var units = [UInt16]()
        units.reserveCapacity(length)
        for index in 0..<length {
            let low = UInt16(bytes[offset + index * 2])
            let high = UInt16(bytes[offset + index * 2 + 1])
            units.append(low | (high << 8))
        }
        return String(decoding: units, as: UTF16.self)
    }
}

extension Array where Element == UInt8 {
    /// 追加小端 Int（转成 UInt32 写入）。
    mutating func appendLE(_ value: Int) {
        appendLE(UInt32(truncatingIfNeeded: value))
    }

    /// 追加小端 UInt16。
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    /// 追加小端 UInt32。
    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }

    /// 追加小端 UInt64。
    mutating func appendLE(_ value: UInt64) {
        for index in 0..<8 {
            append(UInt8((value >> UInt64(8 * index)) & 0xff))
        }
    }

    /// 追加小端 Int32。
    mutating func appendLE(_ value: Int32) {
        appendLE(UInt32(bitPattern: value))
    }

    /// 追加小端 Int16。
    mutating func appendLE(_ value: Int16) {
        appendLE(UInt16(bitPattern: value))
    }

    /// 追加 UTF-16LE 字符串（含结尾 null）。
    mutating func appendUTF16(_ string: String) {
        for unit in string.utf16 {
            appendLE(unit)
        }
        appendLE(UInt16(0))
    }

    /// 追加小端 UInt16 数组。
    mutating func appendLE(_ values: [UInt16]) {
        for value in values {
            appendLE(value)
        }
    }
}
