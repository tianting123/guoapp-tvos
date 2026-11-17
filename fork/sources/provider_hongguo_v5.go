package sources

import (
	"crypto/md5"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"math/bits"
)

// 红果播放取址的「v5」签名（X-Helios / X-Medusa / X-SS-STUB）。
//
// 站方在 2026-11-16 换掉了取址接口与签名（上游 changelog 2.0.1+113
// 「适配新的播放器接口与 v5 签名」），2026-11-17 又把播放请求的 device_level
// 从 3 改成 1（低端机档位），否则部分剧集只返回 H.266 线路、取流直接失败
// （上游 changelog 2.0.2+114）。
//
// v5 与上一代（551 Argus / Ladon）是**完全不同的两套算法**：
// 这一代不用 x-argus / x-gorgon，官方测试里明确断言这两个头必须不存在。
//
// 算法移植自官方的红果站源模块（guoapp-modules/hongguo，GPL-3.0），
// 它本身来自 N3urda/hongguoTV 与 drpys 22261ad（同为 GPL-3.0）。
// 本仓同为 GPL-3.0，按许可证要求保留署名。

var (
	// v5 的两个固定常量。
	hongguoV5Magic   = mustDecodeHex16("2d4b4fca49750d433fb5ae2c226dcc56")
	hongguoV5SignKey = mustDecodeHex16("b23c2a470a20d105dc3f8c4438f8272ed46d6c89ffdcdedd5108698d26e9489d")
	// v5 的 4 组替换盒（每个 variant 256 字节）。
	hongguoV5Sbox = mustDecodeHex16(
		"53290fe9e51f316f90f74a7e034d367784ab49237cd0135cdc632c322fd3be0e2624a417ecd9151a7ff64f60730a87f9445ec6ada2f865d22b696c4188f24c0d" +
			"f37b75510b939f6bc2fe6883e68bc8c722181ba0bdb08c9871b50c9a16b46eea8eed20ba4b8a14e0fcf1468dbbef05a93e5a9d7dcf06898635c1fd99f5de287a" +
			"80c594daaab19b6279fbd75070cb52eb2555c456e39e7839853874e2f0013ac0b64742d8ca10e4b79c955de8b843ce4ed464a6a72ed508091c92e7b3eedd1e1d" +
			"d12afac321618fa3d65f9167c982f43d66a53c6a1997585b346dbf9672ff37cdbc073b2dae11453304df00815476b2a13fccdb30b957a8acafe1274002485912" +
			"38922563e36406d37a24100b7902a028044e218453c2a399199c9d13dc40c55ba67e502273850ebdc1a2e2188b8f2d9e3cb909b8c46a2a9f4a6dd93007eafa65" +
			"b7b3a881aa908cc74f0ad76bbbb58617c37012ca05a469fd44e62eecf1e4272ce860c0ae5eadf99b20d8f0234174006f3f110d7657d01645d4eff8f71471cbfe" +
			"1cb2f52648727bf3c9de55153e031b4d61757db63dbf7782eeafe9018a8891362fb14759ac32bab03b349aeb5a377c5156be4c8dfbe13a684bda39cf836697c8" +
			"94545fe0f2491acea9fc6252f4ff1e0fe72bd2df6e67a7f635e5bcc6d1a5dd951d89960887a18eb40c785cdb1f80ed42299333ab98cdd67f316cd54346585dcc" +
			"d759fb722789b08807cc0fda293f7e5e1819bb0353517020b31d3d00374952bea2c421e862040a9ec892a05b266b7a0d0cc316f483b81af39715657ffe32ad8d" +
			"e0c13077646035236ee5363e5f900e9a7cf850a81cd9960b6df73317226f99eaa6fff15cec34acb98246639b918ab2851466a7cdfc4ad1b52c2ae95a58d3734e" +
			"47ddd5b7560193f644ef9c408b7dee39b4d6aabf4de761e3252d4c7ba3843187745d55e6a5db05d42b45caed43c0c5d0b64bfa9d94a4a9d8f2f0e1a108dcfd28" +
			"8fd2bc1fc7bd675412138169cb09249875ba3b68cfb11180afae104fc9789571c6dfce02413886796ae21e3c488cc21b9f423a066c2eabf98e2fdeeb5776e4f5" +
			"d09a515ba58cbbab3e37b09fd4f6d9244df80512e84cd7956be301cf64f1429d58577cc241f3a2c655144f81aaf95a4e108da894b38970561ae9002619fbbac9" +
			"1fa922ed202bfc62cb08e0de2a7f3631435f8b47c8a3c563b4db4071ce74c46da6fa696a9e282d1e825d663b93bfd56c48dce1884bb10fccea063929f746443f" +
			"d830a4232e53da21a1f2d1bdfebc3a02c10a1b8ad31d04fd616590d272ac737e98eb33af60528716bee78ec0ee8699031177277d9cff32542c67caf5f4459168" +
			"1335ae0e178f3409a7803db83892dde5b9b7f0c750e24aef077badd678a09b850b84ec1597e4963cb5e675df1c0d6fb618496ecd76c35c798325590c2fb27a5e")
)

