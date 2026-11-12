package sources

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"duanjuapp/native/core"
)

// 红果出品方片单：按出品方名搜多页，只保留 copyright 与之精确相等的剧
// （copyright 由 hongguoDramaFromAny 解析到 core.Drama.Producer），再用网页
// 详情补上线日期（搜索载荷没有日期字段），供界面按最新/最热排序。
const (
	producerMaxPages    = 6
	producerEnrichLimit = 40
)

// producerLookup 记录一次出品方检索的命中信息。
type producerLookup struct {
	producer string
	dramas   []core.Drama
}

// ProducerDramas 按出品方名检索该出品方的全部剧作。
func (p *hongguoProvider) ProducerDramas(ctx context.Context, producer string) ([]core.Drama, error) {
	producer = strings.TrimSpace(producer)
	if producer == "" {
		return nil, errors.New("出品方为空")
	}
	dramas, err := p.fetchProducerDramas(ctx, producer)
	if err != nil {
		return nil, err
	}
	return dramas, nil
}

// ProducerOf 返回某部剧的出品方名：详情与首页推荐载荷都没有 copyright，
// 只能按剧名走一次搜索、用剧 ID 精确命中取出品方。查不到返回空串。
func (p *hongguoProvider) ProducerOf(ctx context.Context, drama core.LibraryDrama) (string, error) {
	title := strings.TrimSpace(drama.Title)
	if title == "" {
		return "", nil
	}
	lookupCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	entry, err := p.searchHongguoDramas(lookupCtx, title)
	if err != nil {
		return "", nil
	}
	for _, item := range entry.Dramas {
		if item.ID == drama.ID {
			return strings.TrimSpace(item.Producer), nil
		}
	}
	return "", nil
}

// fetchProducerDramas 检索出品方片单，并补齐上线日期。
//
// 不能只走 tab 搜索接口：红果的 tab 搜索对长公司名（如「河北陶山影视传媒
// 有限公司」）几乎命不中，而联想接口能命中。因此这里复用上游完整的搜索
// 路径（tab 页 + 联想），再按 copyright 精确过滤出品方的剧。
func (p *hongguoProvider) fetchProducerDramas(ctx context.Context, producer string) ([]core.Drama, error) {
	seen := map[string]bool{}
	dramas := []core.Drama{}
	// 先取联想结果：联想按名称/出品方词匹配，长公司名主要靠它命中。
	if names, err := p.fetchHongguoSearchNames(ctx, producer); err == nil {
		for _, drama := range names {
			if strings.TrimSpace(drama.Producer) != producer {
				continue
			}
			if !seen[drama.ID] {
				seen[drama.ID] = true
				dramas = append(dramas, drama)
			}
		}
	}
	for page := 1; page <= producerMaxPages; page++ {
		items, hasMore, err := p.fetchProducerPage(ctx, producer, page)
		if err != nil {
			if page == 1 {
				if len(dramas) > 0 {
					break
				}
				return nil, err
			}
			break
		}
		for _, drama := range items {
			if !seen[drama.ID] {
				seen[drama.ID] = true
				dramas = append(dramas, drama)
			}
		}
		if !hasMore {
			break
		}
	}
	enrichCtx, enrichCancel := context.WithTimeout(ctx, 25*time.Second)
	p.enrichProducerDates(enrichCtx, dramas)
	enrichCancel()
	for i := range dramas {
		if dramas[i].Heat == "" {
			dramas[i].Heat = dramas[i].Views
		}
	}
	return dramas, nil
}

// fetchProducerPage 检索出品方的第 page 页，按 copyright 精确过滤。
func (p *hongguoProvider) fetchProducerPage(ctx context.Context, producer string, pageNum int) ([]core.Drama, bool, error) {
	client := p.client
	offset := strconv.Itoa((pageNum - 1) * hongguoSearchPageSize)
	query := url.Values{"query": {producer}, "offset": {offset}, "count": {strconv.Itoa(hongguoSearchPageSize)}, "tab_type": {hongguoSearchSeriesTab}}
	if pageNum > 1 {
		query.Set("passback", offset)
		client.mu.Lock()
		searchID := client.searchIDs[producer]
		client.mu.Unlock()
		if searchID != "" {
			query.Set("search_id", searchID)
		}
	}
	result, err := p.hongguoAppRequest(ctx, http.MethodGet, hongguoSearchTabPath, query, nil)
	if err != nil {
		return nil, false, err
	}
	var tab map[string]any
	for _, item := range anyList(result["search_tabs"]) {
		if candidate, _ := item.(map[string]any); core.MapString(candidate, "tab_type") == hongguoSearchSeriesTab {
			tab = candidate
		}
	}
	if tab == nil {
		return nil, false, errors.New("红果搜索未返回有效结果")
	}
	if searchID := core.MapString(tab, "search_id"); pageNum == 1 && searchID != "" {
		client.mu.Lock()
		if len(client.searchIDs) >= 64 {
			client.searchIDs = map[string]string{}
		}
		client.searchIDs[producer] = searchID
		client.mu.Unlock()
	}
	dramas := []core.Drama{}
	seen := map[string]bool{}
	for _, cell := range anyList(tab["data"]) {
		row, _ := cell.(map[string]any)
		for _, video := range anyList(row["video_data"]) {
			item, _ := video.(map[string]any)
			if strings.TrimSpace(core.MapString(item, "copyright")) != producer {
				continue
			}
			drama := hongguoDramaFromAny(map[string]any{"video_data": video}, "短剧")
			if drama.ID != "" && !seen[drama.ID] {
				seen[drama.ID] = true
				dramas = append(dramas, drama)
			}
		}
	}
	return dramas, tab["has_more"] == true, nil
}

// enrichProducerDates 用网页详情补上线日期（搜索载荷没有日期字段）。
func (p *hongguoProvider) enrichProducerDates(ctx context.Context, dramas []core.Drama) {
	indexes := []int{}
	for i := range dramas {
		if dramas[i].OnlineDate == "" && dramas[i].SourceID != "" {
			indexes = append(indexes, i)
		}
	}
	if len(indexes) > producerEnrichLimit {
		indexes = indexes[:producerEnrichLimit]
	}
	sem := make(chan struct{}, 4)
	var wg sync.WaitGroup
	for _, idx := range indexes {
		idx := idx
		wg.Add(1)
		go func() {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
				defer func() { <-sem }()
			case <-ctx.Done():
				return
			}
			itemCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
			defer cancel()
			body, err := p.text(itemCtx, hongguoBaseURL+"/detail?series_id="+url.QueryEscape(dramas[idx].SourceID), hongguoBaseURL+"/")
			if err != nil {
				return
			}
			page := routerLoaderMap(parseRouterData(body), "detail_page", "detail_")
			detail, _ := page["seriesDetail"].(map[string]any)
			if date := providerTimestampDate(core.MapString(detail, "first_visible_time")); date != "" {
				dramas[idx].OnlineDate = date
			}
		}()
	}
	wg.Wait()
}
