package sources

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"duanjuapp/native/core"
)

// 红果播放取址：官方 App 当前在用的那条路（2026-11-16 起）。
//
// 站方在 2026-10-27、11-02、11-10、11-16 连续改了取址与签名的校验方式，
// 每一代都把上一代彻底作废（带旧签名的请求一律回 HTTP 200 + 0 字节的
// 空体 —— 软拦截，看不到任何错误码）。当前这一代有三个要点，缺一个就又是空体：
//
//  1. 端点与方法是官方那一套：POST /novel/player/multi_video_model/player/v1
//     （主机是 sinfonline**a**，与普通请求的 sinfonline**b** 不同）。
//  2. 参数在 **body** 里（mixed_video_id_map + dr_scene），不在 query。
//     device_level 用 **1**（低端机档位）：用 3 时部分剧集只返回 H.266 线路，
//     取流直接失败（上游 changelog 2.0.2+114）。
//  3. 签名是 **v5**（X-Helios / X-Medusa / X-SS-STUB），不是上一代的
//     x-argus / x-gorgon —— 官方测试里明确断言这两个头必须不存在。
//
// 签名还有一个容易忽略的机制：v5 要找一个 _rticket 使 (IV & 15) == 12，
// 最多试 1024 次；找不到就说明这次请求必然被空答。
// 这就是「随机空答」的真正来源 —— 不是站方随机拒绝，是签名没落在对的分支上。

const (
	// 取址路径与主机（官方那一套）。
	hongguoPlaybackPath = "/novel/player/multi_video_model/player/v1"
	hongguoPlaybackHost = "api5-normal-sinfonlinea.fqnovel.com"
	// 取址这条请求戴的 UA：视频 UA，客户端版本 73932。
	hongguoPlaybackUserAgent = "com.phoenix.read/73932 (Linux; U; Android 12; zh_CN_#Hans; PGT-AN10; Build/V417IR;tt-ok/3.12.13.20)"
	// 一次取址最多换几个身份（官方 deviceRotations）。
	hongguoPlaybackMaxIdentities = 4
	// 一个注册身份最多用多久（两小时换一次）。
	hongguoPlaybackIdentityMaxAge = 2 * time.Hour
)

// 官方 playbackQuery 的参数：设备是一台 vivo PGT-AN10 / Android 12 / 7.4.3.32。
//
// 这些字段要进 v5 签名（X-Medusa 里的 who），所以不能随便改。
var hongguoPlaybackQueryFields = []struct {
	key   string
	value string
}{
	{"aid", "8662"}, {"app_name", "novelread"},
	{"version_code", "74332"}, {"version_name", "7.4.3.32"},
	{"channel", "vivo_8662_64"}, {"device_platform", "android"},
	{"device_type", "PGT-AN10"}, {"os_version", "12"},
	{"update_version_code", "74332"},
}

// 官方 appQuery 的参数（注册与普通 App 请求共用）。
var hongguoAppQueryFields = []struct {
	key   string
	value string
}{
	{"aid", "8662"}, {"app_name", "novelread"},
	{"version_code", "73532"}, {"version_name", "7.3.5.32"},
	{"manifest_version_code", "73532"}, {"update_version_code", "73532"},
	{"channel", "update_64"}, {"device_platform", "android"}, {"os", "android"},
	{"ssmix", "a"}, {"device_type", "25053RT47C"}, {"device_brand", "Redmi"},
	{"language", "zh"}, {"os_api", "36"}, {"os_version", "16"},
	{"resolution", "1280*2772"}, {"dpi", "520"}, {"ac", "wifi"},
}

// hongguoPlaybackIdentity：站方发的注册身份（device_id / iid / cdid）。
type hongguoPlaybackIdentity struct {
	DeviceID  string
	InstallID string
	CDID      string
	CreatedAt time.Time
}

// 身份缓存：好号跨集复用（站方发号有配额，换太勤会被拒）。
var (
	hongguoPlaybackIdentityMu sync.Mutex
	hongguoPlaybackIdentities  = map[string]*hongguoPlaybackIdentity{}
)

