//go:build gohongguo

package sources

// 构建时加 -tags=gohongguo 可切回本仓自己写的 Go 版红果。
//
// 用途：红果换代极快，官方 JS 模块若某次没跟上，可以先用 Go 版顶上，
// 不用等官方发新版。默认是官方 JS 模块（见 flavor_sources.go）。
//
// 注意：Go 版红果与内置 JS 模块 ID 相同（都是 hongguo），二者只能有一个。
// 启用本 tag 后 Go 版会先注册，内置 JS 模块会因 moduleConflict 自行跳过。
func init() {
	sourceGoHongguoEnabled = true
}