// v5 的哈希表（64 个 32 位常量）。
var hongguoV5HashTable = [64]uint32{
	0xebb64faf, 0x07aadcc2, 0xcf3187bf, 0xe01138ff, 0x6d0bfcff, 0x5a30a3be, 0xb41ad638, 0x34180eb8,
	0xf233eb6f, 0xb1a584cc, 0xccc30dc7, 0x47d1db51, 0xd55653de, 0x70a84fa1, 0x57473c12, 0xf76f0288,
	0x2c077f0a, 0xda0dcad0, 0xfbb86f6c, 0xfdc4cf00, 0x688a020d, 0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e,
	0xcce8b06b, 0x6ad0ed0b, 0xa0522717, 0xdc71ac83, 0x2285db71, 0xd5b4dda6, 0x736f8650, 0x6560306c,
	0x617ce2a6, 0xe423417e, 0x0a40e143, 0x544e4032, 0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x05b23bb3,
	0xe1d0b866, 0xbaa3dcb8, 0xae3374d3, 0xc3381a50, 0x1702f75b, 0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8,
	0x72aad10d, 0x26c53a3d, 0xf2bce0f6, 0xb4557581, 0x4a257fdd, 0x8c3182a2, 0xab0b3b86, 0x3d5dfb14,
	0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1, 0x6ca86f6e, 0x00284ba7, 0x08387cfa, 0x5fb37586,
}

// hongguoV5Le32：32 位小端字节。
func hongguoV5Le32(value uint32) []byte {
	out := make([]byte, 4)
	binary.LittleEndian.PutUint32(out, value)
	return out
}

// hongguoV5IV：v5 的 IV 推导。
//
// 站方会校验这个值：只有 (IV & 15) == 12 的请求才被认真处理，
// 否则回一个 HTTP 200 + 0 字节的空体（看不出任何错误码）。
// 这就是取址「随机空答」的真正原因 —— 不是站方随机，是签名没落在对的分支上。
func hongguoV5IV(queryHash, bodyMD5 []byte, ts uint32) uint32 {
	value := uint32(0x20230928)
	for _, data := range [][]byte{queryHash, bodyMD5, hongguoV5Le32(ts)} {
		for index, current := range data {
			if index&1 == 0 {
				value = (value >> 4) ^ value ^ (value << 6) ^ uint32(current)
			} else {
				value = ^((value >> 7) ^ value ^ (uint32(current) | (value << 12)))
			}
		}
	}
	return value
}

