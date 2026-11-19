package core

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 用官方红果站源模块（guoapp-modules/hongguo，GPL-3.0）跑一遍真实的取址链路。
//
// 这是「跟上游转成 JS 模块架构」的关键验证：
// 官方模块用 v5 播放签名，上游的 JS 宿主原本缺 SM3，
// 所以 core 里补了 ModuleSM3 并暴露为 host.sm3。
//
// ⭐ 这个测试要打真实网络，默认不跑：
//
//	HONGGUO_LIVE=1 go test -run TestOfficialHongguoModuleLive -v ./core/
//
// 模块来源默认用**打进包的 embed 内置模块**（即真正交付的那份）；
// 也可用 HONGGUO_MODULE_DIR 指向外部目录覆盖（调试用）。
// videoID 可以用环境变量 HONGGUO_VIDEO_ID 覆盖。
func TestOfficialHongguoModuleLive(t *testing.T) {
	if os.Getenv("HONGGUO_LIVE") != "1" {
		t.Skip("设置 HONGGUO_LIVE=1 后才会跑（要打真实网络）")
	}
	var module *jsModule
	if directory := os.Getenv("HONGGUO_MODULE_DIR"); directory != "" {
		loaded, err := readModule(directory)
		if err != nil {
			t.Fatal(err)
		}
		module = loaded
		t.Logf("用外部目录的模块：%s", directory)
	} else {
		bundled, failures := readBundledModules()
		if len(failures) > 0 {
			t.Fatalf("读取内置模块失败：%v", failures)
		}
		item, ok := bundled["hongguo"]
		if !ok {
			t.Fatal("内置模块里没有 hongguo")
		}
		// 内置模块存的是原始清单与代码，走和外部模块同一条 parseModule 编译路径。
		loaded, err := parseModule(item.raw, item.code)
		if err != nil {
			t.Fatalf("编译内置红果模块失败：%v", err)
		}
		module = loaded
		t.Log("用打进包的 embed 内置模块")
	}
	videoID := os.Getenv("HONGGUO_VIDEO_ID")
	if videoID == "" {
		videoID = "7704532501426867224"
	}
	// Downloader 零值构造没有 HTTP client，取网络时会 nil 解引用 ——
	// 这里按上游 newNativeEngine 的做法配一个（真实运行时核心会自己配好）。
	downloader := &Downloader{
		cfg: Config{dataDir: t.TempDir()},
		providerHosts: map[string]string{},
		proxyRouter:   &proxyRouter{},
		limiter:       newRequestLimiter(3, 0),
		diagnostics:   newDiagnosticLog(t.TempDir()),
	}
	downloader.proxyRouter.record = downloader.recordDiagnostic
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.MaxIdleConnsPerHost = 8
	transport.ResponseHeaderTimeout = 20 * time.Second
	downloader.client = &http.Client{Transport: transport, Timeout: 45 * time.Second}
	host := &liveModuleHost{Host: downloader}
	p := module.provider(host)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	// 官方模块的章节地址用 hongguo-cenc:// 前缀装视频 id，
	// dramaId 是「站源:剧 id」格式（模块要从中拆出剧 id）。
	task := Task{
		DramaID: "hongguo:" + videoID,
		Chapter: Chapter{VideoURL: "hongguo-cenc://" + videoID},
	}
	media, err := p.ResolveMedia(ctx, task)
	if err != nil {
		t.Fatalf("官方模块取址失败：%v（请求数 %d）", err, len(host.requests))
	}
	out, _ := json.Marshal(map[string]any{
		"url": media.URL, "quality": media.Quality, "cenc": len(media.CENCKey),
	})
	t.Logf("官方模块取址成功：%s", out)
}

// liveModuleHost：把宿主请求发到真实网络。
type liveModuleHost struct {
	Host
	requests []HTTPRequest
}

func (host *liveModuleHost) Fetch(ctx context.Context, request HTTPRequest) (HTTPResponse, error) {
	host.requests = append(host.requests, request)
	return host.Host.Fetch(ctx, request)
}

func (host *liveModuleHost) LoadState(name string) ([]byte, error) {
	path := filepath.Join(os.TempDir(), "hongguo-module-state", name)
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	return data, err
}

func (host *liveModuleHost) SaveState(name string, data []byte) error {
	directory := filepath.Join(os.TempDir(), "hongguo-module-state")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(directory, name), data, 0o600)
}
