#!/usr/bin/env python3
"""把本仓对上游核心的改动覆盖到 submodule 工作区。

构建前必跑（scripts/build_tvos.py 的 build_core 会自动调它）。
幂等，可反复跑：

1. 先把上次补丁改过的文件还原到 submodule 指针版本；
2. 删掉上次拷入的 fork 新增文件；
3. 重新拷入 fork/core/*.go；
4. 按文件名顺序打上 fork/patches/*.patch；
5. 用 fork/sources/ 覆盖上游的 native/sources/（站源包）；
6. 生成 native/go.work 与 native/bridge/sources_gen.go 接入站源包。

只动 fork 清单里的文件，不碰 submodule 其他内容。补丁打不上时直接报错
退出，绝不带着半合入的核心继续构建——这时需要人工把该补丁重排到新版
上游上（改 fork/patches 里对应的 .patch 文件），再重跑。

注意：跑完后 `git status` 会显示 upstream/ 有修改，这是正常的构建态，
不要在 upstream/ 里提交；下次构建会先还原再重打。

上游架构说明（2026-11-12 起）：上游已把 15 个官方站源搬进独立 Go 包
native/sources，并移入私有仓库。本仓改为自带 fork/sources/ 站源包
（取自上游 62fb9d4 公开可见的 native/sources/），红果出品方功能在这个
站源包里实现；core 只保留协议与承载字段的最小改动。
"""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
upstream = root / 'upstream'
core = upstream / 'native' / 'core'
native = upstream / 'native'
sources = native / 'sources'
fork_dir = root / 'fork'
fork_sources = fork_dir / 'sources'


def run(args, **kwargs):
    subprocess.run(args, check=True, **kwargs)


def main():
    if not core.is_dir():
        raise SystemExit(
            '找不到 upstream/native/core，请先初始化 submodule：'
            'git submodule update --init --recursive')
    patches = sorted((fork_dir / 'patches').glob('*.patch'))
    if not patches:
        raise SystemExit('fork/patches 里没有补丁文件')
    # 1. 还原被补丁改过的文件（补丁文件名即目标文件名）。文件若已在上游
    # 被删掉则跳过还原，后面打补丁时会以补丁自己的报错停住。
    patched = [p.name[:-len('.patch')] for p in patches]
    existing = []
    for name in patched:
        probe = subprocess.run(
            ['git', '-C', str(upstream), 'cat-file', '-e',
             f'HEAD:native/core/{name}'],
            capture_output=True)
        if probe.returncode == 0:
            existing.append(f'native/core/{name}')
    if existing:
        run(['git', '-C', str(upstream), 'checkout', '--'] + existing)
    # 2. 删掉上次拷入的 fork 新增文件。
    for source in (fork_dir / 'core').glob('*.go'):
        target = core / source.name
        if target.exists():
            target.unlink()
    # 3. 拷入 fork 新增文件。
    for source in sorted((fork_dir / 'core').glob('*.go')):
        shutil.copy2(source, core / source.name)
    # 4. 打补丁（先逐个 --check，报错时指出是哪个文件）。
    # 补丁文件在 Windows 检出时可能被转成 CRLF，而目标 .go 文件固定是 LF，
    # 行尾不一致时 git apply 会直接失败；这里先统一转成 LF 再打。
    with tempfile.TemporaryDirectory() as tmp:
        normalized = []
        for patch in patches:
            data = patch.read_bytes()
            if b'\r\n' in data:
                target = Path(tmp) / patch.name
                target.write_bytes(data.replace(b'\r\n', b'\n'))
                normalized.append(target)
            else:
                normalized.append(patch)
        for patch, source in zip(normalized, patches):
            check = subprocess.run(
                ['git', '-C', str(upstream), 'apply', '--check', str(patch)],
                capture_output=True, text=True)
            if check.returncode != 0:
                print(check.stderr, file=sys.stderr)
                raise SystemExit(
                    f'补丁打不上：{source.name}，上游改了同处代码，'
                    '请人工重排该补丁后再构建（不要强行跳过）。')
            run(['git', '-C', str(upstream), 'apply', str(patch)])
    # 5. 用本仓的站源包覆盖上游的 native/sources/。
    #    上游已把官方站源移入私有仓库，公开仓库只剩 sources_example；
    #    本仓自带 fork/sources/ 保证站源可用且构建可复现。
    #    逐文件覆盖而不是整目录删除：这样重复运行不会误删，
    #    也避免删掉上游目录里本仓没有的文件。
    #
    #    但「本仓删掉某个文件」时，上游目录里那份会留下来 —— 上游目录是构建态，
    #    残留的旧文件会和新文件一起参与编译，出现「函数重复声明」这类怪错误。
    #    所以这里记一份上一次的 fork 文件清单：本次不在清单里的旧文件删掉。
    count = 0
    if fork_sources.is_dir():
        sources.mkdir(parents=True, exist_ok=True)
        manifest = fork_sources / '.overlay-manifest.txt'
        previous = set()
        if manifest.exists():
            previous = {line.strip() for line in manifest.read_text().splitlines() if line.strip()}
        current = {source.name for source in fork_sources.glob('*.go')}
        for stale in sorted(previous - current):
            target = sources / stale
            if target.exists():
                target.unlink()
        for source in sorted(fork_sources.glob('*.go')):
            shutil.copy2(source, sources / source.name)
        manifest.write_text('\n'.join(sorted(current)) + '\n', encoding='utf-8')
        count = len(list(sources.glob('*.go')))
    # 6. 生成 go.work 与 bridge/sources_gen.go，接入本仓的站源包。
    #    这两处上游不入库（上游 .gitignore 已忽略），每次构建重生成。
    #
    #    go.work 的 go 指令必须**跟着上游 go.mod 走**：上游提 Go 版本后，
    #    写死的旧版本会让 go 命令直接罢工 ——
    #    "module . listed in go.work file requires go >= 1.26.10,
    #     but go.work lists go 1.24.1"（2026-11-20 的同步失败就是这个）。
    go_version = '1.24.1'
    go_mod = native / 'go.mod'
    if go_mod.exists():
        for line in go_mod.read_text(encoding='utf-8').splitlines():
            stripped = line.strip()
            if stripped.startswith('go '):
                go_version = stripped[3:].strip()
                break
    (native / 'go.work').write_text(
        f'go {go_version}\n\nuse (\n\t.\n)\n', encoding='utf-8')
    (native / 'bridge' / 'sources_gen.go').write_text(
        'package main\n\nimport (\n\t_ "duanjuapp/native/sources"\n)\n',
        encoding='utf-8')
    print(f'fork 覆盖层已合入：{len(patched)} 个补丁，'
          f'{len(list((fork_dir / "core").glob("*.go")))} 个新增文件，'
          f'{count} 个站源文件。')


if __name__ == '__main__':
    main()