// hongguoV5Hash：v5 的摘要（X-Medusa 里作为 f13）。
//
// 要求 (IV & 15) == 12，否则调用方要换个 _rticket 重试。
func hongguoV5Hash(queryHash, bodyMD5 []byte, ts uint32) ([]byte, error) {
	if len(queryHash) != 32 || len(bodyMD5) != 16 {
		return nil, errors.New("v5 哈希需要 32 字节的 query 哈希与 16 字节的 body 哈希")
	}
	if (hongguoV5IV(queryHash, bodyMD5, ts) & 15) != 12 {
		return nil, errors.New("v5 哈希分支不对")
	}
	iv := uint32(0x9d4a97c2)
	count := int32(iv + ts)
	table := make([]uint32, len(hongguoV5HashTable))
	for index, value := range hongguoV5HashTable {
		table[index] = bits.RotateLeft32(value, -int((count+1)&255))
	}
	shift := uint((count + 2) & 7)
	padding := make([]byte, 4)
	for index, value := range []byte{0xfa, 0x45, 0x61, 0xd7} {
		padding[index] = byte((uint32(value) | (uint32(value) << 8)) >> shift)
	}

	data := make([]byte, 0, 32+16+4+4+8)
	data = append(data, queryHash...)
	data = append(data, bodyMD5...)
	data = append(data, hongguoV5Le32(ts)...)
	data = append(data, padding...)
	data = append(data, 0, 0, 0, 0, 0, 0, 1, 0xa0)

	words := make([]uint32, 0, 112)
	for index := 0; index < len(data); index += 4 {
		words = append(words, uint32(data[index])<<24|uint32(data[index+1])<<16|
			uint32(data[index+2])<<8|uint32(data[index+3]))
	}
	for index := 0; index < 112; index++ {
		x := words[index+1]
		y := words[index+14]
		words = append(words, words[index]+words[index+9]+
			(bits.RotateLeft32(x, 14) ^ bits.RotateLeft32(x, 25) ^ (x >> 3))+
			(bits.RotateLeft32(y, 13) ^ bits.RotateLeft32(y, 15) ^ (y >> 10)))
	}

	initialValues := [8]uint32{
		0x7aba4fc8, 0x67166507, 0x6403fa00, 0x340f512f,
		984304912, 3005047866, 2874125293, 2152413264,
	}
	initial := make([]uint32, 8)
	for index, value := range initialValues {
		initial[index] = bits.RotateLeft32(value, -int(count))
	}
	state := make([]uint32, 8)
	copy(state, initial)

	for index := 0; index < 96; index++ {
		base := (int32(iv) + int32(index))
		choose := ((state[4] ^ state[0]) & state[1]) ^ state[4]
		sigma1 := bits.RotateLeft32(state[1], 26) ^ bits.RotateLeft32(state[1], 21) ^ bits.RotateLeft32(state[1], 7)
		mixed := words[base&127] + choose + sigma1 + table[base&63] + state[6]
		sigma0 := bits.RotateLeft32(state[3], 30) ^ bits.RotateLeft32(state[3], 19) ^ bits.RotateLeft32(state[3], 10)
		majority := (state[3] & state[5]) | ((state[3] | state[5]) & state[2])
		old := state[7]
		// 官方是 state.unshift(state.pop())：把最后一个挪到最前。
		copy(state[1:], state[:7])
		state[0] = old
		state[7] = sigma0 + majority + mixed
		state[0] = old + mixed
	}

	digest := make([]byte, 32)
	for index := 0; index < 8; index++ {
		binary.BigEndian.PutUint32(digest[index*4:], state[index]+initial[index])
	}
	folded := make([]byte, 16)
	for index := 0; index < 16; index++ {
		folded[index] = digest[index] ^ digest[index+16]
	}
	check := uint32(0x20220420)
	for index := 0; index < 12; index++ {
		even := index&1 == 0
		var temp uint32
		if even {
			temp = (check >> 3) ^ check
			check = (uint32(folded[index]) ^ (check << 7)) ^ temp
		} else {
			temp = (check >> 5) ^ check
			check = ^(uint32(folded[index]) | (check << 11)) ^ temp
		}
	}
	out := make([]byte, 0, 20)
	out = append(out, folded...)
	out = append(out, hongguoV5Le32(((check|4)^0x1000000)|0x20)...)
	return out, nil
}

// MARK: - 载体加密（carrier）

