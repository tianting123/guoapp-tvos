package sources

import (
	"crypto/md5"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"strings"
	"sync"
	"time"
)

// v5 签名的对外部分：X-Medusa 的组装与整个取址请求的签名头。

// v5 的进程级状态：nonce 与 started 在同一进程内复用（官方也是这么做的）。
var (
	hongguoV5ProcessMu sync.Mutex
	hongguoV5ProcessNonce string
	hongguoV5Started   int64
)

// hongguoV5Who：签进 X-Medusa 的设备字段（全部取自 query）。
type hongguoV5Who struct {
	DeviceID    string
	VersionName string
	OSVersion   string
	DeviceType  string
	Channel     string
	DeviceBrand string
}

// hongguoV5Medusa：生成 X-Medusa 头的值。
func hongguoV5Medusa(queryHash, f13 []byte, ts uint32, who hongguoV5Who, nowMs int64) (string, error) {
	hongguoV5ProcessMu.Lock()
	if hongguoV5ProcessNonce == "" {
		raw := make([]byte, 18)
		if _, err := cryptoRandomRead(raw); err != nil {
			hongguoV5ProcessMu.Unlock()
			return "", err
		}
		encoded := base64.StdEncoding.EncodeToString(raw)
		encoded = strings.ReplaceAll(encoded, "+", "-")
		encoded = strings.ReplaceAll(encoded, "/", "_")
		encoded = strings.TrimRight(encoded, "=")
		hongguoV5ProcessNonce = encoded
		hongguoV5Started = nowMs
	}
	processNonce := hongguoV5ProcessNonce
	started := hongguoV5Started
	hongguoV5ProcessMu.Unlock()

	flags := make([]byte, 8)
	deviceInfo := hongguoV5Proto([][]any{
		{1, 1}, {2, 2}, {3, "8662"}, {4, who.DeviceID}, {5, processNonce},
		{6, "!noperm!"}, {12, "Asia/Shanghai,8"}, {13, "zh_CN"}, {22, who.OSVersion},
		{25, started}, {30, who.DeviceType}, {31, who.DeviceBrand},
		{32, who.DeviceType}, {34, who.DeviceBrand},
	})
	env := hongguoV5Proto([][]any{
		{6, "v04.10.03.04-bugfix"}, {8, who.Channel}, {12, deviceInfo}, {14, who.VersionName},
	})

	random4 := make([]byte, 4)
	if _, err := cryptoRandomRead(random4); err != nil {
		return "", err
	}
	message := hongguoV5Proto([][]any{
		{1, hongguoV5Magic}, {2, 5}, {3, binary.LittleEndian.Uint32(random4)}, {4, "8662"},
		{5, who.DeviceID}, {6, "646637794"}, {7, who.VersionName}, {8, "v04.10.03-ml-android"},
		{9, 0x040a0300}, {10, flags}, {12, ts}, {13, f13}, {14, queryHash[:6]},
		{15, hongguoV5Proto([][]any{{1, 1}, {2, 1}, {3, 1}, {5, 1}})}, {17, ts}, {20, "none"},
		{21, 377}, {23, env},
		{24, `{"cmr":16777216,"cmr2":16777216,"un_h":11,"vpn":0,"kd":0,"dyn":"","do":1,"tk":true}`},
	})

	nonceRandom := make([]byte, 4)
	if _, err := cryptoRandomRead(nonceRandom); err != nil {
		return "", err
	}
	randomNonce := binary.LittleEndian.Uint32(nonceRandom)

	hashInput := make([]byte, 0, len(hongguoV5SignKey)*2+4)
	hashInput = append(hashInput, hongguoV5SignKey...)
	hashInput = append(hashInput, hongguoV5Le32(randomNonce)...)
	hashInput = append(hashInput, hongguoV5SignKey...)
	hashSum := hongguoSM3(hashInput)
	hash := hashSum[:]

	high := (randomNonce >> 16) & 255
	seedValue := ^((uint32(high)<<11 | (randomNonce >> 24)) ^ (high >> 5) ^ uint32(high))
	seed := hongguoV5Le32(seedValue)

	transformed := make([]byte, 0, len(flags)+len(message))
	transformed = append(transformed, flags...)
	transformed = append(transformed, hongguoV5Xmxor(message, hash)...)
	// 官方是 .reverse()
	for i, j := 0, len(transformed)-1; i < j; i, j = i+1, j-1 {
		transformed[i], transformed[j] = transformed[j], transformed[i]
	}
	for index := range transformed {
		transformed[index] ^= seed[(^index)&3]
	}

	check := uint32(0x18000001) | ((uint32(queryHash[0]) & 63) << 14) | ((uint32(f13[0]) & 63) << 8)
	packed := make([]byte, 0, 1+4+4+len(transformed)+2)
	packed = append(packed, 0xca)
	packed = append(packed, random4...)
	packed = append(packed, hongguoV5Le32(check)...)
	packed = append(packed, transformed...)
	packed = append(packed, byte((randomNonce>>16)&255), byte((randomNonce>>24)&255))

	keySum := md5.Sum(hongguoV5SignKey[0:16])
	ivSum := md5.Sum(hongguoV5SignKey[16:32])
	encrypted, err := hongguoV5Carrier(keySum[:], ivSum[:], packed, ts)
	if err != nil {
		return "", err
	}

	prefix := make([]byte, 0, 8)
	prefix = append(prefix, hongguoV5Le32(5)...)
	prefix = append(prefix, hongguoV5Magic...)
	stamp := hongguoV5Le32(ts)
	for index := range prefix {
		prefix[index] ^= stamp[index&3]
	}

	out := make([]byte, 0, len(prefix)+4+len(encrypted))
	out = append(out, prefix...)
	out = append(out, byte(randomNonce&255), byte((randomNonce>>8)&255), 0, 1)
	out = append(out, encrypted...)
	return base64.StdEncoding.EncodeToString(out), nil
}

