package sources

import (
	"encoding/hex"
	"strings"
	"testing"
)

// 551 Argus 的黄金向量。
//
// 向量由 GPL-3.0 的 hongguoTV（kotlin-tv/core/.../Argus.kt）的同一套算法生成，
// 用来确认 Go 侧的移植与上游逐字节一致 —— 这类算法只靠「跑得通」测不出来，
// 差一个位就会变成站方那种「HTTP 200 + 0 字节」的静默拦截。
const (
	sign551VectorQuery = "ac=wifi&channel=update_64&aid=8662&app_name=novelread&version_code=73932" +
		"&version_name=7.3.9.32&device_platform=android&os=android&ssmix=a" +
		"&device_type=25053RT47C&device_brand=Redmi&language=zh&os_api=36&os_version=16" +
		"&manifest_version_code=73932&resolution=1280*2772&dpi=520&update_version_code=73932" +
		"&host_abi=arm64-v8a&dragon_device_type=phone&pv_player=73932&compliance_status=0" +
		"&need_personal_recommend=1&player_so_load=1&is_android_pad_screen=0" +
		"&device_id=1202245902801130&iid=1202245902805226&cdid=27B969C6-993A-4F4E-A061-2A78E1A965CC" +
		"&video_id=7704532501426867224&video_id_type=0&device_level=3" +
		"&need_all_video_definition=1&need_mp4_align=0&use_os_player=0&video_platform=1024" +
		"&source=0&from_video_id=&ts=1763300000&_rticket=1763300000123"
	sign551VectorArgus = "8oGtly/q30zomF9jsMsfO3JH1WF7TLiPqtHvN1FuiHsrhc+PdIrYefXosEK6ZZjO/" +
		"HDzyE0/DI50XiBSG+8d5+sdhRq6FYVZnIuHRb214/8H0P2fHiR4DUZBnSMujlYsvH0LMhock+8VGYxCfdq" +
		"VicFfjmkwDE6rn6Tl2Lc/Cdta0LM/uXkAze9xDdh2yO+XO+aenLVy3X9isyznGpQebSd5Cgvzqxm92rC3U1+" +
		"yy0cmM+wybMM9duiuQ4YPTHsfkImdz3tOocwjm0NIDHvmyATq"
	sign551VectorDecrypted = "08d2a4808204100218b9602204383636322a1031323032323435393032383031313330" +
		"320a313631313932313736343a08372e332e392e333242147630342e30342e30352d6f762d616e64726f" +
		"696448c094a04052080000000000000000580060c0cace910d6a06106e34a2b8c772062ee5f0cb154e7a" +
		"0c08011001180138ccd9cbbc0c820100a201046e6f6e65a801e205ba01110a064e583535314a1084402080b" +
		"0838708c8010207070707070707"
	sign551VectorLadon = "ESIzRDkJnKwe4XgdUocUY4m3HFJiOFD9GEufakOjqE0b/iD0"
)

// x-argus 必须与上游逐字节一致。
func TestSign551ArgusMatchesUpstream(t *testing.T) {
	got := hongguoSign551Argus(sign551VectorQuery, "", 1763300000, 8662, 1611921764,
		"1202245902801130", "", 12345)
	if got != sign551VectorArgus {
		t.Fatalf("x-argus 与上游不一致\n  期望 %s\n  实得 %s", sign551VectorArgus, got)
	}
}