// hongguoV5Carrier：v5 的载体加密（X-Medusa 的外层）。
func hongguoV5Carrier(key, iv, source []byte, ts uint32) ([]byte, error) {
	if len(key) != 16 || len(iv) != 16 || len(source) < 248 {
		return nil, errors.New("v5 载体需要 16 字节的 key/IV 与至少 248 字节的源数据")
	}
	variant := int(ts & 3)
	box := hongguoV5Sbox[variant*256 : (variant+1)*256]

	conTable := [4][4]int{
		{2, 0, 3, 1}, {1, 3, 2, 0}, {3, 2, 1, 0}, {2, 3, 1, 0},
	}
	orderTable := [4][16]int{
		{0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11},
		{0, 9, 14, 11, 4, 13, 2, 3, 8, 1, 6, 15, 12, 5, 10, 7},
		{0, 9, 14, 3, 4, 13, 2, 15, 8, 1, 6, 11, 12, 5, 10, 7},
		{0, 9, 14, 15, 4, 13, 2, 3, 8, 1, 6, 11, 12, 5, 10, 7},
	}
	initialValues := [4]uint32{0xbbb5de72, 0xd4638d5b, 0x92a5f73b, 0x89f8a1c9}
	initial := initialValues[variant]
	con := conTable[variant]
	order := orderTable[variant]

	initialBytes := hongguoV5Le32(initial)
	expanded := make([]byte, 48)
	for index := 0; index < 16; index++ {
		expanded[index] = initialBytes[index&3] ^ key[index]
	}
	rounds := 8
	for index := 4; index < 12; index++ {
		at := 4 * (index - 1)
		a := expanded[at]
		b := expanded[at+1]
		c := expanded[at+2]
		d := expanded[at+3]
		if index&3 == 0 {
			next := byte((initial >> uint(rounds&24)) ^ uint32(box[b]))
			b = box[c]
			c = box[d]
			d = box[a]
			a = next
		}
		rounds += 2
		expanded[at+4] = a ^ expanded[at-12]
		expanded[at+5] = b ^ expanded[at-11]
		expanded[at+6] = c ^ expanded[at-10]
		expanded[at+7] = d ^ expanded[at-9]
	}

	xt := func(value byte) byte {
		// 官方：((value << 1) ^ ((value & 128) !== 0 ? 0x1b : 0)) & 255
		// 注意是异或整个 0x1b，不是它的某个位。
		out := uint16(value) << 1
		if value&0x80 != 0 {
			out ^= 0x1b
		}
		return byte(out & 0xff)
	}
	block := func(value []byte) []byte {
		rows := [4][4]byte{}
		for index := 0; index < 4; index++ {
			copy(rows[index][:], value[index*4:index*4+4])
		}
		addCon := func(offset int) {
			for i := 0; i < 4; i++ {
				for j := 0; j < 4; j++ {
					rows[i][j] ^= expanded[(offset+i)*4+con[j]]
				}
			}
		}
		addCon(0)
		for round := 1; round <= 2; round++ {
			for i := 0; i < 4; i++ {
				for j := 0; j < 4; j++ {
					rows[i][j] = box[rows[i][j]]
				}
			}
			before := rows
			// rows = con.map(index => before[index])
			var mapped [4][4]byte
			for i := 0; i < 4; i++ {
				copy(mapped[i][:], before[con[i]][:])
			}
			rows = mapped
			flat := make([]byte, 0, 16)
			for i := 0; i < 4; i++ {
				flat = append(flat, rows[i][:]...)
			}
			for index := 0; index < 16; index++ {
				rows[index/4][index%4] = flat[order[index]]
			}
			if round == 1 {
				var after [4][4]byte
				for i := 0; i < 4; i++ {
					for j := 0; j < 4; j++ {
						after[i][j] = rows[i][con[j]]
					}
				}
				rows = after
				for index := 0; index < 4; index++ {
					mixed := rows[0][index] ^ rows[1][index] ^ rows[2][index] ^ rows[3][index]
					first := rows[0][index]
					rows[0][index] ^= mixed ^ xt(rows[0][index]^rows[1][index])
					rows[1][index] ^= mixed ^ xt(rows[1][index]^rows[2][index])
					rows[2][index] ^= mixed ^ xt(rows[2][index]^rows[3][index])
					rows[3][index] ^= mixed ^ xt(rows[3][index]^first)
				}
			}
			addCon(round * 4)
		}
		for i := 0; i < 4; i++ {
			for j := 0; j < 4; j++ {
				rows[i][j] ^= expanded[(4+i)*4+j]
			}
		}
		out := make([]byte, 0, 16)
		for i := 0; i < 4; i++ {
			out = append(out, rows[i][:]...)
		}
		return out
	}

	wire := [8]int{6, 5, 3, 4, 2, 7, 1, 0}
	compact := [8]int{1, 7, 3, 6, 2, 0, 4, 5}
	plaintext := make([]byte, 32)
	for i := 0; i < 31; i++ {
		for j := 0; j < 8; j++ {
			plaintext[i] |= byte((source[i*8+j]>>uint(wire[j]))&1) << uint(compact[j])
		}
	}
	plaintext[31] = 1

	input := make([]byte, 16)
	for index := 0; index < 16; index++ {
		input[index] = plaintext[index] ^ iv[index]
	}
	first := block(input)
	for index := 0; index < 16; index++ {
		input[index] = plaintext[index+16] ^ first[index]
	}
	stream := make([]byte, 0, 32)
	stream = append(stream, first...)
	stream = append(stream, block(input)...)

	out := make([]byte, 0, len(stream)+len(source))
	out = append(out, stream[31])
	out = append(out, source...)
	for i := 0; i < 31; i++ {
		for j := 0; j < 8; j++ {
			at := 1 + i*8 + j
			out[at] = (out[at] & ^(1 << uint(wire[j]))) | (((stream[i] >> uint(compact[j])) & 1) << uint(wire[j]))
		}
	}
	return out, nil
}

