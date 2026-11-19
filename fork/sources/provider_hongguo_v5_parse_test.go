package sources

import (
	"encoding/json"
	"testing"
)

// 红果取址的响应有两种形状，官方与上游 tvOS 2.56 都要支持：
//
//  1. data["1004"][集].video_model —— 播放模型是一段 JSON 字符串，要再 parse 一次；
//  2. data["1004"][集].video_list —— 这一集直接给 video_list，没有 video_model 包装。
//
// 这两种形状曾经漏掉过第二种，取址会直接报「没有播放模型」。

func TestHongguoPlaybackParsesVideoModelString(t *testing.T) {
	model := map[string]any{
		"video_duration": 80.5,
		"video_list": []any{map[string]any{
			"main_url":   "https://media.example.invalid/main.mp4",
			"video_meta": map[string]any{"codec_type": "bytevc1", "definition": "1080p"},
		}},
	}
	encoded, err := json.Marshal(model)
	if err != nil {
		t.Fatal(err)
	}
	reply := map[string]any{
		"code": "0",
		"data": map[string]any{
			"1004": map[string]any{
				"7704532501426867224": map[string]any{
					"video_model": string(encoded),
				},
			},
		},
	}
	parsed := parseHongguoPlaybackReply(reply, "7704532501426867224")
	if parsed == nil {
		t.Fatal("video_model 形状没解析出来")
	}
	if list := anyList(parsed["video_list"]); len(list) != 1 {
		t.Fatalf("video_list 数量不对：%d", len(list))
	}
}

// 这一集直接给 video_list（没有 video_model 包装）时也要能解析出来。
func TestHongguoPlaybackParsesDirectVideoList(t *testing.T) {
	reply := map[string]any{
		"code": "0",
		"data": map[string]any{
			"1004": map[string]any{
				"7704532501426867224": map[string]any{
					"video_duration": 80.5,
					"video_list": []any{map[string]any{
						"main_url":   "https://media.example.invalid/direct.mp4",
						"video_meta": map[string]any{"codec_type": "bytevc1", "definition": "1080p"},
					}},
				},
			},
		},
	}
	parsed := parseHongguoPlaybackReply(reply, "7704532501426867224")
	if parsed == nil {
		t.Fatal("video_list 直出的形状没解析出来")
	}
	if list := anyList(parsed["video_list"]); len(list) != 1 {
		t.Fatalf("video_list 数量不对：%d", len(list))
	}
}

// 解析出来之后要能选出可播的那一条。
func TestHongguoPlaybackSelectsPlayableVariant(t *testing.T) {
	reply := map[string]any{
		"code": "0",
		"data": map[string]any{
			"1004": map[string]any{
				"7704532501426867224": map[string]any{
					"video_list": []any{
						map[string]any{
							"main_url":   "https://media.example.invalid/hevc2.mp4",
							"video_meta": map[string]any{"codec_type": "bytevc2", "definition": "1080p"},
						},
						map[string]any{
							"main_url":   "https://media.example.invalid/hevc1.mp4",
							"video_meta": map[string]any{"codec_type": "bytevc1", "definition": "1080p"},
						},
					},
				},
			},
		},
	}
	parsed := parseHongguoPlaybackReply(reply, "7704532501426867224")
	if parsed == nil {
		t.Fatal("没解析出来")
	}
	media, err := selectHongguoAppMedia(parsed)
	if err != nil {
		t.Fatalf("选不出可播的线路：%v", err)
	}
	if media.URL != "https://media.example.invalid/hevc1.mp4" {
		t.Fatalf("应该选 bytevc1 那条，实得 %s", media.URL)
	}
	if media.Quality != 1080 {
		t.Fatalf("清晰度不对：%d", media.Quality)
	}
}
