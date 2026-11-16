package sources

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"math/bits"
	"strings"
)

// 红果播放取址的「真 551」签名（x-argus / x-ladon）。
//
// 站方 2026-11-11 收紧了播放取址的签名校验：占位签名一律被软拦截成
// HTTP 200 + 0 字节（看不到任何错误码）。真签名绑的是「最终 query 原文 +
// 实际发送的 body」，所以 query 的参数顺序与百分号编码都必须一字不差。
//
// 算法移植自 GPL-3.0 的 hongguoTV（kotlin-tv/core/.../Argus.kt），
// 它本身又是 fqapp 的 rust/src/sign/{argus,simon,ladon,gorgon,protobuf}.rs 的移植。
// 本仓同为 GPL-3.0，按许可证要求保留出处说明。
//
// x-argus：protobuf bean -> PKCS7 -> Simon -> 551 包装 -> AES-CBC
// x-ladon：34 轮 ARX

const (
	hongguoSign551LicenseID = 1611921764
	hongguoSign551AID       = 8662
)

var (
	hongguoSign551Key = mustDecodeHex16("fc78e0a9657a0c748ce51559903ccf03510e51d3cff232d71343e88a321c5304")
	hongguoSign551AES = mustDecodeHex16("d31e3718288a1027baab59f146a09a9c")
	hongguoSign551IV  = mustDecodeHex16("ea180a0336ed352fcd24e4d50018ae54")

	hongguoSign551Magic = [8]byte{0xf2, 0xf7, 0xfc, 0xff, 0xf2, 0xf7, 0xfc, 0xff}
	hongguoSign551Tail  = [9]byte{0xea, 0xfb, 0x2c, 0xfe, 0x85, 0x68, 0x51, 0x91, 0x54}
)

func mustDecodeHex16(text string) []byte {
	raw, err := hex.DecodeString(text)
	if err != nil {
		panic("红果签名常量不是合法十六进制：" + text)
	}
	return raw
}

// formatInt64：与 strconv.FormatInt 一致，但避免到处 import strconv。
func formatInt64(value int64) string {
	if value == 0 {
		return "0"
	}
	negative := value < 0
	var magnitude uint64
	if negative {
		magnitude = uint64(-value)
	} else {
		magnitude = uint64(value)
	}
	var digits [20]byte
	index := len(digits)
	for magnitude > 0 {
		index--
		digits[index] = byte('0' + magnitude%10)
		magnitude /= 10
	}
	if negative {
		index--
		digits[index] = '-'
	}
	return string(digits[index:])
}

// hongguoQueryParam 从 query 原文里取一个参数的值（按第一个等号切，不做解码：
// 签名用的就是原文，版本号这类 ASCII 值取出来即可）。
func hongguoQueryParam(query, name string) string {
	for _, pair := range strings.Split(query, "&") {
		if pair == "" {
			continue
		}
		key, value, found := strings.Cut(pair, "=")
		if found && key == name {
			return value
		}
	}
	return ""
}

// MARK: - protobuf 编码（只写不读，varint 截断到 32 位）

type hongguoProtoField struct {
	tag      int
	kind     int
	value    uint64
	blob     []byte
}

type hongguoProtoBuilder struct {
	fields []hongguoProtoField
}

func (b *hongguoProtoBuilder) putVarint(index int, value uint64) *hongguoProtoBuilder {
	b.fields = append(b.fields, hongguoProtoField{tag: index, kind: 0, value: value & 0xffffffff})
	return b
}

func (b *hongguoProtoBuilder) putBlob(index int, data []byte) *hongguoProtoBuilder {
	b.fields = append(b.fields, hongguoProtoField{tag: index, kind: 2, blob: data})
	return b
}

func (b *hongguoProtoBuilder) putString(index int, text string) *hongguoProtoBuilder {
	return b.putBlob(index, []byte(text))
}

func (b *hongguoProtoBuilder) putProto(index int, nested *hongguoProtoBuilder) *hongguoProtoBuilder {
	return b.putBlob(index, nested.encode())
}

func (b *hongguoProtoBuilder) encode() []byte {
	out := make([]byte, 0, 64)
	for _, field := range b.fields {
		out = appendProtoVarint(out, uint64(field.tag)<<3|uint64(field.kind))
		switch field.kind {
		case 0:
			out = appendProtoVarint(out, field.value)
		case 2:
			out = appendProtoVarint(out, uint64(len(field.blob)))
			out = append(out, field.blob...)
		}
	}
	return out
}