// resolveHongguoTabMedia：走官方那条路取播放地址。
func (p *hongguoProvider) resolveHongguoTabMedia(ctx context.Context, videoID string) (core.ProviderMedia, error) {
	if !hongguoNumericID.MatchString(videoID) {
		return core.ProviderMedia{}, errors.New("红果视频 ID 无效")
	}
	model, err := p.hongguoPlaybackModel(ctx, videoID)
	if err != nil {
		return core.ProviderMedia{}, err
	}
	return selectHongguoAppMedia(model)
}

// hongguoPlaybackModel：拿一个身份问这一集；这个身份整轮都空答，就换一个新身份再问。
func (p *hongguoProvider) hongguoPlaybackModel(ctx context.Context, videoID string) (map[string]any, error) {
	var identity *hongguoPlaybackIdentity
	var failure error
	sawEmpty := false

	for round := 0; round < hongguoPlaybackMaxIdentities; round++ {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if identity == nil {
			fresh, err := p.hongguoPlaybackIdentity(ctx)
			if err != nil {
				// 注册被拒是站方「现在不发设备给你」，再问只会把限流拉长 —— 直接上抛，
				// 不要让它被后面的空答盖成「空内容」而掉到公开页。
				return nil, err
			}
			identity = fresh
		}
		model, err := p.hongguoPlaybackModelOnce(ctx, videoID, identity)
		if err != nil {
			failure = err
			continue
		}
		if model != nil {
			return model, nil
		}
		sawEmpty = true
		// 这个身份整轮都空答：站方发的号有一半是坏的（注册响应里看不出来，
		// 只有拿号去取址才知道），坏号不会自己变好 —— 丢掉换新的。
		p.dropHongguoPlaybackIdentity()
		identity = nil
	}

	if !sawEmpty && failure != nil {
		return nil, failure
	}
	if failure != nil {
		return nil, fmt.Errorf("红果取址接口未返回有效数据：%w", failure)
	}
	return nil, errors.New("红果取址接口未返回有效数据（站方连续返回空答）")
}