// MARK: - protobuf（v5 用的是自己那套 varint 布局）

func hongguoV5Varint(out []byte, value uint64) []byte {
	for value >= 0x80 {
		out = append(out, byte(value)|0x80)
		value >>= 7
	}
	return append(out, byte(value))
}

func hongguoV5VarintField(out []byte, tag int, value uint64) []byte {
	out = hongguoV5Varint(out, uint64(tag)<<3)
	return hongguoV5Varint(out, value)
}

func hongguoV5BytesField(out []byte, tag int, data []byte) []byte {
	out = hongguoV5Varint(out, uint64(tag)<<3|2)
	out = hongguoV5Varint(out, uint64(len(data)))
	return append(out, data...)
}

// hongguoV5Proto：v5 的 protobuf 构造。
//
// 数字字段按官方那样先 *2（zigzag 变体），字符串/字节字段长度为 0 时省略。
func hongguoV5Proto(fields [][]any) []byte {
	out := make([]byte, 0, 128)
	for _, field := range fields {
		tag := field[0].(int)
		switch value := field[1].(type) {
		case int:
			encoded := int64(value)
			if encoded < 0 {
				encoded = -encoded*2 - 1
			} else {
				encoded = encoded * 2
			}
			out = hongguoV5VarintField(out, tag, uint64(encoded))
		case uint32:
			out = hongguoV5VarintField(out, tag, uint64(value*2))
		case string:
			data := []byte(value)
			if len(data) != 0 {
				out = hongguoV5BytesField(out, tag, data)
			}
		case []byte:
			if len(value) != 0 {
				out = hongguoV5BytesField(out, tag, value)
			}
		}
	}
	return out
}

// MARK: - xmxor

func hongguoV5Rotl8(value byte, bits uint) byte {
	return (value << bits) | (value >> (8 - bits))
}