func appendProtoVarint(dst []byte, value uint64) []byte {
	v := value & 0xffffffff
	for v >= 128 {
		dst = append(dst, byte(v&127)|128)
		v >>= 7
	}
	return append(dst, byte(v&127))
}

// MARK: - Simon 分组密码（128 位密钥、64 位分组、72 轮）

const hongguoSimonZ = uint64(0x3DC94C3A046D678B)

func hongguoSimonKeyExpansion(key []uint64) []uint64 {
	expanded := make([]uint64, 72)
	copy(expanded, key)
	for i := 4; i < 72; i++ {
		tmp := bits.RotateLeft64(expanded[i-1], -3)
		tmp ^= expanded[i-3]
		tmp ^= bits.RotateLeft64(tmp, -1)
		bit := (hongguoSimonZ >> ((i - 4) % 62)) & 1
		expanded[i] = ^expanded[i-4] ^ tmp ^ bit ^ 3
	}
	return expanded
}

func hongguoSimonEncrypt(left, right uint64, expanded []uint64) (uint64, uint64) {
	xi, xi1 := left, right
	for _, roundKey := range expanded {
		tmp := xi1
		f := bits.RotateLeft64(xi1, 1) & bits.RotateLeft64(xi1, 8)
		xi1 = xi ^ f ^ bits.RotateLeft64(xi1, 2) ^ roundKey
		xi = tmp
	}
	return xi, xi1
}

func hongguoSimonDecrypt(left, right uint64, expanded []uint64) (uint64, uint64) {
	xLeft, xRight := left, right
	for i := 71; i >= 0; i-- {
		tmp := xLeft
		f := bits.RotateLeft64(xLeft, 1) & bits.RotateLeft64(xLeft, 8)
		xLeft = xRight ^ f ^ bits.RotateLeft64(xLeft, 2) ^ expanded[i]
		xRight = tmp
	}
	return xLeft, xRight
}

func hongguoSign551KeyWords() []uint64 {
	words := make([]uint64, 4)
	for i := 0; i < 4; i++ {
		words[i] = binary.LittleEndian.Uint64(hongguoSign551Key[i*8:])
	}
	return words
}

// MARK: - AES-CBC

func hongguoSign551AESEncrypt(data []byte) []byte {
	block, err := aes.NewCipher(hongguoSign551AES)
	if err != nil {
		return nil
	}
	// AES/CBC/NoPadding：数据长度必须已经是 16 的倍数（调用方负责 PKCS7）。
	out := make([]byte, len(data))
	cipher.NewCBCEncrypter(block, hongguoSign551IV).CryptBlocks(out, data)
	return out
}

// MARK: - PKCS7

func hongguoPKCS7Align(data []byte) []byte {
	pad := 16 - len(data)%16
	out := make([]byte, 0, len(data)+pad)
	out = append(out, data...)
	for i := 0; i < pad; i++ {
		out = append(out, byte(pad))
	}
	return out
}

// MARK: - x-argus

