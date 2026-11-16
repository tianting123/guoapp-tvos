package sources

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha512"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"duanjuapp/native/core"
)

// 红果取址用的注册身份：怎么拿、怎么复用、什么时候换。
//
// 站方发的号**大约一半是坏的**：注册响应里看不出好坏（好号坏号的 device_id /
// install_id / device_token 长得一模一样），只有拿号去取址才知道。坏号是**号级**的
// —— 同一个号连问三次全空、隔 30 秒再问还是全空；好号则可以长期跨集复用
// （实测同一个身份连取 60 集全部成功）。
//
// 所以这里的策略是：好号一直用（省站方的发号配额），整轮空答才换号，
// 最多换 8 个（八个全坏的概率约 0.4%）。

// 身份缓存：按客户端实例存一个，好号跨集复用。
var (
	hongguoPlaybackIdentityMu sync.Mutex
	hongguoPlaybackIdentities  = map[string]*hongguoPlaybackIdentity{}
)

// cryptoRandomInt：取一个随机的 32 位整数（Argus 的每次调用随机字段）。
func cryptoRandomInt() (int, error) {
	var raw [4]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return 0, err
	}
	return int(binary.LittleEndian.Uint32(raw[:]) & 0x7fffffff), nil
}

// cryptoRandomRead：填随机字节。
func cryptoRandomRead(buffer []byte) (int, error) {
	return rand.Read(buffer)
}

// hongguoPlaybackIdentity：取一个可用的注册身份。
//
// 好号会缓存起来跨集复用；缓存的身份超过两小时就重新注册一个
// （站方可能慢慢地不看它了）。
func (p *hongguoProvider) hongguoPlaybackIdentity(ctx context.Context) (*hongguoPlaybackIdentity, error) {
	hongguoPlaybackIdentityMu.Lock()
	cached, ok := hongguoPlaybackIdentities[p.hongguoIdentityKey()]
	if ok && time.Since(cached.CreatedAt) < hongguoPlaybackIdentityMaxAge {
		hongguoPlaybackIdentityMu.Unlock()
		return cached, nil
	}
	if ok {
		// 过期了，重新注册（顺手把旧的删掉）。
		delete(hongguoPlaybackIdentities, p.hongguoIdentityKey())
	}
	hongguoPlaybackIdentityMu.Unlock()

	identity, err := p.registerHongguoPlaybackDevice(ctx)
	if err != nil {
		return nil, err
	}
	hongguoPlaybackIdentityMu.Lock()
	hongguoPlaybackIdentities[p.hongguoIdentityKey()] = identity
	hongguoPlaybackIdentityMu.Unlock()
	return identity, nil
}

// hongguoIdentityKey：身份缓存的键。同一台设备共用一个身份。
func (p *hongguoProvider) hongguoIdentityKey() string {
	return "hongguo-playback"
}

// dropHongguoPlaybackIdentity：丢掉当前身份（这一整轮都空答，说明是坏号）。
func (p *hongguoProvider) dropHongguoPlaybackIdentity() {
	hongguoPlaybackIdentityMu.Lock()
	delete(hongguoPlaybackIdentities, p.hongguoIdentityKey())
	hongguoPlaybackIdentityMu.Unlock()
}

// hongguoPlaybackDeviceRegisterURL：注册设备用的地址。
//
// 站方现在发号的是 log5-applog-lf.fqnovel.com：老的 log.snssdk.com 会回
// HTTP 200 但 device_id 是 0（不给你设备），拿这种号去取址必然整轮空答。
const hongguoPlaybackDeviceRegisterURL = "https://log5-applog-lf.fqnovel.com/service/2/device_register/?" +
	"tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1"

// hongguoPlaybackRegisterUserAgent：注册时戴的 UA（App 自己的，不是取址那个）。
const hongguoPlaybackRegisterUserAgent = "com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)"

// hongguoPlaybackKDFSalt：ttEncrypt 的密钥派生盐（App 自带的那一份）。
const hongguoPlaybackKDFSalt = "4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524" +
	"f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58"

