package sources

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"duanjuapp/native/core"
)

// 红果播放取址：官方 App 现在用的那条 GET 路。
//
// 站方在 2026-10-27、11-02、11-10、11-11 连续改了四次取址与签名的校验方式，
// 旧的 POST /novel/player/video_model/v1/ 一族已经被关掉：带签名的请求一律回
// HTTP 200 + 0 字节（软拦截，看不到任何错误码），表现就是「红果 App 接口未返回有效数据」。
//
// 现在这条 GET 的三个要点，缺一个就又是 0 字节：
//
//  1. 参数全在 query 上，body 是空的。少一个业务参数，服务端回 100103 PARAM_INVALID。
//     query 的**参数顺序与百分号编码**也参与签名，必须与上游 App 一字不差。
//  2. 身份必须是站方注册过的（device_id / iid / cdid 三个字段），并且要带真签名
//     （551 Argus / Ladon）—— 2026-11-11 起站方收紧了签名，占位签名一律被拦。
//  3. 站方发的号**大约一半是坏的**：坏号整轮都空答且不会自己变好，好号可以跨集复用。
//     所以整轮空答就换一个新身份，最多换 8 个；好号要一直用，别浪费站方的发号配额。

const (
	// 取址路径（GET，参数全在 query 上）。
	hongguoPlaybackTabPath = "/reading/bookapi/video_tab/multi_video_model/v1/"
	// 取址主机：主域偶尔空答，备用域顶上。
	hongguoPlaybackHostPrimary = "api5-normal-sinfonlineb.fqnovel.com"
	hongguoPlaybackHostBackup   = "api5-normal-hl.fqnovel.com"
	// 取址这条 GET 戴的 UA：视频 UA，客户端版本换成 73932。
	hongguoPlaybackTabUserAgent = "com.phoenix.read/73932 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
	// 一次取址最多换几个身份：站方发号大约一半好，八个全坏的概率约 0.4%。
	hongguoPlaybackMaxIdentities = 8
	// 一个注册身份最多用多久（两小时换一次，避免站方慢慢不看它了）。
	hongguoPlaybackIdentityMaxAge = 2 * time.Hour
)

// 取址这条 GET 用的设备参数：73932 / 7.3.9.32，顺序照抄站方 App。
// 顺序不是排版问题：签名把 query 的字节原样算进去。
var hongguoPlaybackDeviceParams = []struct {
	key   string
	value string
}{
	{"ac", "wifi"}, {"channel", "update_64"}, {"aid", "8662"}, {"app_name", "novelread"},
	{"version_code", "73932"}, {"version_name", "7.3.9.32"}, {"device_platform", "android"},
	{"os", "android"}, {"ssmix", "a"}, {"device_type", "25053RT47C"}, {"device_brand", "Redmi"},
	{"language", "zh"}, {"os_api", "36"}, {"os_version", "16"}, {"manifest_version_code", "73932"},
	{"resolution", "1280*2772"}, {"dpi", "520"}, {"update_version_code", "73932"},
	{"host_abi", "arm64-v8a"}, {"dragon_device_type", "phone"}, {"pv_player", "73932"},
	{"compliance_status", "0"}, {"need_personal_recommend", "1"}, {"player_so_load", "1"},
	{"is_android_pad_screen", "0"},
}

// hongguoPlaybackIdentity：站方发的注册身份。三个字段都得带上 ——
// cdid 是注册 body 里那个原样带回来的值，不是每个请求重新随机的。
type hongguoPlaybackIdentity struct {
	DeviceID string
	InstallID string
	CDID     string
	CreatedAt time.Time
}

// resolveHongguoTabMedia：走 GET video_tab 取播放地址。
func (p *hongguoProvider) resolveHongguoTabMedia(ctx context.Context, videoID string) (core.ProviderMedia, error) {
	if !hongguoNumericID.MatchString(videoID) {
		return core.ProviderMedia{}, errors.New("红果视频 ID 无效")
	}
	model, err := p.hongguoTabVideoModel(ctx, videoID)
	if err != nil {
		return core.ProviderMedia{}, err
	}
	return selectHongguoAppMedia(model)
}

