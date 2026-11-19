package sources

import "testing"

// 编译期 flavor 机制要保证：
//   - 红果版（无 tag）：只启用红果；
//   - 真果鉴版（-tags=zhenguojian）：启用全部站源。
//
// 上游在 11-14 的 cf0dc7a 把 flavor 整个删了（核心不再内置站源，
// 改成运行时安装 JS 模块），但我们仍有两个包要能同时装在同一台 Apple TV 上，
// 所以在自己的站源包里补了这套机制。

func TestSourceFlavorSelection(t *testing.T) {
	if sourceFlavorAll {
		// 真果鉴版：红果必须在名单里，其余站源也不该被排除。
		for _, id := range []string{"hongguo", "beabox", "dsd", "guipian", "hanxiaoquan",
			"heitao", "huangdou", "huangguo-video", "huangguoai", "huangju",
			"jinguo", "jinguoduanju", "cloudfront", "sorani", "yeguo"} {
			if !sourceEnabledInFlavor(id) {
				t.Fatalf("真果鉴版不该排除站源 %q", id)
			}
		}
		return
	}
	// 红果版：只有红果。
	if !sourceEnabledInFlavor("hongguo") {
		t.Fatal("红果版必须包含红果")
	}
	for _, id := range []string{"beabox", "dsd", "guipian", "hanxiaoquan", "heitao",
		"huangdou", "huangguo-video", "huangguoai", "huangju", "jinguo",
		"jinguoduanju", "cloudfront", "sorani", "yeguo"} {
		if sourceEnabledInFlavor(id) {
			t.Fatalf("红果版不该包含站源 %q", id)
		}
	}
}
