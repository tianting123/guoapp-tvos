# 未签名 tvOS IPA

| 文件 | 应用 | 版本 |
| --- | --- | --- |
| `zhenguojian-2.58-tvos-unsigned.ipa` | 真果鉴（全站源） | 2.58 / build 84 |
| `hongguojian-2.58-tvos-unsigned.ipa` | 火龙果短剧（单站源） | 2.58 / build 84 |

两个包都是 **未签名** 的 tvOS（arm64）IPA，装到 Apple TV 前需要用自己的开发者证书签名。
`*-unsigned` 里的 `unsigned` 就是提醒：不能直接双击安装。

## 版本说明

仓库源码已是 **2.59**（修正作者署名：B 站「芽芽ol」、微信公众号「芽芽打包酱」分开显示）。
这里的 IPA 仍是 **2.58**，因为打包机的沙箱策略拦截了 Xcode 解析 SwiftPM 依赖时对
`~/.swiftpm/security` 的清理，2.59 的二进制没能生成；2.58 的内容除署名外与 2.59 一致
（含播放黑屏自愈、WebDAV 地址修复）。

在不受该策略限制的本机终端里，进仓库根目录跑下面两条就能补齐 2.59 双包：

```bash
export PATH="$HOME/.local/toolchain/go/bin:$PATH"
python3 scripts/build_tvos.py --all-sources --skip-overlay --skip-resolve
python3 scripts/build_tvos.py --skip-overlay --skip-resolve
```

产物在 `dist/tvos/`，把两个 `*-2.59-tvos-unsigned.ipa` 复制到本目录替换即可。
构建脚本的 `--skip-overlay` / `--skip-resolve` 只用于 Go 核心与依赖没变动时跳过重复步骤。

## 从源码构建

```bash
git clone --recursive <本仓库地址>
cd guoapp-tvos
```

`upstream/` 是子模块（上游 Go 核心 `Xanerix/guoapp`），`fork/` 存放本仓对核心的本地改动，
构建脚本会把 `fork/` 覆盖到 `upstream/` 再编译，所以 `--recursive` 不能省。
