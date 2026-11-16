package sources

import (
	"context"
	"errors"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"duanjuapp/native/core"
)

// 官方在 pages.dev 发布页的 publish.js 里维护当前镜像（urls = 根域名，
// subdomains = 子域名前缀），HGhubX 等客户端用的是同一份发布数据。
// 静态域名池过期时靠它自愈：拉取成功缓存 30 分钟，失败 5 分钟后重试；
// 发现结果只追加候选，不替换主线路，拉不到时行为与原来一致。
var huangguoPublishScripts = []string{
	"https://huangguoai.pages.dev/publish.js",
	"https://huang-guo.pages.dev/publish.js",
}

const (
	huangguoDiscoverSuccessTTL = 30 * time.Minute
	huangguoDiscoverRetryTTL   = 5 * time.Minute
	huangguoDiscoverMaxHosts   = 16
	huangguoPublishMaxBytes    = 512 * 1024
)

var (
	huangguoDiscoverMu      sync.Mutex
	huangguoDiscovered      []string
	huangguoDiscoverNext    time.Time
	huangguoDiscoverRunning bool

	reHuangguoPublishArray  = regexp.MustCompile(`(?s)\b(urls|subdomains)\s*=\s*\[([^\]]*)\]`)
	reHuangguoPublishQuoted = regexp.MustCompile(`'([^']+)'|"([^"]+)"`)
)

// 读已发现的镜像；没有就顺手在后台开一次预取，调用方不等它。
//
// 不能持锁发请求：限流器在放行前会按 URL 反查站源，
// 经 isHuangguoAIMirrorHost 回到 huangguoDiscoveredHost 抢同一把锁。
// 所以预取在后台 goroutine 里跑，锁只用来读缓存。
func (p *huangguoAIProvider) huangguoDiscoveredMirrors() []string {
	huangguoDiscoverMu.Lock()
	defer huangguoDiscoverMu.Unlock()
	if !time.Now().Before(huangguoDiscoverNext) && !huangguoDiscoverRunning {
		huangguoDiscoverRunning = true
		go p.refreshHuangguoMirrors()
	}
	return huangguoDiscovered
}

// 后台拉发布页：成功缓存 30 分钟，失败 5 分钟后再试。
// 不阻塞站源请求 —— 第一次调用时静态域名池照常先用，动态发现的镜像下一轮才出现。
func (p *huangguoAIProvider) refreshHuangguoMirrors() {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	hosts := p.discoverHuangguoMirrors(ctx)
	huangguoDiscoverMu.Lock()
	defer huangguoDiscoverMu.Unlock()
	huangguoDiscoverRunning = false
	if len(hosts) > 0 {
		huangguoDiscovered = hosts
		huangguoDiscoverNext = time.Now().Add(huangguoDiscoverSuccessTTL)
	} else {
		// 拉不到就不重试太勤：5 分钟后再试，期间沿用上一次的发现结果。
		huangguoDiscoverNext = time.Now().Add(huangguoDiscoverRetryTTL)
	}
}

func (p *huangguoAIProvider) discoverHuangguoMirrors(ctx context.Context) []string {
	for _, script := range huangguoPublishScripts {
		if ctx.Err() != nil {
			return nil
		}
		body, err := p.fetchHuangguoPublish(ctx, script)
		if err != nil {
			continue
		}
		if hosts := parseHuangguoPublish(body); len(hosts) > 0 {
			return hosts
		}
	}
	return nil
}

func (p *huangguoAIProvider) fetchHuangguoPublish(ctx context.Context, rawURL string) (string, error) {
	requestCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	response, err := p.host.FetchText(requestCtx, core.TextRequest{
		URL:       rawURL,
		Referer:   rawURL,
		UserAgent: core.UserAgent,
	})
	if err != nil {
		return "", err
	}
	if len(response.Body) > huangguoPublishMaxBytes {
		return "", errors.New("黄果发布页返回的数据过大")
	}
	return response.Body, nil
}

func parseHuangguoPublish(js string) []string {
	var domains, subs []string
	for _, match := range reHuangguoPublishArray.FindAllStringSubmatch(js, -1) {
		var values []string
		for _, quoted := range reHuangguoPublishQuoted.FindAllStringSubmatch(match[2], -1) {
			value := quoted[1]
			if value == "" {
				value = quoted[2]
			}
			values = append(values, value)
		}
		switch match[1] {
		case "urls":
			for _, value := range values {
				value = strings.TrimSuffix(strings.TrimSpace(strings.ToLower(value)), "/")
				value = strings.TrimPrefix(strings.TrimPrefix(value, "https://"), "http://")
				if validHuangguoDNSName(value) && !strings.Contains(value, "..") {
					domains = append(domains, value)
				}
			}
		case "subdomains":
			for _, value := range values {
				value = strings.TrimSpace(strings.ToLower(value))
				if validHuangguoDNSLabel(value) {
					subs = append(subs, value)
				}
			}
		}
	}
	if len(domains) == 0 {
		return nil
	}
	var hosts []string
	seen := map[string]bool{}
	add := func(host string) {
		if !seen[host] && len(hosts) < huangguoDiscoverMaxHosts {
			seen[host] = true
			hosts = append(hosts, "https://"+host)
		}
	}
	if len(subs) == 0 {
		for _, domain := range domains {
			add(domain)
		}
		return hosts
	}
	for i := 0; i < len(subs)*len(domains) && len(hosts) < huangguoDiscoverMaxHosts; i++ {
		add(subs[i/len(domains)] + "." + domains[i%len(domains)])
	}
	return hosts
}

func huangguoDiscoveredHost(host string) bool {
	huangguoDiscoverMu.Lock()
	discovered := huangguoDiscovered
	huangguoDiscoverMu.Unlock()
	for _, origin := range discovered {
		parsed, err := url.Parse(origin)
		if err != nil {
			continue
		}
		known := strings.ToLower(parsed.Hostname())
		if host == known {
			return true
		}
		labels := strings.Split(known, ".")
		if len(labels) >= 2 && strings.HasSuffix(host, "."+strings.Join(labels[len(labels)-2:], ".")) {
			return true
		}
	}
	return false
}

func validHuangguoDNSLabel(value string) bool {
	if value == "" || len(value) > 63 {
		return false
	}
	for i := 0; i < len(value); i++ {
		c := value[i]
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return value[0] != '-' && value[len(value)-1] != '-'
}

func validHuangguoDNSName(value string) bool {
	if value == "" || len(value) > 253 || !strings.Contains(value, ".") {
		return false
	}
	for _, label := range strings.Split(value, ".") {
		if !validHuangguoDNSLabel(label) {
			return false
		}
	}
	return true
}