// hongguoSign551Argus 生成 x-argus 头。
//
// query 必须是「最终发出去的那份 query 原文」—— 顺序和百分号编码都不能改，
// 签名就是按这些字节算的。stubHex 是 body 的 MD5（十六进制），没有 body 时传空串。
func hongguoSign551Argus(query, stubHex string, ts int64, aid int64, licenseID int64,
	deviceID string, installID string, randField int) string {
	if aid == 0 {
		aid = 1967
	}
	if licenseID == 0 {
		licenseID = hongguoSign551LicenseID
	}

	bean := &hongguoProtoBuilder{}
	bean.putVarint(1, 1077940818)
	bean.putVarint(2, 2)
	bean.putVarint(3, uint64(randField)&0xffffffff)
	bean.putString(4, formatInt64(aid))
	bean.putString(5, deviceID)
	bean.putString(6, formatInt64(licenseID))
	bean.putString(7, hongguoQueryParam(query, "version_name"))
	bean.putString(8, "v04.04.05-ov-android")
	bean.putVarint(9, 134744640)
	bean.putBlob(10, make([]byte, 8))
	bean.putVarint(11, 0)
	bean.putVarint(12, uint64(ts)<<1&0xffffffff)
	bean.putBlob(13, hongguoSign551BodyHash(stubHex))
	bean.putBlob(14, hongguoSign551QueryHash(query))

	sub15 := &hongguoProtoBuilder{}
	sub15.putVarint(1, 1)
	sub15.putVarint(2, 1)
	sub15.putVarint(3, 1)
	sub15.putVarint(7, 0xC792ECCC)
	bean.putProto(15, sub15)

	bean.putString(16, installID)
	bean.putString(20, "none")
	bean.putVarint(21, 738)

	sub23 := &hongguoProtoBuilder{}
	sub23.putString(1, "NX551J")
	sub23.putVarint(2, 8196)
	sub23.putVarint(4, 0x80E0D800)
	bean.putProto(23, sub23)
	bean.putVarint(25, 2)

	protobuf := hongguoPKCS7Align(bean.encode())
	encrypted := hongguoSimonEncryptPadded(protobuf)

	// 551 包装：MAGIC8 + 密文 + TAIL9，再逐字节异或 MAGIC8、整体反转。
	un := make([]byte, 0, len(encrypted)+17)
	un = append(un, hongguoSign551Magic[:]...)
	un = append(un, encrypted...)
	un = append(un, hongguoSign551Tail[:]...)

	buf := make([]byte, len(un))
	copy(buf, hongguoSign551Magic[:])
	for i := 8; i < len(un); i++ {
		buf[i] = un[i] ^ hongguoSign551Magic[i%8]
	}
	// 整体反转
	for i, j := 0, len(buf)-1; i < j; i, j = i+1, j-1 {
		buf[i], buf[j] = buf[j], buf[i]
	}

	padded := make([]byte, 0, len(buf)+18)
	padded = append(padded, buf...)
	padded = append(padded, 'a', 'o')
	padded = hongguoPKCS7Align(padded)

	encrypted = hongguoSign551AESEncrypt(padded)
	if encrypted == nil {
		return ""
	}
	out := make([]byte, 0, len(encrypted)+2)
	out = append(out, 0xf2, 0x81)
	out = append(out, encrypted...)
	return base64.StdEncoding.EncodeToString(out)
}

func hongguoSimonEncryptPadded(protobuf []byte) []byte {
	expanded := hongguoSimonKeyExpansion(hongguoSign551KeyWords())
	out := make([]byte, len(protobuf)/16*16)
	for i := 0; i < len(protobuf)/16; i++ {
		block := protobuf[i*16 : i*16+16]
		left := binary.LittleEndian.Uint64(block[0:8])
		right := binary.LittleEndian.Uint64(block[8:16])
		encLeft, encRight := hongguoSimonEncrypt(left, right, expanded)
		binary.LittleEndian.PutUint64(out[i*16:], encLeft)
		binary.LittleEndian.PutUint64(out[i*16+8:], encRight)
	}
	return out
}

// hongguoSign551BodyHash：body 的 SM3 前 6 字节；没有 body 时是 16 个零字节的 SM3 前 6 字节。
func hongguoSign551BodyHash(stubHex string) []byte {
	if stubHex == "" {
		return hongguoSM3(make([]byte, 16))[:6]
	}
	raw, err := hex.DecodeString(stubHex)
	if err != nil {
		return hongguoSM3(make([]byte, 0))[:6]
	}
	return hongguoSM3(raw)[:6]
}

// hongguoSign551QueryHash：query 原文的 SM3 前 6 字节。
func hongguoSign551QueryHash(query string) []byte {
	if query == "" {
		return hongguoSM3(make([]byte, 16))[:6]
	}
	return hongguoSM3([]byte(query))[:6]
}

// MARK: - x-ladon