// hongguoV5Xmxor：v5 的消息混淆。
func hongguoV5Xmxor(data, key []byte) []byte {
	encoded := make([]byte, len(data))
	for index := 0; index < len(data); index++ {
		at := (index * 4) & 28
		d0 := key[at]
		d1 := key[at+1]
		// 全程用 int 运算，与 JS 的 Number 语义一致（溢出后取低 8 位）。
		mixed := int(hongguoV5Rotl8(data[index], 4)) + int(d0)
		mixed = ^mixed ^ int(d1)
		mixed = int(hongguoV5Rotl8(byte(mixed&0xff), 3))
		mixed = (mixed + int(d1)) & 0xff
		mixed ^= int(d0)
		encoded[len(data)-index-1] = byte(^mixed & 0xff)
	}
	lastIndex := len(encoded) - 1
	last := int(encoded[lastIndex] ^ encoded[lastIndex-1])
	first := int(encoded[0])
	encoded[0] = byte((^last + first) & 0xff)
	encoded[1] = byte(((int(encoded[0]) ^ int(encoded[lastIndex]) ^ 254) + int(encoded[1])) & 0xff)
	encoded[2] = byte((int(encoded[2]) + int((last-first)^int(hongguoV5Rotl8(encoded[1], 3))^2)) & 0xff)
	for index := 0; index < len(encoded)-4; index++ {
		mixed := int(hongguoV5Rotl8(encoded[index+2], 3)) ^ int(encoded[index+1]) ^ (index + 3)
		encoded[index+3] = byte((^mixed + int(encoded[index+3])) & 0xff)
	}
	encoded[lastIndex] ^= encoded[lastIndex-1]
	sum := 0
	for index := 1; index < len(encoded); index++ {
		sum += int(encoded[index])
	}
	encoded[0] = byte(((int(encoded[0]) ^ int(encoded[1])) + sum) & 0xff)
	return encoded
}

// MARK: - X-Helios

// hongguoV5Helios：X-Helios 头的值。
func hongguoV5Helios(ts uint32) (string, error) {
	prefix := make([]byte, 4)
	if _, err := cryptoRandomRead(prefix); err != nil {
		return "", err
	}
	sum := md5.Sum(append(append([]byte(nil), prefix...), []byte("8662")...))
	ascii := []byte(hex.EncodeToString(sum[:]))
	// 官方用 u32le 拼 64 位 —— 小端。
	left := binary.LittleEndian.Uint64(ascii[0:8])
	right := binary.LittleEndian.Uint64(ascii[8:16])
	queue := []uint64{binary.LittleEndian.Uint64(ascii[16:24]), binary.LittleEndian.Uint64(ascii[24:32])}
	keys := make([]uint64, 0, 34)
	for index := 0; index < 34; index++ {
		keys = append(keys, left)
		mixed := (bits.RotateLeft64(right, -8) + left) ^ uint64(index)
		queue = append(queue, mixed)
		left = mixed ^ bits.RotateLeft64(left, 3)
		right = queue[0]
		queue = queue[1:]
	}

	payload := []byte(fmt.Sprintf("%d-646637794-8662", ts))
	data := hongguoV5Pad16(payload)
	for offset := 0; offset < len(data); offset += 16 {
		a := binary.LittleEndian.Uint64(data[offset : offset+8])
		b := binary.LittleEndian.Uint64(data[offset+8 : offset+16])
		for _, key := range keys {
			b = key ^ (a + bits.RotateLeft64(b, -8))
			a = b ^ bits.RotateLeft64(a, 3)
		}
		binary.LittleEndian.PutUint64(data[offset:], a)
		binary.LittleEndian.PutUint64(data[offset+8:], b)
	}
	return base64.StdEncoding.EncodeToString(append(prefix, data...)), nil
}

// hongguoV5Pad16：按 16 字节对齐补齐（补的是差值本身）。
func hongguoV5Pad16(data []byte) []byte {
	size := len(data)
	pad := 16 - size%16
	out := make([]byte, 0, size+pad)
	out = append(out, data...)
	for i := 0; i < pad; i++ {
		out = append(out, byte(pad))
	}
	return out
}