// hongguoTabVideoModel：拿一个身份问这一集；这个身份整轮都空答，就换一个新身份再问。
//
// 站方对这条 GET 会**按请求随机回空答**（HTTP 200 + 0 字节）：不是限流、不是设备问题，
// 是掷骰子。实测主域对某些客户端持续空答、备用域偶尔能出。
// 所以同一个身份的几次询问是**并发发出**的 —— 串行问等于按骰子的顺序排队，
// 并发问是一把梭，同一批里只要有一个不是空答就拿到了。
func (p *hongguoProvider) hongguoTabVideoModel(ctx context.Context, videoID string) (map[string]any, error) {
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
		model, err := p.hongguoTabVideoModelWave(ctx, videoID, identity)
		if err != nil {
			failure = err
		}
		if model != nil {
			return model, nil
		}
		sawEmpty = true
		// 这个身份整轮都空答：坏号是永久坏的（实测），留着只会一直空答。丢掉换新的。
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

// hongguoTabVideoModelWave：并发发出几波询问，拿到第一个有数据的就返回。
//
// 同一波里各次询问用的是**同一份 query 与同一份签名**（签名绑的是 query 原文，
// 多次发同一份是最省事也最不容易算错的做法）。站方按请求随机决定答不答，
// 所以并发比串行快得多、命中率高得多。
func (p *hongguoProvider) hongguoTabVideoModelWave(ctx context.Context, videoID string,
	identity *hongguoPlaybackIdentity) (map[string]any, error) {
	const waveSize = 6
	// 同一波里各次询问用**同一份 query 与同一份签名**：签名绑的是 query 原文，
	// 多次发同一份是最不容易算错的做法；站方是按请求随机决定答不答，
	// 所以这一波里只要有一个不是空答就拿到了。
	stamp := time.Now().Unix()
	query := hongguoPlaybackQuery(videoID, identity, stamp, time.Now().UnixMilli())
	signature := hongguoSign551Headers(query, "", stamp)
	if len(signature) == 0 {
		return nil, errors.New("红果签名生成失败")
	}
	results := make(chan map[string]any, waveSize)
	errs := make(chan error, waveSize)
	for i := 0; i < waveSize; i++ {
		go func() {
			model, err := p.hongguoTabVideoModelWithQuery(ctx, query, signature, videoID)
			if err != nil {
				errs <- err
				return
			}
			if model != nil {
				results <- model
				return
			}
			errs <- nil
		}()
	}
	var lastErr error
	for i := 0; i < waveSize; i++ {
		select {
		case model := <-results:
			return model, nil
		case err := <-errs:
			if err != nil {
				lastErr = err
			}
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return nil, lastErr
}

// hongguoTabVideoModelOnce：一次 GET；空答、结构不对、业务码非 0 都算没有。
func (p *hongguoProvider) hongguoTabVideoModelOnce(ctx context.Context, videoID string,
	identity *hongguoPlaybackIdentity) (map[string]any, error) {
	stamp := time.Now().Unix()
	query := hongguoPlaybackQuery(videoID, identity, stamp, time.Now().UnixMilli())
	signature := hongguoSign551Headers(query, "", stamp)
	if len(signature) == 0 {
		return nil, errors.New("红果签名生成失败")
	}
	return p.hongguoTabVideoModelWithQuery(ctx, query, signature, videoID)
}

// hongguoTabVideoModelWithQuery：用给定的 query 与签名发一次取址请求。
func (p *hongguoProvider) hongguoTabVideoModelWithQuery(ctx context.Context, query string,
	signature map[string]string, videoID string) (map[string]any, error) {
	var lastErr error
	for _, host := range []string{hongguoPlaybackHostPrimary, hongguoPlaybackHostBackup} {
		body, err := p.hongguoPlaybackText(ctx, host, query, signature)
		if err != nil {
			lastErr = err
			continue
		}
		if strings.TrimSpace(body) == "" {
			// 站方对这条 GET 按请求随机回空答（HTTP 200 + 0 字节）。
			lastErr = errors.New("红果取址接口返回空答")
			continue
		}
		var reply map[string]any
		if err := json.Unmarshal([]byte(body), &reply); err != nil {
			lastErr = errors.New("红果取址接口返回格式异常")
			continue
		}
		code := 0
		if raw, ok := reply["code"]; ok {
			code = int(toFloat64(raw))
		} else if raw, ok := reply["Code"]; ok {
			code = int(toFloat64(raw))
		}
		if code != 0 {
			lastErr = fmt.Errorf("红果取址接口返回业务码 %d", code)
			continue
		}
		data, _ := reply["data"].(map[string]any)
		if data == nil {
			lastErr = errors.New("红果取址接口没有数据")
			continue
		}
		// 模型挂在 video_model_data 下面这一集的位置上；老形状直接挂在 data 下面。
		rows, _ := data["video_model_data"].(map[string]any)
		if rows == nil {
			rows = data
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
			lastErr = errors.New("红果取址接口没有这一集的数据")
			continue
		}
		raw, ok := row["video_model"]
		if !ok {
			lastErr = errors.New("红果取址接口没有播放模型")
			continue
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
				lastErr = errors.New("红果播放模型格式异常")
				continue
			}
		default:
			lastErr = errors.New("红果播放模型类型不对")
			continue
		}
		if len(model) == 0 {
			lastErr = errors.New("红果播放模型是空的")
			continue
		}
		return model, nil
	}
	if lastErr == nil {
		lastErr = errors.New("红果取址接口未返回有效数据")
	}
	return nil, lastErr
}

// hongguoPlaybackText：发一次带签名的 GET。
func (p *hongguoProvider) hongguoPlaybackText(ctx context.Context, host, query string,
	signature map[string]string) (string, error) {
	address := "https://" + host + hongguoPlaybackTabPath + "?" + query
	requestCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	response, err := p.host.FetchText(requestCtx, core.TextRequest{
		URL:       address,
		Referer:   "https://" + host + "/",
		UserAgent: hongguoPlaybackTabUserAgent,
	})
	if err != nil {
		return "", err
	}
	return response.Body, nil
}

// hongguoPlaybackQuery：取址这条 GET 的 query，顺序照抄站方 App。
//
// 签名是按 query 的字节算的，顺序变了就是另一份签名，服务端会静默丢弃。
func hongguoPlaybackQuery(videoID string, identity *hongguoPlaybackIdentity, stamp int64, ticket int64) string {
	parts := make([]string, 0, len(hongguoPlaybackDeviceParams)+12)
	for _, item := range hongguoPlaybackDeviceParams {
		parts = append(parts, hongguoPlaybackEncode(item.key)+"="+hongguoPlaybackEncode(item.value))
	}
	parts = append(parts,
		"device_id="+hongguoPlaybackEncode(identity.DeviceID),
		"iid="+hongguoPlaybackEncode(identity.InstallID),
		"cdid="+hongguoPlaybackEncode(identity.CDID),
		"video_id="+hongguoPlaybackEncode(videoID),
		"video_id_type=0",
		"device_level=3",
		"need_all_video_definition=1",
		"need_mp4_align=0",
		"use_os_player=0",
		"video_platform=1024",
		"source=0",
		"from_video_id=",
		"ts="+strconv.FormatInt(stamp, 10),
		"_rticket="+strconv.FormatInt(ticket, 10),
	)
	return strings.Join(parts, "&")
}

// hongguoPlaybackEncode：站方 App 自己的百分号编码。
//
// 与 encodeURIComponent 语义相同，只差一处：`*` **不转义** ——
// resolution=1280*2772 里的星号原样留在 query 上。
// 签名按 query 字节算，多编一个字符服务端就对不上，只能照抄。
func hongguoPlaybackEncode(value string) string {
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

// hongguoSign551Headers：生成这条 GET 要带的签名头。
func hongguoSign551Headers(query, stubHex string, stamp int64) map[string]string {
	aid := int64(0)
	if raw := hongguoQueryParam(query, "aid"); raw != "" {
		aid, _ = strconv.ParseInt(raw, 10, 64)
	}
	deviceID := hongguoQueryParam(query, "device_id")
	installID := hongguoQueryParam(query, "iid")
	randField, err := cryptoRandomInt()
	if err != nil {
		randField = 12345
	}
	ladonRandom := make([]byte, 4)
	if _, err := cryptoRandomRead(ladonRandom); err != nil {
		copy(ladonRandom, []byte{0x11, 0x22, 0x33, 0x44})
	}
	headers := map[string]string{
		"x-ss-req-ticket":       strconv.FormatInt(stamp*1000, 10),
		"x-khronos":             strconv.FormatInt(stamp, 10),
		"x-ladon":               hongguoSign551Ladon(stamp, hongguoSign551LicenseID, aid, ladonRandom),
		"x-argus":               hongguoSign551Argus(query, stubHex, stamp, aid, hongguoSign551LicenseID, deviceID, installID, randField),
		"passport-sdk-version":  "50561",
		"x-ss-dp":               "8662",
		"x-tt-request-tag":      "t=0;n=0",
		"x-tt-dt":               "",
		"x-tt-store-region":     "cn",
		"x-tt-store-region-src": "did",
	}
	return headers
}

// toFloat64：把 JSON 里的数字（可能是 json.Number 或 float64）转成 float64。
func toFloat64(value any) float64 {
	switch typed := value.(type) {
	case float64:
		return typed
	case int:
		return float64(typed)
	case int64:
		return float64(typed)
	case json.Number:
		number, _ := typed.Float64()
		return number
	case string:
		number, _ := strconv.ParseFloat(typed, 64)
		return number
	}
	return 0
}
