package sources

// 红果站源包的「编译期版本」机制。
//
// 上游在 11-14 的 cf0dc7a 把 flavor 机制整个删了（核心不再内置站源，
// 改成运行时安装 JS 模块；`core.RegisterFlavor` 也没了）。
// 但我们仍有两个包：火龙果短剧（仅红果）与真果鉴（全部站源）——
// 两个包要能同时装在同一台 Apple TV 上（包名不同），所以编译期就要区分。
//
// 这里用 build tag 实现，与上游 8e277f8 起的做法一致（`-tags=hongguojian`
// 或 `-tags=zhenguojian`）：
//   - flavor_sources_all.go  → 有 zhenguojian tag 时启用全部站源；
//   - flavor_sources_red.go  → 只有红果（默认，无 tag 也走这份）。
//
// 站源注册前用 [sourceEnabledInFlavor] 问一句：不属于当前 flavor 就不注册。
// 这样不用给每个站源文件拆出通用工具，改动面最小。

// sourceFlavorAll：当前编译是否包含全部站源。
var sourceFlavorAll = false

// sourceFlavorRed：当前编译包含的站源 id（仅红果版有效）。
var sourceFlavorRed = map[string]bool{
	"hongguo": true,
}

// sourceEnabledInFlavor：这个站源在当前编译的 flavor 里是否启用。
func sourceEnabledInFlavor(id string) bool {
	if sourceFlavorAll {
		return true
	}
	return sourceFlavorRed[id]
}
