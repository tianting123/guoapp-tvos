package core

import (
	"context"
	"errors"
	"strings"
)

// producerHongguoSource 是红果的站源标识。core 本身不引用任何具体站源，
// 这里只是出品方能力的默认作用站源；实际是否可用由站源注册表判定。
const producerHongguoSource = "hongguo"

// 出品方能力的可选接口：站源实现它即可支持「按出品方浏览其剧作」。
// core 不内置任何具体站源逻辑，只做协议转发与鉴权。
type ProducerProvider interface {
	// ProducerDramas 按出品方名检索该出品方的全部剧作。
	ProducerDramas(ctx context.Context, producer string) ([]Drama, error)
	// ProducerOf 返回某部剧的出品方名；查不到时返回空串。
	ProducerOf(ctx context.Context, drama LibraryDrama) (string, error)
}

// errNoProducerProvider 表示当前站源没有出品方能力。
var errNoProducerProvider = errors.New("当前站源不支持出品方")

// nativeProducerProvider 取指定站源的出品方能力。
func (engine *nativeEngine) nativeProducerProvider(source string) (ProducerProvider, error) {
	source = canonicalProviderSource(source)
	if !nativeSourceAvailable(source) {
		return nil, errNativeBuildSource
	}
	provider, ok := engine.downloader.provider(source)
	if !ok {
		return nil, errNoProducerProvider
	}
	producer, ok := provider.(ProducerProvider)
	if !ok {
		return nil, errNoProducerProvider
	}
	return producer, nil
}

// nativeProducerDramas 处理 producerDramas 动作：按出品方名取其全部剧作。
func (engine *nativeEngine) nativeProducerDramas(ctx context.Context, producer string) (any, error) {
	producer = strings.TrimSpace(producer)
	if producer == "" {
		return nil, errors.New("出品方为空")
	}
	provider, err := engine.nativeProducerProvider(producerHongguoSource)
	if err != nil {
		return nil, err
	}
	dramas, err := provider.ProducerDramas(ctx, producer)
	if err != nil {
		return nil, err
	}
	items := make([]LibraryDrama, 0, len(dramas))
	for _, drama := range dramas {
		items = append(items, NativeNormalize(drama))
	}
	return map[string]any{"items": items}, nil
}

// nativeProducerWorks 处理 producerWorks 动作：先定出品方，再取其全部剧作。
func (engine *nativeEngine) nativeProducerWorks(ctx context.Context, drama LibraryDrama) (any, error) {
	source, _, valid := SplitProviderDramaID(drama.ID)
	if !valid || source != producerHongguoSource {
		return nil, errors.New("仅红果剧集有出品方信息")
	}
	provider, err := engine.nativeProducerProvider(source)
	if err != nil {
		return nil, err
	}
	name := strings.TrimSpace(drama.Producer)
	if name == "" {
		name, err = provider.ProducerOf(ctx, drama)
		if err != nil {
			return nil, err
		}
		name = strings.TrimSpace(name)
	}
	if name == "" {
		return map[string]any{"producer": "", "items": []LibraryDrama{}}, nil
	}
	dramas, err := provider.ProducerDramas(ctx, name)
	if err != nil {
		return nil, err
	}
	items := make([]LibraryDrama, 0, len(dramas))
	for _, item := range dramas {
		items = append(items, NativeNormalize(item))
	}
	return map[string]any{"producer": name, "items": items}, nil
}
