from dataclasses import dataclass


@dataclass(frozen=True)
class BuildVariant:
    all_sources: bool = False

    @property
    def slug(self):
        return 'zhenguojian' if self.all_sources else 'hongguojian'

    @property
    def display_name(self):
        # 主屏显示名，经 Xcode 构建设置 GUOAPP_DISPLAY_NAME 写入 Info.plist（签名前生效）。
        return '真果鉴' if self.all_sources else '火龙果短剧'

    @property
    def arguments(self):
        return ['--all-sources'] if self.all_sources else []

    @property
    def flutter_arguments(self):
        return ['--dart-define=APP_FLAVOR=' + self.slug]

    @property
    def go_arguments(self):
        # 上游自 8e277f8 起把版本开关从 linker 变量 buildAllSources 改成
        # Go build tag（hongguojian / zhenguojian），站源包里的 flavor_*.go
        # 按 tag 决定注册哪些站源。旧的 -X .../core.buildAllSources=true
        # 在新上游已无对应变量，传了也不生效。
        return ['-tags=' + self.slug]

    @property
    def linker_flags(self):
        return '-s -w'


def add_variant_argument(parser):
    parser.add_argument('--all-sources', action='store_true',
                        help='构建包含全部站源的真果鉴；默认构建仅红果的火龙果短剧')