// hongguoPlaybackModelOnce：一次取址请求。
func (p *hongguoProvider) hongguoPlaybackModelOnce(ctx context.Context, videoID string,
	identity *hongguoPlaybackIdentity) (map[string]any, error) {
	body, err := json.Marshal(map[string]any{
		"biz_param": map[string]any{
			"detail_page_version": 0,
			// 低端机档位：用 3 时部分剧集只返回 H.266 线路，取流直接失败。
			"device_level":              1,
			"disable_digg_stat":         false,
			"disable_video_relate_book": false,
			"need_all_video_definition": true,
			"need_mp4_align":            false,
			"use_os_player":             false,
			"use_server_dns":             false,
			"video_platform":            1024,
		},
		"mixed_video_id_map": map[string]any{"1004": []string{videoID}},
		"dr_scene":                  "player",
	})
	if err != nil {
		return nil, errors.New("红果取址请求准备失败")
	}

	values := map[string]string{}
	for _, field := range hongguoPlaybackQueryFields {
		values[field.key] = field.value
	}
	values["device_id"] = identity.DeviceID
	values["iid"] = identity.InstallID
	values["cdid"] = identity.CDID

	query, headers, err := hongguoV5SignedHeaders(values, body, hongguoV5NowMs())
	if err != nil {
		return nil, err
	}

	address := "https://" + hongguoPlaybackHost + hongguoPlaybackPath + "?" + query
	requestCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	response, err := p.host.Fetch(requestCtx, core.HTTPRequest{
		Label: "红果取址", Method: "POST", URL: address, Body: body,
		Limit: 4 << 20, Timeout: 20 * time.Second, FollowRedirects: true, AnyStatus: true,
		Header: map[string]string{
			"User-Agent": hongguoPlaybackUserAgent,
			"Accept":     "application/json; charset=utf-8,application/x-protobuf",
			"X-Khronos":  headers["X-Khronos"],
			"X-Helios":   headers["X-Helios"],
			"X-Medusa":   headers["X-Medusa"],
			"X-SS-STUB":  headers["X-SS-STUB"],
		},
	})
	if err != nil {
		return nil, err
	}
	if response.Status != 200 {
		return nil, fmt.Errorf("红果取址接口 HTTP %d", response.Status)
	}
	if len(response.Body) == 0 {
		// 空答：站方对这条路的随机软拦截（签名分支不对或号是坏的）。
		return nil, errors.New("红果取址接口返回空答")
	}
	var reply map[string]any
	if err := json.Unmarshal(response.Body, &reply); err != nil {
		return nil, errors.New("红果取址接口返回格式异常")
	}
	code := ""
	if raw, ok := reply["code"]; ok {
		code = fmt.Sprintf("%v", raw)
	} else if raw, ok := reply["Code"]; ok {
		code = fmt.Sprintf("%v", raw)
	}
	if code != "" && code != "0" {
		return nil, fmt.Errorf("红果取址接口暂不可用（%s）", code)
	}
	data, _ := reply["data"].(map[string]any)
	if data == nil {
		return nil, errors.New("红果取址接口没有数据")
	}
	// 模型可能挂在 data 下，也可能挂在 data["1004"] 下（官方两种形状都处理）。
	rows := data
	if nested, ok := data["1004"].(map[string]any); ok {
		rows = nested
	}
	row, _ := rows[videoID].(map[string]any)
	if row == nil {
		for _, value := range rows {
			if candidate, ok := value.(map[string]any); ok && candidate["video_model"] != nil {
				row = candidate
				break
			}
		}
	}
	if row == nil {
		return nil, errors.New("红果取址接口没有这一集的数据")
	}
	raw, ok := row["video_model"]
	if !ok {
		return nil, errors.New("红果取址接口没有播放模型")
	}
	var model map[string]any
	switch value := raw.(type) {
	case map[string]any:
		model = value
	case string:
		decoded, err := decodeHongguoBase64(value)
		if err != nil {
			decoded = []byte(value)
		}
		if err := json.Unmarshal(decoded, &model); err != nil {
			return nil, errors.New("红果播放模型格式异常")
		}
	default:
		return nil, errors.New("红果播放模型类型不对")
	}
	if len(model) == 0 {
		// 官方还兼容一种形状：video_list 直接挂在 data 下。
		if list := anyList(data["video_list"]); len(list) > 0 {
			model = map[string]any{
				"video_list":     data["video_list"],
				"video_duration": data["video_duration"],
				"duration":       data["duration"],
			}
		}
	}
	if len(model) == 0 {
		return nil, errors.New("红果播放模型是空的")
	}
	return model, nil
}

// MARK: - 身份

