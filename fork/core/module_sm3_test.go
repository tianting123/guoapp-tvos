package core

import (
	"encoding/hex"
	"strings"
	"testing"
)

// 站源模块（JS）要用 SM3 —— 官方红果模块的 v5 播放签名依赖它。
// 上游宿主原本只提供 md5 / sha256，缺 SM3，官方模块跑不起来，
// 所以 core 里补了 ModuleSM3 并暴露为 host.sm3。
//
// 这里验证两件事：
//  1. SM3 实现符合标准（与标准测试向量一致）；
//  2. 宿主把 sm3 暴露给 JS 后，模块能算出官方期望的 query 哈希。

func TestModuleSM3MatchesStandardVector(t *testing.T) {
	// GB/T 32905-2016 标准测试向量：abc → 66c7f0f4…
	sum := ModuleSM3([]byte("abc"))
	got := hex.EncodeToString(sum[:])
	want := "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0"
	if got != want {
		t.Fatalf("SM3(abc) 与标准不符\n  期望 %s\n  实得 %s", want, got)
	}
}

func TestModuleSM3MatchesLongInput(t *testing.T) {
	// 64 字节的 "abcd"×16：跨两个分组，检验填充与长度编码。
	input := strings.Repeat("abcd", 16)
	sum := ModuleSM3([]byte(input))
	got := hex.EncodeToString(sum[:])
	want := "debe9ff92275b8a138604889c18e5a4d6fdb70e5387e5765293dcba39c0c5732"
	if got != want {
		t.Fatalf("SM3(abcd×16) 与标准不符\n  期望 %s\n  实得 %s", want, got)
	}
}

// 宿主要能把 sm3 暴露给 JS 模块 —— 官方红果模块正是这么用的。
func TestModuleHostExposesSM3(t *testing.T) {
	directory := writeTestModule(t, `{"id":"sm3test","name":"SM3 测试","runtime":"js","api":1,"adult":false,"capabilities":["search"]}`, `
module.exports = {
  categories() { return []; },
  search(page, query) {
    const digest = host.hexEncode(host.sm3(host.utf8Encode("abc")));
    const md5 = host.hexEncode(host.md5(host.utf8Encode("abc")));
    const sha = host.hexEncode(host.sha256(host.utf8Encode("abc")));
    return { items: [{ id: host.dramaId(digest), title: digest + "|" + md5 + "|" + sha }], hasMore: false };
  },
};`)
	module, err := readModule(directory)
	if err != nil {
		t.Fatal(err)
	}
	p := module.provider(&moduleTestHost{state: map[string][]byte{}})
	searcher, ok := providerAs[Searcher](p)
	if !ok {
		t.Fatal("模块没有暴露 search 能力")
	}
	items, _, err := searcher.Search(t.Context(), 1, "红果")
	if err != nil || len(items) != 1 {
		t.Fatalf("search = %v, %v", items, err)
	}
	want := "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0|" +
		"900150983cd24fb0d6963f7d28e17f72|" +
		"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
	if items[0].Title != want {
		t.Fatalf("宿主里的摘要不对\n  期望 %s\n  实得 %s", want, items[0].Title)
	}
}
