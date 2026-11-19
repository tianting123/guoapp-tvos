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

// sourceGoHongguoEnabled：是否用本仓自己写的 Go 版红果。
//
// 红果有两套实现，ID 相同（都是 "hongguo"），只能二选一 —— 站源注册表按 ID 唯一，
// 官方 JS 模块安装时会发现与 Go 站源冲突而拒绝安装。
//
//   - Go 版（本仓写的）：可控性高，改协议不用等官方；但红果换代极快，
//     每次换代都要自己跟进（10-27、11-02、11-10、11-16 连续四次）。
//   - 官方 JS 模块：跟站方同步，官方跟进协议变更我们更新模块即可；
//     但要靠 JS 模块宿主（上游已具备，本仓补了 SM3）。
//
// ⭐ 默认用**官方 JS 模块**（理由见上）。要切回 Go 版，把下面这行改成 false
// 或在构建时加 `-tags=gohongguo`。
var sourceGoHongguoEnabled = false

// sourceEnabledInFlavor 之外的额外判断：红果这一项要看用哪套实现。
func sourceHongguoRegisteredByGo() bool {
	return sourceGoHongguoEnabled
}
