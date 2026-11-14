# 红果 tvOS（Apple TV）

火龙果短剧 / 真果鉴的 Apple TV 原生应用：SwiftUI 界面 + Go 核心 + MPVKit（libmpv）播放。

![Description](Screenshot.jpg)

> 与上游的关系：本仓是独立仓库，是上游 [Xanerix/guoapp](https://github.com/Xanerix/guoapp)
> 的 tvOS 版（独立 SwiftUI 应用），与主仓库只共享 Go 核心与 `DuanjuRequest` JSON 协议；
> 上游维护者建议拆独立仓（见 [Issue #13](https://github.com/Xanerix/guoapp/issues/13)），
> 本仓即按该建议拆出。上游的 Flutter 应用仍在原仓库维护。
> 完整继承关系、改了什么、解决了什么问题，见下文
> [「Fork 了哪些上游项目，解决了什么问题」](#fork-了哪些上游项目解决了什么问题)。

## 功能

推荐（整屏 hero 播放推荐流）、浏览（剧场）、搜索、详情、分段选集、追剧（继续观看 + 我的追剧）、观看进度、同名剧分部归组（系列）、弹幕、播完自动连播下一集、红果榜单。
> - 清晰度在设置中调整，下次打开剧集生效；
> - 播放时点按（暂停）或按 ↑ ↓ 调出播放控件：进度条与剩余时间、倍速、选集；
>   ← → 快退 / 快进 10 秒；Menu 先收起控件，再按一次退出播放。倍速会记住。
> - 任意海报或「继续观看」卡片上按遥控器「播放/暂停」键：直接播放（有记录则续播到那一集那一秒）。
> - 「继续观看」卡片长按：查看详情 / 从观看记录中移除；「我的」里可清除全部观看记录（追剧不受影响）。
> - 同一部剧的第 N 部 / 季：搜索结果合成一张卡片，详情页下方「本系列」列出各部，看完可直接「观看下一部」。
> - 「推荐」（默认页）：整屏播放推荐流里的剧（有声），左侧信息栏 + 底部「接下来」；在「接下来」的海报上停留 1 秒
>   先预览，按下才切换；播放键（焦点在标签栏时也行）或「暂停 / 继续」按钮暂停；「全屏观看」从当前这集当前位置接着播。
>   在推荐页里要连续看满 30 秒才记入观看记录；离开本页即停止，回来按观看记录重新起播。
>   推荐页不拦屏保：按电视设置的时间出现屏保，hero 随之暂停。
> - 「搜索」：tvOS 原生搜索界面，键盘在上、结果在下，停止输入 0.6 秒即出结果，联想词选中即搜；
>   还没输入时显示「大家都在看」（推荐流前 14 部），结果上方「找到 N 部短剧」。
> - 加载时各页显示形状相同的骨架（扫光，开了「减弱动态效果」时静止）；出错时「出了点问题」+ 重试，
>   网络问题提示「网络连接失败，请检查网络后重试」。
> - 海报焦点停住时预先加载后面几张封面与这部剧的详情，进详情页几乎即开；封面按显示尺寸缩小解码，内存有上限。
> - 看完的剧用播放键或在推荐页里播，从第 1 集开头（与详情页「重新观看」一致）。
> - 启动即有内容：推荐页先显示核心存着的推荐（hero 马上开始），新推荐在后台取回后接到正在播的这部后面；
>   剧场先显示上次的榜单第 1 页（或核心缓存的片库），「大家都在看」同样立刻显示。
> - 追剧更新：后台检查追的剧（启动后与回到前台时，每部 6 小时最多一次），有新集时海报与继续观看卡片上显示
>   「更新至 N 集」，打开或播放后消失；「我的」里可「检查追剧更新」。
> - 详情页补全评分、上线月份与热度；弹幕恢复（全屏播放，「我的」里开关）。
> - 「我的」：应用与核心版本、观看统计（在追 / 看过的剧 / 看完的集 / 累计观看）、进入推荐页自动播放开关、已用空间。
> - 与核心的请求分两条通道：播放类一个一个来，其余最多 4 个并行（封面更快）；搜索、联想词连续输入时旧的请求被取消。
> - 「剧场」：顶部「今日主推」（立即观看 / 详情），海报右上角显示总集数；换分类时网格变暗并在分类行下转圈。
> - 看完且没有下一部的剧，详情页主按钮为「重新观看」（从第 1 集开头）。
> - **远端存储**：「设置 › 存储与关于」可把追剧与观看进度写入 **SMB 共享**（自研 SMB2
>   客户端）或 **WebDAV**，同步频率可选不自动 / 3 / 10 / 30 / 60 / 300 秒，
>   另有「立即备份 / 立即恢复」。默认仍以本地为主，远端读取失败自动回退本地。
> - **站源登录**：红果支持设备注册后登录（「设置 › 站源账号」），青空支持账号登录与
>   滑块验证（遥控器方向键完成轨迹）；播放失败提示含「登录」时可直接跳到登录页。

**未移植**：下载、局域网互联。

两个版本功能相同，区别只在站源范围：

- 火龙果短剧（hongguojian）：仅红果站源
- 真果鉴（zhenguojian）：全部站源

## Fork 了哪些上游项目，解决了什么问题

本仓不是凭空写的应用，而是**基于上游的 Go 核心与协议，重新实现了一层 tvOS 界面**。
下面按「继承了什么 / 改了什么 / 解决什么问题」逐条说明。

### 1. `Xanerix/guoapp` —— 上游 Go 核心（以 submodule 继承，不改上游仓库）

| | |
| --- | --- |
| **仓库** | [Xanerix/guoapp](https://github.com/Xanerix/guoapp)（Dart + Go，GPL-3.0，1.5k star）|
| **继承方式** | `upstream/` 是 git submodule，**不 fork、不改上游仓库**，只跟踪它的 commit 指针 |
| **拿到的** | `native/` 下的 Go 核心：站源调度、榜单与推荐、搜索、详情、播放地址与 CENC 解密密钥、`DuanjuRequest` JSON 协议 |

**解决的问题**：站源解析、签名算法、播放解密这些逻辑复杂且随站源方频繁变动，
重写一遍成本极高、而且会立刻过时。本仓直接复用上游维护的核心，
**只在 UI 层做 tvOS 原生化**，上游修 bug 或加站源时本仓可以跟着升级。

**我们自己的改动**（不改上游仓库，而是用 `fork/` 覆盖层在构建时叠加）：

- `fork/patches/`（3 个补丁，对上游 core 的**最小**改动）：
  - `models.go`：`Drama` 增加 `Producer`（出品方）字段。
  - `app_runtime.go`：`LibraryDrama` 增加 `Producer` 字段、归一化时透传，
    `nativeDispatch` 增加 `producerDramas` / `producerWorks` 两个动作。
  - `app_catalog_cache.go`：合并新旧片单时保留 `Producer`（缓存不回退出品方信息）。
  - 设计上 **core 不内置任何具体站源逻辑** —— 出品方能力通过可选接口
    `ProducerProvider` 由站源实现，core 只做协议转发与鉴权。
- `fork/core/producer_core.go`（新增到 core 的文件）：`ProducerProvider` 接口与
  `nativeProducerProvider` / `nativeProducerDramas` / `nativeProducerWorks` 的实现，
  是上面两个动作的桥接。
- `fork/sources/`（**54 个 Go 文件**，构建时整体覆盖上游 `native/sources/`）：
  - 取自上游 `62fb9d4` 公开可见的站源包，保底可用；
  - **解决的关键问题**：上游已把 15 个官方站源搬进**私有仓库**，公开仓库只剩
    不联网的示例站源 —— 直接克隆上游会得到一个**没有任何可用站源**的空壳。
    自带站源包后构建可复现，也不依赖上游的私有仓库是否开放。
  - 在此基础上扩展：`provider_hongguo_device.go`（红果**设备注册**，
    调 `log.snssdk.com` 换 device_id / install_id，拿不到就播放失败）、
    `provider_hongguo_app.go`、`provider_hongguo_producer.go`（**出品方片单**：
    按 `copyright` 精确过滤并用网页详情补上线日期）等。
- `fork/sources/flavor_hongguojian.go` / `flavor_zhenguojian.go`：
  按 build tag 注册不同站源集合，实现「火龙果短剧（仅红果）/ 真果鉴（全站源）」两个版本。

**构建时如何叠加**：`scripts/build_tvos.py` 先跑 `scripts/apply_fork_overlay.py`，
把补丁 `git apply` 到 submodule 工作区、把 `fork/core/` 与 `fork/sources/` 拷进去。
**补丁打不上构建直接失败**，不会带着半成品出包。不要直接改 `upstream/` 里的文件。

### 2. `MPVKit` —— 播放内核（libmpv），依赖而非 fork

- **仓库**：[mpvkit/MPVKit](https://github.com/mpvkit/MPVKit)，SPM 依赖，
  版本**严格锁定 `exactVersion 1.1.0-n9.0.2`**（`Package.resolved` 同步锁死），
  构建带 `-onlyUsePackageVersionsFromResolvedFile`，不随上游自动升级。
- **解决的问题**：红果源视频是 **CENC 加密**，密钥需传给解码器，
  而 **AVPlayer 没有传原始密钥的接口** —— 用 AVPlayer 根本放不了红果源。
  改用 libmpv 后，密钥经 FFmpeg demuxer 选项直传 libavformat。
- 内置版本：mpv v0.41.0、FFmpeg n9.0.2、libplacebo v7.360.1、MoltenVK v1.4.2。
- 许可证：MPVKit 本身 **LGPL-3.0**，其内置 libmpv 来自 mpv（GPL-2.0-or-later）。
  分发前请以 MPVKit 仓库的 LICENSE 与对应 Release 说明为准。

### 3. `mpv` 本身 —— 通过 MPVKit 间接使用，不直接 fork

- **上游**：[mpv/mpv](https://github.com/mpv/mpv)（GPL-2.0-or-later）本身**没有官方 tvOS 支持**。
- **我们不直接引入 mpv**，而是通过 MPVKit 使用它 —— MPVKit 1.1.0-n9.0.2 已提供
  tvOS 平台构建（含 MoltenVK 图形后端、FFmpeg n9.0.2），本仓不需要自行把 mpv 移植到 tvOS。
- **许可证区分**：MPVKit 自身是 **LGPL-3.0**，但它内置的 libmpv 来自 mpv（**GPL-2.0-or-later**），
  因此整体分发仍受 GPL 条款约束。
- **补丁归属**：MPVKit 上游自己给 libmpv 打了 3 个补丁（MoltenVK 上下文、tvOS 的
  AVFoundation 音频输出等），在本仓的 `fork/` 里**没有**任何 libmpv 补丁 ——
  本仓对 mpv 只是通过 FFI（`DuanjuRequest` / `DuanjuFree`）调用，未改其源码。

### 4. 上游的 Flutter 应用 —— **没有** fork

上游主仓库维护的是 Flutter 客户端。本仓按上游维护者在
[Issue #13](https://github.com/Xanerix/guoapp/issues/13) 的建议**拆成独立仓**，
SwiftUI 界面、播放逻辑、缓存与设置全部是本仓自己的实现，只共享 Go 核心与协议。

### 同步上游核心

GitHub Actions 会**每天自动同步**（`.github/workflows/sync-upstream.yml`，
UTC 03:17 / 北京 11:17，也可手动触发）：

1. `git submodule update --remote -- upstream` 把核心指针更新到上游 `main` 最新；
2. **预检**（Ubuntu 上跑，便宜）：① `fork/` 补丁在新版上游上还能不能合入；
   ② Go 核心能否 `go build` + `go test` 通过。**任何一项不过就不推 main**，
   GitHub 发失败通知等人工处理 —— 避免出现「补丁打不上却把 main 写坏」；
3. 有更新才动：自动递增 `VERSION`、在 `CHANGELOG.md` 补一节、同步
   `project.pbxproj` 的 `MARKETING_VERSION`，然后推送 main；
4. 推送后触发 `build.yml`（在 **macOS** runner 上用 Xcode 真机编译双 flavor IPA
   并发布 Release）。

无上游更新时不做任何事。

手动同步（不依赖 CI）：

```sh
cd upstream
git fetch origin
git checkout <上游新 commit>   # 如只想跟最新 main：git checkout origin/main
cd ..
git add upstream
git commit -m "同步上游核心到 <commit>"
```

同步后跑一次 `python3 scripts/build_tvos.py`（或跑 CI）确认通过。

## 存储：本地为主，可选 SMB / WebDAV 远端

tvOS 沙盒限制：真机上只有 Caches 与 tmp 可写，核心数据、追剧与观看进度默认存
Caches。**系统在存储不足时可能清理 Caches**，追剧与进度可能丢失。

设置页「存储与关于」可配置远端存储，把状态 JSON 写出去，应用每次启动再拉回来：

- **SMB 共享**（主要方式）：自研 SMB2 客户端（`Core/SMB2Protocol.swift`、
  `SMB2Client.swift`），支持 NTLMv2 认证（`NTLM.swift` + `Hashing.swift`，
  含 MD4/MD5/HMAC-MD5）、读写、覆盖写时截断旧尾部。
- **WebDAV**（备份方式）：Basic / Digest 认证，支持 PROPFIND、MKCOL、PUT、GET。
- **同步频率**：不自动同步 / 每 3 / 10 / 30 / 60 / 300 秒；观看进度约每 5 秒落一次
  本地盘并重置远端防抖计时，远端任务等所选间隔后写入。「立即备份 / 立即恢复」手动触发。
- 未配置远端时行为与纯本地一致；远端读取失败会回退到本地副本。

## 构建

需要 macOS + 完整 Xcode。首次克隆须带子模块（否则 `upstream/` 为空，构建会失败）：

```sh
git clone --recurse-submodules https://github.com/lukaschan/guoapp-tvos.git
# 已克隆过的仓库：git submodule update --init --recursive
python3 scripts/build_tvos.py [--all-sources]
```

- 默认构建火龙果短剧；`--all-sources` 构建真果鉴。
- 产物在 `dist/tvos/`，为**未签名** IPA，需在 Mac 上用 Xcode 签名后安装到 Apple TV。
- CI（GitHub Actions，手动触发）构建两个版本并发布 Release，tag 形如 `tvos-v2.41`。

版本号：根目录 `VERSION`（如 `2.41`）是唯一来源：构建脚本把 Xcode 工程的
`MARKETING_VERSION` 覆盖为它，并用它命名 IPA；同步工作流升版本时会一并改工程里的值。

### 安装到 Apple TV

方法一（推荐）：
部署[atvloadly](https://github.com/bitxeno/atvloadly)，通过atvloadly安装。

方法二：
需要在 Xcode › Settings › Accounts 登录 Apple ID（免费账号即可），并把 Apple TV 与本机配对
（电视上打开 设置 › 遥控器与设备 › 遥控器 App 与设备，再在 Xcode › Window › Devices and
Simulators 里配对）。然后：

```sh
python3 scripts/deploy_tvos.py --team <Team ID> --bundle-id <自己的唯一包名> --device <Apple TV 名称> --save
# 之后（包括免费账号描述文件 7 天过期后续签）只需：
python3 scripts/deploy_tvos.py [--all-sources]
```

- 脚本编译 Go 核心 → Xcode 自动签名构建 → `devicectl` 安装并启动。
- 工程默认包名 `com.duanju.guoapp.tv` 已被其他开发者注册，必须用自己的唯一包名；
  `--save` 把参数存到 `tvos-deploy.local.json`（已 gitignore），也可用环境变量
  `GUOAPP_TEAM_ID` / `GUOAPP_BUNDLE_ID` / `GUOAPP_TV_DEVICE`。
- 真果鉴（`--all-sources`）包名自动加 `.all`，两个版本可同时安装。

## 目录结构

| 目录 / 文件 | 说明 |
| --- | --- |
| `tvos/GuoAppTV/GuoAppTV/Core/` | 应用核心：`Client`（Go 协议）、`Store`（状态与同步）、`Models`、`StorageBackend` / `SMB2Client` / `WebDAVStore`（远端存储）、`NTLM` / `Hashing`（认证）、`SourceAccount`（站源账号）、`Logic/`（28 个业务逻辑模块） |
| `tvos/GuoAppTV/GuoAppTV/Views/` | 界面：首页 / 搜索 / 详情 / 剧场 / 我的、播放器（`PlayerView` + `PlayerController` + `PlaybackSession` + `PlayerControlsView`）、`StorageSettingsView`、`SourceAccountView`、`SliderCaptchaView` |
| `tvos/LogicTests/` | 逻辑层单元测试（28 个文件） |
| `upstream/` | 上游仓库 git submodule，Go 核心在 `upstream/native/`（见上文「Fork 了哪些上游项目」） |
| `fork/sources/` | 本仓自带的站源包（覆盖上游 `native/sources/`，54 个文件），含红果出品方与设备注册实现 |
| `fork/patches/` | 对上游 core 的最小补丁（`Producer` 字段与两个 action） |
| `fork/core/` | 新增到上游 core 的文件（出品方能力桥接） |
| `scripts/build_tvos.py` | 构建脚本：先编 Go 核心为 xcframework，再用 xcodebuild 出包 |
| `scripts/apply_fork_overlay.py` | 把 `fork/` 的改动合入 submodule 工作区（幂等） |
| `scripts/deploy_tvos.py` | 签名构建并安装、启动到已配对的 Apple TV |
| `.github/workflows/build.yml` | CI：构建两个版本并发布 Release |
| `.github/workflows/sync-upstream.yml` | 每日自动同步上游核心（预检通过才推 main） |
| `VERSION` | 版本号 |
| `CHANGELOG.md` | 更新日志 |

## 上架说明

聚合第三方源站的应用上架 App Store 有内容合规风险，建议侧载或 TestFlight。
