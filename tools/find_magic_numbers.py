#!/usr/bin/env python3
"""
find_magic_numbers.py - 在 lib/ 下扫描"业务代码里的幻数"

不是 lint/pre-commit hook 那种硬拦,而是给人看"还有哪些字面数字没名字"的列表。

跟 .git/hooks/pre-commit 的区别:
- pre-commit hook 抓的是"业务 widget 里硬编码数字"(padding/fontSize/iconSize/widget 尺寸),
  这些是该走主题/默认值的硬约束,违反就 exit 1 拦 commit。
- 本脚本抓的是"代码里出现频率高但没命名的数字"(API 限制/魔法常量/状态机索引/算法哨兵),
  主要是给 review 用,违反不当 error,只列清单。

用法:
    cd /path/to/oceanus
    python3 tools/find_magic_numbers.py                 # 扫 lib/ (默认排除 lib/sdk/)
    python3 tools/find_magic_numbers.py --include-sdk  # 把 lib/sdk/ 也算进去

排除:
- 单行注释 / doc 注释 (/// / // / *) 里的数字
- 已经是命名常量(static const / RegExp / enum 字段)的行
- 协议字段 (limit: / ctcode: / countrycode: / cursor: / scene:)
- 状态机索引(switch case)
- 边界判断(< 0 / >= 0 / == 0 / isEmpty return -1)
- 比例 / 透明度 (withValues(alpha:) / aspectRatio: / maxLines: / flex: / padLeft)
- 颜色 / 默认值(`?? 0` / `? 0 :` / json 默认值)
- JSON 解析默认值 (`is int ? json[...] as int : 0`)

返回:
    计数行 + 剩余"待 review"行
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path


# 文件级白名单:这些文件的"数字"基本都已经命名,不再逐个审视
'''
WHITELIST_FILES = {
    'LoginController.dart': lambda l: bool(re.search(
        r'static const|RegExp\(|isCodeValid|countdown\.value <= 0', l)),
    'PlayerController.dart': lambda l: bool(re.search(
        r'static const|Rx<Duration> duration', l)),
    'default.dart': lambda l: bool(re.search(r'static const', l)),
    'AppShell.dart': lambda l: bool(re.search(r'static const', l)),
    'aspect_driven_grid.dart': lambda l: bool(re.search(
        r'_GridDefaults|class _GridDefaults|static const', l)),
    'SearchController.dart': lambda l: bool(re.search(
        r'enum SearchType|song\(1,|album\(10,|artist\(100,|playlist\(1000', l)),
    'LibraryPage.dart': lambda l: bool(re.search(
        r'enum LibraryTab|LibraryTab\.|segments:|playlists\(1,|albums\(2,|artists\(3,', l)),
    'LibraryController.dart': lambda l: bool(re.search(
        r'enum LibraryTab|Rx<LibraryTab>|case LibraryTab|playlists\(1,|albums\(2,|artists\(3,', l)),
    'ArtistDetail.dart': lambda l: bool(re.search(r'enum ArtistView|ArtistView\.', l)),
    'ArtistController.dart': lambda l: bool(re.search(r'enum ArtistView|Rx<ArtistView>', l)),
    'LoginPage.dart': lambda l: bool(re.search(
        r'codeMaxLength|strokeWidth: 2|countdown > 0', l)),
}
'''
# 行级黑名单:即使有数字也不算
'''
LEGIT = [
    r'maxLines:', r'flex:', r'aspectRatio:',
    r'withValues\(alpha:', r'padLeft\(',
    r'limit:', r'ctcode:', r'countrycode:', r'cursor:', r'scene:',
    r"'(1|0|2)'", r'\? 0 :', r': 0', r'\?\? 0',
    r'case [0-9]+:', r'\.clamp\(',
    r'is int \?', r'< 0\b', r'>= 0\b',
    r'isEmpty return -1', r'== 1\b', r'== 0\b',
    r'x86_64', r'/[0-9]\.', r'/[0-9]+\.[0-9]',
    r'==', r'!=', r'\+ 1', r'- 1',
    r'inSeconds % 60',
    r'progressIndicator\(',
    r'strokeWidth: [0-9]',
    r'androidCompactActionIndices',
    r'speed: 1\.0',
    r'this\.songCount = 0', r'this\.albumCount = 0', r'this\.fanCount = 0',
]
'''

def collect_magic_numbers(lib_root: Path, include_sdk: bool) -> list[str]:
    """收集 lib/ 下所有 .dart 文件里"代码行里出现数字"的行。

    排除:
    - 单行/多行/doc 注释
    - exclude 路径 (默认 lib/sdk/)
    """
    # 先用 grep -nE 一次扫完
    cmd = [
        'grep', '-rnE',
        # 数字边界:不能是字母/数字/小数点的一部分
        # 形如 ", 12" / "(1)" / "= 3" 都命中,但 "v1.2.3" / "abc123" / "id123" 不命中
        r'[^a-zA-Z_0-9.]([0-9]+(\.[0-9]+)?)[^a-zA-Z_0-9.]',
        str(lib_root),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    raw_lines = result.stdout.splitlines()

    hits = []
    for line in raw_lines:
        # 跳过注释行(行首是 // /// 或 /* *)
        # 格式: lib/path/file.dart:N:content
        parts = line.split(':', 2)
        if len(parts) < 3:
            continue
        file_part, _, content = parts
        if content.lstrip().startswith(('///', '//', '*', '/*')):
            continue
        # exclude 路径
        if not include_sdk and '/sdk/' in file_part:
            continue
        hits.append(line)

    return hits


def filter_suspicious(hits: list[str]) -> list[str]:
    """从总命中筛出"真可疑"行。"""
    suspicious = []
    for line in hits:
        # 文件级白名单
        fname = line.split(':')[0].split('/')[-1]
        '''
        if fname in WHITELIST_FILES and WHITELIST_FILES[fname](line):
            continue
        # 行级黑名单
        if any(re.search(p, line) for p in LEGIT):
            continue
        '''
        # JSON 解析默认值
        if re.search(r'is int \? json\[', line):
            continue
        '''
        if re.search(r'isEmpty return 0', line):
            continue
        '''
        suspicious.append(line)
    return suspicious


def main() -> int:
    parser = argparse.ArgumentParser(
        description='扫 lib/ 找还没命名的数字字面量',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        '--lib-root', type=Path, default=Path('lib'),
        help='lib 根目录(默认 ./lib)',
    )
    parser.add_argument(
        '--include-sdk', action='store_true',
        help='把 lib/sdk/ 也算进去(默认排除,因为它是 MusicLibrary 子模块)',
    )
    parser.add_argument(
        '--verbose', '-v', action='store_true',
        help='额外打印每个文件的命中数',
    )
    args = parser.parse_args()

    lib_root = args.lib_root
    if not lib_root.is_dir():
        print(f'❌ 目录不存在: {lib_root}', file=sys.stderr)
        return 2

    print(f'🔍 扫 {lib_root}/ 找幻数(排除 sdk: {not args.include_sdk})...\n')

    hits = collect_magic_numbers(lib_root, args.include_sdk)
    suspicious = filter_suspicious(hits)

    if args.verbose:
        # 按文件聚合
        from collections import Counter
        files = Counter(line.split(':', 1)[0] for line in hits)
        print(f'📊 命中文件 Top:')
        for f, n in files.most_common(10):
            print(f'   {n:3d}  {f}')
        print()

    print(f'📋 命中: {len(hits)} 行')
    print(f'⚠️  待 review: {len(suspicious)} 行')
    print()
    for s in suspicious:
        print(s)
    print()

    # 不当 error,return 0(这是给人看的清单,不是 lint gate)
    return 0


if __name__ == '__main__':
    sys.exit(main())