// registerHongguoPlaybackDevice：注册一个匿名设备，拿回三个身份字段。
//
// 注意：注册响应里**没有 code 字段**。之前按「code 不为 0 就失败」来读，
// 会把「字段缺失」读成 code=-1，于是每次注册成功都被当场判为失败。
// 正确的判法是「device_id / install_id 都是合法的数字且不为 0」。
func (p *hongguoProvider) registerHongguoPlaybackDevice(ctx context.Context) (*hongguoPlaybackIdentity, error) {
	cdid, err := newHongguoPlaybackUUID()
	if err != nil {
		return nil, errors.New("红果设备注册失败：无法准备随机标识")
	}
	now := time.Now().UnixMilli()
	header := map[string]any{
		"display_name": "红果免费短剧", "update_version_code": 73932, "manifest_version_code": 73932,
		"app_version_minor": "7.3.9.32", "aid": 8662, "channel": "update_64",
		"package": "com.phoenix.read", "app_version": "7.3.9.32", "version_code": 73932,
		"sdk_version": "3.7.0-rc.34-fanqie-xiaoshuo", "sdk_target_version": 29, "git_hash": "3a88f4e",
		"os": "Android", "os_version": "16", "os_api": 36, "device_model": "25053RT47C",
		"device_brand": "Redmi", "device_manufacturer": "Redmi", "cpu_abi": "arm64-v8a",
		"release_build": "b5e187f", "density_dpi": 520, "display_density": "mdpi",
		"resolution": "1280*2772", "language": "zh", "timezone": 8, "access": "wifi",
		"not_request_sender": 0, "carrier": "CHINA MOBILE", "mcc_mnc": "46000",
		"rom": "eng.root.20231116.160340", "rom_version": "W528JS release-keys", "cdid": cdid,
		"sig_hash": "56a962410c494bbaf0b58dba20cae56f", "openudid": newHongguoPlaybackHex(8),
		"clientudid": newHongguoPlaybackUUID(), "ipv6_list": []any{}, "region": "CN",
		"tz_name": "Asia/Shanghai", "tz_offset": 28800, "sim_region": "cn",
		"sim_serial_number": []any{}, "oaid_may_support": false, "req_id": newHongguoPlaybackUUID(),
		"device_platform": "android",
		"custom": map[string]any{
			"account_region_src": "fallback", "account_region": "cn",
			"host_bit": 64, "dragon_device_type": "phone",
		},
		"pre_installed_channel": "", "apk_first_install_time": now, "is_system_app": 0,
		"sdk_flavor": "china", "guest_mode": 0,
	}
	envelope, err := json.Marshal(map[string]any{
		"magic_tag": "ss_app_log", "header": header, "_gen_time": now,
	})
	if err != nil {
		return nil, errors.New("红果设备注册失败：无法准备注册内容")
	}
	body, err := hongguoTTEncrypt(envelope)
	if err != nil {
		return nil, errors.New("红果设备注册失败：无法准备加密注册内容")
	}

	address := hongguoPlaybackDeviceRegisterURL
	ticket, err := p.host.Reserve(ctx, address, "")
	if err != nil {
		return nil, err
	}
	requestCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	response, err := p.host.Fetch(requestCtx, core.HTTPRequest{
		Label: "红果设备注册", Method: http.MethodPost, URL: address, Body: body, Ticket: ticket,
		Limit: 64 << 10, Timeout: 20 * time.Second, FollowRedirects: true, AnyStatus: true,
		Header: map[string]string{
			"User-Agent": hongguoPlaybackRegisterUserAgent, "Accept": "application/json",
			"Content-Type":            "application/octet-stream;tt-data=a",
			"log-encode-type":         "gzip",
			"x-ss-dp":                 "8662",
			"x-ss-req-ticket":         strconv.FormatInt(now, 10),
			"x-vc-bdturing-sdk-version": "4.0.3.cn",
			"lc":                       "101",
			"sdk-version":              "2",
			"passport-sdk-version":     "5051452",
			"x-neptune":                "-8|50:51:59:30:40:47:49:39",
			"x-ss-stub":                strings.ToUpper(md5Hex(body)),
		},
	})
	if err != nil {
		return nil, err
	}
	if response.Status != http.StatusOK {
		return nil, fmt.Errorf("红果设备注册 HTTP %d", response.Status)
	}
	reply := map[string]any{}
	if err := json.Unmarshal(response.Body, &reply); err != nil {
		return nil, errors.New("红果设备注册返回格式异常")
	}
	// 没有 code 字段就是正常 —— 只看设备号与安装号。
	deviceID := firstNonEmptyString(reply["device_id_str"], reply["device_id"])
	installID := firstNonEmptyString(reply["install_id_str"], reply["install_id"])
	if !hongguoNumericID.MatchString(deviceID) || !hongguoNumericID.MatchString(installID) ||
		deviceID == "0" || installID == "0" {
		return nil, errors.New("红果设备注册未返回设备号")
	}
	return &hongguoPlaybackIdentity{
		DeviceID: deviceID, InstallID: installID, CDID: cdid, CreatedAt: time.Now(),
	}, nil
}

