package core

import (
	"encoding/binary"
	"math/bits"
)

// SM3 摘要（国密）。
//
// 站源模块（JS）要用它算播放签名里的 query 哈希 —— 官方红果模块的 v5 签名
// 依赖 SM3。上游的模块宿主只提供了 md5 / sha256 / base64 / utf8 / AES，
// 缺 SM3，所以在这里补上，让官方模块能直接跑在宿主里。
//
// 算法与站源包里的实现一致（同一个 SM3 标准），只是放在 core 里给宿主用。

// ModuleSM3 返回输入的 SM3 摘要（32 字节）。
func ModuleSM3(input []byte) [32]byte {
	length := uint64(len(input)) * 8
	data := append(append([]byte(nil), input...), 0x80)
	for len(data)%64 != 56 {
		data = append(data, 0)
	}
	data = binary.BigEndian.AppendUint64(data, length)
	state := [8]uint32{
		0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
		0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e,
	}
	for offset := 0; offset < len(data); offset += 64 {
		var words [68]uint32
		for i := 0; i < 16; i++ {
			words[i] = binary.BigEndian.Uint32(data[offset+i*4:])
		}
		for i := 16; i < len(words); i++ {
			v := words[i-16] ^ words[i-9] ^ bits.RotateLeft32(words[i-3], 15)
			words[i] = v ^ bits.RotateLeft32(v, 15) ^ bits.RotateLeft32(v, 23) ^
				bits.RotateLeft32(words[i-13], 7) ^ words[i-6]
		}
		a, b, c, d := state[0], state[1], state[2], state[3]
		e, f, g, h := state[4], state[5], state[6], state[7]
		for i := 0; i < 64; i++ {
			t, ff, gg := uint32(0x79cc4519), a^b^c, e^f^g
			if i >= 16 {
				t, ff, gg = 0x7a879d8a, (a&b)|(a&c)|(b&c), (e&f)|(^e&g)
			}
			ss1 := bits.RotateLeft32(bits.RotateLeft32(a, 12)+e+bits.RotateLeft32(t, i), 7)
			tt1 := ff + d + (ss1 ^ bits.RotateLeft32(a, 12)) + (words[i] ^ words[i+4])
			tt2 := gg + h + ss1 + words[i]
			a, b, c, d = tt1, a, bits.RotateLeft32(b, 9), c
			e, f, g, h = tt2^bits.RotateLeft32(tt2, 9)^bits.RotateLeft32(tt2, 17), e, bits.RotateLeft32(f, 19), g
		}
		for i, value := range [8]uint32{a, b, c, d, e, f, g, h} {
			state[i] ^= value
		}
	}
	var result [32]byte
	for i, value := range state {
		binary.BigEndian.PutUint32(result[i*4:], value)
	}
	return result
}
