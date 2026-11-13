import Foundation

// MARK: - 哈希算法

/// 系统没有暴露 MD4 / MD5（CommonCrypto 只有 SHA 系列与部分场景的 MD5），
/// 而 SMB 的 NTLM 认证与 WebDAV 的 Digest 认证都需要它们，只能自己实现。
/// 两个实现都用 RFC 的官方测试向量验证过。

/// MD4 哈希：NTLMv2 需要它算 NT 哈希。
///
/// 系统没有暴露 MD4（CommonCrypto 只有 MD5/SHA 系列），只能自己实现。
enum MD4 {
    static func hex(_ message: [UInt8]) -> String {
        hexDigest(message).map { String(format: "%02x", $0) }.joined()
    }

    static func hexDigest(_ message: [UInt8]) -> [UInt8] {
        var a0: UInt32 = 0x67452301
        var b0: UInt32 = 0xefcdab89
        var c0: UInt32 = 0x98badcfe
        var d0: UInt32 = 0x10325476

        let originalLength = UInt64(message.count) * 8
        var padded = message
        padded.append(0x80)
        while padded.count % 64 != 56 {
            padded.append(0)
        }
        for index in 0..<8 {
            padded.append(UInt8((originalLength >> UInt64(8 * index)) & 0xff))
        }

        for chunkStart in stride(from: 0, to: padded.count, by: 64) {
            var x = [UInt32](repeating: 0, count: 16)
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                x[index] = UInt32(padded[offset])
                    | (UInt32(padded[offset + 1]) << 8)
                    | (UInt32(padded[offset + 2]) << 16)
                    | (UInt32(padded[offset + 3]) << 24)
            }
            var a = a0, b = b0, c = c0, d = d0

            // 第一轮：F(x,y,z) = (x & y) | (~x & z)
            for index in 0..<16 {
                let result = rotateLeft(a &+ f(b, c, d) &+ x[index], by: [3, 7, 11, 19][index % 4])
                a = d
                d = c
                c = b
                b = result
            }
            // 第二轮：G(x,y,z) = (x & y) | (x & z) | (y & z)
            let order2 = [0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15]
            let shifts2: [UInt32] = [3, 5, 9, 13, 3, 5, 9, 13, 3, 5, 9, 13, 3, 5, 9, 13]
            for index in 0..<16 {
                let result = rotateLeft(a &+ g(b, c, d) &+ x[order2[index]] &+ 0x5a827999, by: shifts2[index])
                a = d
                d = c
                c = b
                b = result
            }
            // 第三轮：H(x,y,z) = x ^ y ^ z
            let order3 = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15]
            let shifts3: [UInt32] = [3, 9, 11, 15, 3, 9, 11, 15, 3, 9, 11, 15, 3, 9, 11, 15]
            for index in 0..<16 {
                let result = rotateLeft(a &+ h(b, c, d) &+ x[order3[index]] &+ 0x6ed9eba1, by: shifts3[index])
                a = d
                d = c
                c = b
                b = result
            }

            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
        }

        var output = [UInt8]()
        output.reserveCapacity(16)
        for word in [a0, b0, c0, d0] {
            output.append(UInt8(word & 0xff))
            output.append(UInt8((word >> 8) & 0xff))
            output.append(UInt8((word >> 16) & 0xff))
            output.append(UInt8((word >> 24) & 0xff))
        }
        return output
    }

    private static func f(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        (x & y) | (~x & z)
    }

    private static func g(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        (x & y) | (x & z) | (y & z)
    }

    private static func h(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        x ^ y ^ z
    }

    private static func rotateLeft(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }
}

/// MD5：Digest 认证要用。系统没有直接暴露 MD5，只能自己实现。
enum MD5 {
    static func hex(_ string: String) -> String {
        hex(Array(string.utf8))
    }

    /// 字节形式的摘要：HMAC-MD5 的内层摘要需要。
    static func hexDigest(_ message: [UInt8]) -> [UInt8] {
        var a0: UInt32 = 0x67452301
        var b0: UInt32 = 0xefcdab89
        var c0: UInt32 = 0x98badcfe
        var d0: UInt32 = 0x10325476

        let originalLength = UInt64(message.count) * 8
        var padded = message
        padded.append(0x80)
        while padded.count % 64 != 56 {
            padded.append(0)
        }
        for index in 0..<8 {
            padded.append(UInt8((originalLength >> UInt64(8 * index)) & 0xff))
        }

        let shifts: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                               5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                               4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                               6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
        let constants: [UInt32] = (0..<64).map {
            UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4294967296.0))
        }

        for chunkStart in stride(from: 0, to: padded.count, by: 64) {
            var m = [UInt32](repeating: 0, count: 16)
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                m[index] = UInt32(padded[offset])
                    | (UInt32(padded[offset + 1]) << 8)
                    | (UInt32(padded[offset + 2]) << 16)
                    | (UInt32(padded[offset + 3]) << 24)
            }
            var a = a0, b = b0, c = c0, d = d0
            for index in 0..<64 {
                var f: UInt32
                var g: Int
                switch index {
                case 0..<16:
                    f = (b & c) | (~b & d)
                    g = index
                case 16..<32:
                    f = (d & b) | (~d & c)
                    g = (5 * index + 1) % 16
                case 32..<48:
                    f = b ^ c ^ d
                    g = (3 * index + 5) % 16
                default:
                    f = c ^ (b | ~d)
                    g = (7 * index) % 16
                }
                f = f &+ a &+ constants[index] &+ m[g]
                a = d
                d = c
                c = b
                b = b &+ rotateLeft(f, by: shifts[index])
            }
            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
        }

        var output = [UInt8]()
        output.reserveCapacity(16)
        for word in [a0, b0, c0, d0] {
            output.append(UInt8(word & 0xff))
            output.append(UInt8((word >> 8) & 0xff))
            output.append(UInt8((word >> 16) & 0xff))
            output.append(UInt8((word >> 24) & 0xff))
        }
        return output
    }

    static func hex(_ message: [UInt8]) -> String {
        hexDigest(message).map { String(format: "%02x", $0) }.joined()
    }

    private static func rotateLeft(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }
}