// hongguoTTEncrypt：站方注册接口要的 ttEncrypt 报文。
//
// 组成：固定前缀 + 32 字节随机 + AES-128-CBC/PKCS5 加密的（SHA-512(gzip) + gzip(信封)）。
// 密钥与 IV 由 SHA-512(SHA-512(随机) + 盐) 派生：前 16 字节是 key，后 16 字节是 iv。
func hongguoTTEncrypt(envelope []byte) ([]byte, error) {
	compressed, err := gzipBytes(envelope)
	if err != nil {
		return nil, err
	}
	random := make([]byte, 32)
	if _, err := rand.Read(random); err != nil {
		return nil, err
	}
	salt, err := hex.DecodeString(hongguoPlaybackKDFSalt)
	if err != nil {
		return nil, err
	}
	inner := sha512.Sum512(random)
	outer := sha512.Sum512(append(inner[:], salt...))
	key := outer[:16]
	iv := outer[16:32]

	plain := append(sha512.Sum512(compressed)[:], compressed...)
	pad := 16 - len(plain)%16
	for i := 0; i < pad; i++ {
		plain = append(plain, byte(pad))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	encrypted := make([]byte, len(plain))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(encrypted, plain)

	out := make([]byte, 0, 12+len(random)+len(encrypted))
	out = append(out, []byte("746305100000")...)
	out = append(out, random...)
	out = append(out, encrypted...)
	return out, nil
}

// gzipBytes：gzip 压缩（注册体要求）。
func gzipBytes(data []byte) ([]byte, error) {
	var buffer bytes.Buffer
	writer, err := gzip.NewWriterLevel(&buffer, gzip.BestCompression)
	if err != nil {
		return nil, err
	}
	if _, err := writer.Write(data); err != nil {
		return nil, err
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	return buffer.Bytes(), nil
}

// md5Hex：body 的 MD5（十六进制小写）。
func md5Hex(data []byte) string {
	sum := md5.Sum(data)
	return fmt.Sprintf("%x", sum)
}

// newHongguoPlaybackUUID：一个大写 UUID（客户端号与 cdid 都用它）。
func newHongguoPlaybackUUID() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	raw[6] = (raw[6] & 0x0f) | 0x40
	raw[8] = (raw[8] & 0x3f) | 0x80
	hexed := fmt.Sprintf("%x", raw)
	return strings.ToUpper(hexed[0:8] + "-" + hexed[8:12] + "-" + hexed[12:16] + "-" +
		hexed[16:20] + "-" + hexed[20:32]), nil
}

// newHongguoPlaybackHex：随机十六进制串（openudid 用）。
func newHongguoPlaybackHex(length int) string {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "0000000000000000"
	}
	return fmt.Sprintf("%x", raw)[:length]
}

// firstNonEmptyString：取第一个非空的字符串值。
func firstNonEmptyString(values ...any) string {
	for _, value := range values {
		if text, ok := value.(string); ok && text != "" {
			return text
		}
	}
	return ""
}