// 往返验证：解开自己签的 x-argus，能还原出原始 protobuf。
func TestSign551ArgusRoundTrip(t *testing.T) {
	signed := hongguoSign551Argus(sign551VectorQuery, "", 1763300000, 8662, 1611921764,
		"1202245902801130", "", 12345)
	plain := hongguoSign551DecryptArgus(signed)
	if plain == nil {
		t.Fatal("解开 x-argus 失败")
	}
	if hex.EncodeToString(plain) != sign551VectorDecrypted {
		t.Fatalf("解出的 protobuf 与上游不一致\n  期望 %s\n  实得 %s",
			sign551VectorDecrypted, hex.EncodeToString(plain))
	}
	// 关键字段要能在明文里看到：设备号、许可号、版本、551 标记。
	for _, want := range []string{"1202245902801130", "1611921764", "7.3.9.32", "NX551J"} {
		if !strings.Contains(string(plain), want) {
			t.Fatalf("解出的 protobuf 里没有 %q", want)
		}
	}
}

// x-ladon 必须与上游逐字节一致。
func TestSign551LadonMatchesUpstream(t *testing.T) {
	got := hongguoSign551Ladon(1763300000, 1611921764, 8662, []byte{0x11, 0x22, 0x33, 0x44})
	if got != sign551VectorLadon {
		t.Fatalf("x-ladon 与上游不一致\n  期望 %s\n  实得 %s", sign551VectorLadon, got)
	}
}

// 查询串的参数顺序与编码都在签名里：改动任何一处，签名都必须变。
func TestSign551ArgusBindsQuery(t *testing.T) {
	base := hongguoSign551Argus(sign551VectorQuery, "", 1763300000, 8662, 1611921764,
		"1202245902801130", "", 12345)
	changed := strings.Replace(sign551VectorQuery, "video_id_type=0", "video_id_type=1", 1)
	other := hongguoSign551Argus(changed, "", 1763300000, 8662, 1611921764,
		"1202245902801130", "", 12345)
	if base == other {
		t.Fatal("query 变了但签名没变：签名没有绑定 query")
	}
	// 参数顺序变了，签名同样要变（顺序是签名的一部分）。
	reordered := "version_name=7.3.9.32&" + strings.TrimPrefix(sign551VectorQuery, "ac=wifi&")
	third := hongguoSign551Argus(reordered, "", 1763300000, 8662, 1611921764,
		"1202245902801130", "", 12345)
	if base == third {
		t.Fatal("query 顺序变了但签名没变：签名没有绑定参数顺序")
	}
}

// 时间戳也要绑定在签名里。
func TestSign551ArgusBindsTimestamp(t *testing.T) {
	base := hongguoSign551Argus(sign551VectorQuery, "", 1763300000, 8662, 1611921764,
		"1202245902801130", "", 12345)
	other := hongguoSign551Argus(sign551VectorQuery, "", 1763300001, 8662, 1611921764,
		"1202245902801130", "", 12345)
	if base == other {
		t.Fatal("时间戳变了但签名没变：签名没有绑定时间戳")
	}
}

// 从 query 里取参数：签名要用 version_name 与 aid。
func TestSign551QueryParam(t *testing.T) {
	if got := hongguoQueryParam(sign551VectorQuery, "version_name"); got != "7.3.9.32" {
		t.Fatalf("version_name 取错：%q", got)
	}
	if got := hongguoQueryParam(sign551VectorQuery, "aid"); got != "8662" {
		t.Fatalf("aid 取错：%q", got)
	}
	if got := hongguoQueryParam(sign551VectorQuery, "from_video_id"); got != "" {
		t.Fatalf("空值参数取错：%q", got)
	}
	if got := hongguoQueryParam(sign551VectorQuery, "不存在"); got != "" {
		t.Fatalf("不存在的参数应返回空：%q", got)
	}
}

// 设备号是签名的一部分：换设备号，签名必须变。
func TestSign551ArgusBindsDeviceID(t *testing.T) {
	base := hongguoSign551Argus(sign551VectorQuery, "", 1763300000, 8662, 1611921764,
		"1202245902801130", "", 12345)
	other := hongguoSign551Argus(sign551VectorQuery, "", 1763300000, 8662, 1611921764,
		"1202245902809999", "", 12345)
	if base == other {
		t.Fatal("设备号变了但签名没变：签名没有绑定设备号")
	}
}
