//go:build !zhenguojian

package sources

// 火龙果短剧版（默认，无 tag）：只包含红果。
// sourceFlavorAll 默认就是 false，这里只把名单写清楚。
func init() {
	sourceFlavorAll = false
}
