package core

import (
	"testing"
)

// 内置红果 JS 模块要与 Go 站源共存 —— 站源注册表按 ID 唯一，
// 官方模块安装时若发现同 ID 的 Go 站源会拒绝安装（moduleConflict）。
// 所以本仓默认**不用** Go 版红果，让官方 JS 模块接管。
//
// 这个测试守住这条约定：内置模块在位，且 Go 版红果没有注册。

func TestBundledHongguoModuleIsPresent(t *testing.T) {
	modules, failures := readBundledModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	module, ok := modules["hongguo"]
	if !ok {
		t.Fatal("内置模块里没有 hongguo")
	}
	if module.manifest.Name != "红果" {
		t.Fatalf("内置红果模块的名字不对：%q", module.manifest.Name)
	}
	if len(module.code) == 0 {
		t.Fatal("内置红果模块的代码是空的")
	}
	// 模块要能访问的域名：取址与设备注册都在里面。
	for _, host := range []string{"api5-normal-sinfonlinea.fqnovel.com", "log.snssdk.com"} {
		found := false
		for _, declared := range module.manifest.Hosts {
			if declared == host || declared == "*."+host || declared == "*" {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("内置红果模块没有声明可访问 %s（hosts=%v）", host, module.manifest.Hosts)
		}
	}
}

// Go 版红果默认不注册 —— 否则官方模块会被 moduleConflict 拦下。
// 这里从站源注册表反查：注册表里不该有 Go 版红果留下的 Go 站源。
func TestGoHongguoIsNotRegisteredByDefault(t *testing.T) {
	if owner, taken := registeredSource("hongguo"); taken {
		t.Fatalf("hongguo 已被 Go 站源 %q 注册，官方 JS 模块会被 moduleConflict 拦下", owner)
	}
}