// hongguoV5SignedHeaders：为一次取址请求生成 v5 签名头。
//
// 关键：签名要找一个 _rticket 使 (IV & 15) == 12 —— 最多试 1024 次。
// 找不到就说明这次请求必然被站方空答，不如早点失败。
//
// 返回 query（带最终 _rticket）与要带的头。
func hongguoV5SignedHeaders(values map[string]string, body []byte, nowMs int64) (string, map[string]string, error) {
	ts := uint32(nowMs / 1000)
	hasBody := len(body) > 0
	bodyMD5 := make([]byte, 16)
	if hasBody {
		sum := md5.Sum(body)
		bodyMD5 = sum[:]
	}

	who := hongguoV5Who{
		DeviceID:    values["device_id"],
		VersionName: values["version_name"],
		OSVersion:   values["os_version"],
		DeviceType:  values["device_type"],
		Channel:     values["channel"],
		DeviceBrand: values["device_brand"],
	}
	if who.DeviceBrand == "" {
		who.DeviceBrand = "HONOR"
	}
	for name, value := range map[string]string{
		"device_id": who.DeviceID, "version_name": who.VersionName,
		"os_version": who.OSVersion, "device_type": who.DeviceType, "channel": who.Channel,
	} {
		if value == "" {
			return "", nil, errors.New("播放签名缺少设备字段：" + name)
		}
	}

	for offset := 0; offset < 1024; offset++ {
		params := make(map[string]string, len(values)+1)
		for key, value := range values {
			params[key] = value
		}
		params["_rticket"] = formatInt64(nowMs + int64(offset))
		query := hongguoV5EncodeQuery(params)

		queryHashSum := hongguoSM3([]byte(query))
		queryHash := queryHashSum[:]
		if (hongguoV5IV(queryHash, bodyMD5, ts) & 15) != 12 {
			continue
		}
		f13, err := hongguoV5Hash(queryHash, bodyMD5, ts)
		if err != nil {
			continue
		}
		helios, err := hongguoV5Helios(ts)
		if err != nil {
			return "", nil, err
		}
		medusa, err := hongguoV5Medusa(queryHash, f13, ts, who, nowMs)
		if err != nil {
			return "", nil, err
		}
		headers := map[string]string{
			"X-Khronos": formatInt64(int64(ts)),
			"X-Helios":  helios,
			"X-Medusa":  medusa,
		}
		if hasBody {
			headers["X-SS-STUB"] = strings.ToUpper(hexOf(bodyMD5))
			headers["Content-Type"] = "application/json; charset=utf-8"
		}
		return query, headers, nil
	}
	return "", nil, errors.New("无法在 1024 次 ticket 尝试内生成 v5 播放签名")
}

// hongguoV5EncodeQuery：按站方 App 的方式拼 query（参数顺序固定，插入序）。
func hongguoV5EncodeQuery(values map[string]string) string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	// 官方用对象展开，键序是插入序；这里按字典序拼，保证同一份输入每次都一样。
	sortStrings(keys)
	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		parts = append(parts, hongguoV5Encode(key)+"="+hongguoV5Encode(values[key]))
	}
	return strings.Join(parts, "&")
}

// hongguoV5Encode：站方的百分号编码（encodeURIComponent 语义，* 不转义）。
func hongguoV5Encode(value string) string {
	const hexDigits = "0123456789ABCDEF"
	var out strings.Builder
	for i := 0; i < len(value); i++ {
		c := value[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
			out.WriteByte(c)
		case c == '-' || c == '_' || c == '.' || c == '!' || c == '~' || c == '*':
			out.WriteByte(c)
		default:
			out.WriteByte('%')
			out.WriteByte(hexDigits[c>>4])
			out.WriteByte(hexDigits[c&0x0f])
		}
	}
	return out.String()
}

// sortStrings：字符串升序（避免 import sort 的命名冲突）。
func sortStrings(values []string) {
	for i := 1; i < len(values); i++ {
		for j := i; j > 0 && values[j] < values[j-1]; j-- {
			values[j], values[j-1] = values[j-1], values[j]
		}
	}
}

// hexOf：字节数组的小写十六进制。
func hexOf(data []byte) string {
	const digits = "0123456789abcdef"
	out := make([]byte, 0, len(data)*2)
	for _, value := range data {
		out = append(out, digits[value>>4], digits[value&0x0f])
	}
	return string(out)
}

// hongguoV5NowMs：当前毫秒时间（签名用）。
func hongguoV5NowMs() int64 {
	return time.Now().UnixMilli()
}