// hongguoSign551DecryptArgus 解开 x-argus，回到原始 protobuf。
//
// 只用于自测（往返验证加密是否与上游一致），出包不走这条路。
// 注意：Simon 的解密不是加密的简单逆 —— 上游的 decrypt 用 (xLeft, xRight) 的
// 约定，与加密的 (xi, xi1) 顺序相反，这里照抄上游的写法。
func hongguoSign551DecryptArgus(argusBase64 string) []byte {
	raw, err := base64.StdEncoding.DecodeString(argusBase64)
	if err != nil || len(raw) <= 18 || raw[0] != 0xf2 || raw[1] != 0x81 {
		return nil
	}
	block, err := aes.NewCipher(hongguoSign551AES)
	if err != nil {
		return nil
	}
	padded := make([]byte, len(raw)-2)
	cipher.NewCBCDecrypter(block, hongguoSign551IV).CryptBlocks(padded, raw[2:])

	end := len(padded)
	pad := int(padded[len(padded)-1])
	if pad >= 1 && pad <= 16 && pad <= end {
		end -= pad
	}
	if end < 2 || padded[end-2] != 'a' || padded[end-1] != 'o' {
		return nil
	}

	framed := make([]byte, end-2)
	for i := range framed {
		framed[i] = padded[end-2-1-i]
	}
	un := make([]byte, len(framed))
	for i := range framed {
		if i < 8 {
			un[i] = framed[i]
		} else {
			un[i] = framed[i] ^ hongguoSign551Magic[i%8]
		}
	}
	for i := 0; i < 8; i++ {
		if un[i] != hongguoSign551Magic[i] {
			return nil
		}
	}
	for i := 0; i < 9; i++ {
		if un[len(un)-9+i] != hongguoSign551Tail[i] {
			return nil
		}
	}

	encPb := un[8 : len(un)-9]
	expanded := hongguoSimonKeyExpansion(hongguoSign551KeyWords())
	out := make([]byte, len(encPb))
	for i := 0; i < len(encPb)/16; i++ {
		block := encPb[i*16 : i*16+16]
		left := binary.LittleEndian.Uint64(block[0:8])
		right := binary.LittleEndian.Uint64(block[8:16])
		plainLeft, plainRight := hongguoSimonDecrypt(left, right, expanded)
		binary.LittleEndian.PutUint64(out[i*16:], plainLeft)
		binary.LittleEndian.PutUint64(out[i*16+8:], plainRight)
	}
	return out
}
// hongguoSign551Ladon 生成 x-ladon 头（34 轮 ARX）。
func hongguoSign551Ladon(khronos int64, lcID int64, aid int64, randomBytes []byte) string {
	data := formatInt64(khronos) + "-" + formatInt64(lcID) + "-" + formatInt64(aid)
	sum := md5.Sum(append(append([]byte(nil), randomBytes...), []byte(formatInt64(aid))...))
	table := hongguoLadonExpandTable(sum[:])
	size := len(data)
	newSize := size + (16 - size%16)
	input := make([]byte, newSize)
	for i := range input {
		input[i] = byte(newSize - size)
	}
	copy(input, data)
	out := make([]byte, newSize)
	for i := 0; i < newSize/16; i++ {
		block := hongguoLadonEncryptBlock(table, input, i*16)
		copy(out[i*16:], block)
	}
	return base64.StdEncoding.EncodeToString(append(append([]byte(nil), randomBytes...), out...))
}

func hongguoLadonExpandTable(sum []byte) []uint64 {
	table := make([]byte, 288)
	copy(table, sum)
	b0 := binary.LittleEndian.Uint64(table[0:8])
	b8 := binary.LittleEndian.Uint64(table[8:16])
	// 原始实现以 [word2, word3] 起步，每次弹出前先压入。
	temp := []uint64{
		binary.LittleEndian.Uint64(table[16:24]),
		binary.LittleEndian.Uint64(table[24:32]),
	}
	for i := 0; i < 34; i++ {
		x8 := bits.RotateLeft64(b8, -8) + b0
		x8 ^= uint64(i)
		temp = append(temp, x8)
		x8 ^= bits.RotateLeft64(b0, 3)
		for j := 0; j < 8; j++ {
			table[(i+1)*8+j] = byte((x8 >> (j * 8)) & 0xff)
		}
		b0 = x8
		b8 = temp[0]
		temp = temp[1:]
	}
	words := make([]uint64, 36)
	for i := 0; i < 36; i++ {
		words[i] = binary.LittleEndian.Uint64(table[i*8:])
	}
	return words
}

func hongguoLadonEncryptBlock(table []uint64, data []byte, at int) []byte {
	data0 := binary.LittleEndian.Uint64(data[at : at+8])
	data1 := binary.LittleEndian.Uint64(data[at+8 : at+16])
	for i := 0; i < 34; i++ {
		data1 = table[i] ^ (data0 + bits.RotateLeft64(data1, -8))
		data0 = data1 ^ bits.RotateLeft64(data0, 3)
	}
	out := make([]byte, 16)
	binary.LittleEndian.PutUint64(out[0:8], data0)
	binary.LittleEndian.PutUint64(out[8:16], data1)
	return out
}