// cryptoRandomInt：随机 32 位整数。
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
func (p *hongguoProvider) hongguoPlaybackIdentity(ctx context.Context) (*hongguoPlaybackIdentity, error) {
	hongguoPlaybackIdentityMu.Lock()
	cached, ok := hongguoPlaybackIdentities[p.hongguoIdentityKey()]
	if ok && time.Since(cached.CreatedAt) < hongguoPlaybackIdentityMaxAge {
		hongguoPlaybackIdentityMu.Unlock()
		return cached, nil
	}
	if ok {
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

// hongguoIdentityKey：身份缓存的键（同一台设备共用一个身份）。
func (p *hongguoProvider) hongguoIdentityKey() string {
	return "hongguo-playback"
}

// dropHongguoPlaybackIdentity：丢掉当前身份（这一整轮都空答，说明是坏号）。
func (p *hongguoProvider) dropHongguoPlaybackIdentity() {
	hongguoPlaybackIdentityMu.Lock()
	delete(hongguoPlaybackIdentities, p.hongguoIdentityKey())
	hongguoPlaybackIdentityMu.Unlock()
}

// hongguoPlaybackDeviceRegisterURL：注册设备用的地址（官方那一套）。
const hongguoPlaybackDeviceRegisterURL = "https://log.snssdk.com/service/2/device_register/"

// hongguoPlaybackRegisterUserAgent：注册时戴的 UA（App 自己的，不是取址那个）。
const hongguoPlaybackRegisterUserAgent = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

// registerHongguoPlaybackDevice：注册一个匿名设备，拿回身份。
//
// 注册响应里**没有 code 字段** —— 按「code 不为 0 就失败」来读会把成功判成失败。
// 正确的判法是「device_id / install_id 都是合法的数字且不为 0」。
func (p *hongguoProvider) registerHongguoPlaybackDevice(ctx context.Context) (*hongguoPlaybackIdentity, error) {
	cdid := newHongguoPlaybackUUID()
	header := map[string]any{
		"display_name": "红果免费短剧", "aid": 8662, "app_version": "7.3.5.32", "version_code": 73532,
		"manifest_version_code": 73532, "update_version_code": 73532, "channel": "update_64",
		"package": "com.phoenix.read", "app_language": "zh", "os": "Android", "os_version": "16",
		"os_api": 36, "device_model": "25053RT47C", "device_brand": "Redmi", "device_manufacturer": "Xiaomi",
		"cpu_abi": "arm64-v8a", "density_dpi": 520, "display_density": "xxhdpi", "resolution": "2772x1280",
		"language": "zh", "timezone": 8, "access": "wifi",
		"openudid": newHongguoPlaybackHex(8), "clientudid": newHongguoPlaybackUUID(), "cdid": cdid,
		"region": "CN", "tz_name": "Asia/Shanghai", "tz_offset": 28800, "sim_region": "cn",
		"device_platform": "android", "not_request_sender": 0, "is_system_app": 0,
		"sdk_flavor": "china", "rom": "OS2.0", "rom_version": "BP2A.250605.031.A3",
	}
	body, err := json.Marshal(map[string]any{
		"magic_tag": "ss_app_log", "header": header, "_gen_time": time.Now().UnixMilli(),
	})
	if err != nil {
		return nil, errors.New("红果设备注册失败：无法准备注册内容")
	}

	query := url.Values{}
	for _, field := range hongguoAppQueryFields {
		query.Set(field.key, field.value)
	}
	query.Del("device_id")
	query.Del("iid")
	query.Set("req_id", newHongguoPlaybackUUID())
	query.Set("_rticket", strconv.FormatInt(time.Now().UnixMilli(), 10))
	address := hongguoPlaybackDeviceRegisterURL + "?" + query.Encode()

	ticket, err := p.host.Reserve(ctx, address, "")
	if err != nil {
		return nil, err
	}
	requestCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	response, err := p.host.Fetch(requestCtx, core.HTTPRequest{
		Label: "红果设备注册", Method: "POST", URL: address, Body: body, Ticket: ticket,
		Limit: 64 << 10, Timeout: 20 * time.Second, FollowRedirects: true, AnyStatus: true,
		Header: map[string]string{
			"User-Agent": hongguoPlaybackRegisterUserAgent, "Accept": "application/json",
			"Content-Type": "application/json; charset=utf-8",
		},
	})
	if err != nil {
		return nil, err
	}
	if response.Status >= 500 {
		return nil, fmt.Errorf("红果设备注册 HTTP %d", response.Status)
	}
	reply := map[string]any{}
	if err := json.Unmarshal(response.Body, &reply); err != nil {
		return nil, errors.New("红果设备注册返回格式异常")
	}
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

// newHongguoPlaybackUUID：一个大写 UUID。
// 随机源出错时退回一个固定值：注册只是要一个唯一标识，
// 拿不到随机数不该让整次注册失败。
func newHongguoPlaybackUUID() string {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		raw = [16]byte{0x5c, 0x2a, 0x9e, 0x71, 0x30, 0xd4, 0x18, 0x6b,
			0x8f, 0x24, 0x50, 0xc7, 0x93, 0x11, 0x6d, 0xe2}
	}
	raw[6] = (raw[6] & 0x0f) | 0x40
	raw[8] = (raw[8] & 0x3f) | 0x80
	hexed := fmt.Sprintf("%x", raw)
	return strings.ToUpper(hexed[0:8] + "-" + hexed[8:12] + "-" + hexed[12:16] + "-" +
		hexed[16:20] + "-" + hexed[20:32])
}

// newHongguoPlaybackHex：随机十六进制串。
func newHongguoPlaybackHex(length int) string {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "0000000000000000"
	}
	hexed := fmt.Sprintf("%x", raw)
	if length > len(hexed) {
		return hexed
	}
	return hexed[:length]
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
