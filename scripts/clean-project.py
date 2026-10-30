#!/usr/bin/env python3
"""Preview or remove disposable project/build artifacts and app-owned runtime caches.

No input films, exports, saved projects, models, browser sessions or IndexedDB.
Run with --apply after reviewing the default dry run; --runtime adds user caches.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def targets(runtime=False):
    result = [ROOT / 'build', ROOT / '.build/.DS_Store']
    result += [ROOT / '.build' / name for name in (
        'Build', 'Index.noindex', 'ModuleCache.noindex', 'SDKExplicitPrecompiledModules',
        'SDKStatCaches.noindex', 'CompilationCache.noindex', 'Logs', 'TestResults')]
    for base, directories, files in os.walk(ROOT, followlinks=False):
        directories[:] = [d for d in directories if d not in ('.git', '.build', 'node_modules', 'Vendor')]
        for name in files:
            if name == '.DS_Store' or name.endswith('.bak'):
                result.append(Path(base) / name)
    if runtime:
        home = Path.home()
        support = home / 'Library/Application Support/Shortcast'
        result += [home / 'Library/Logs/Shortcast', home / 'Library/Caches/app.shortcast.Shortcast']
        # Removed frame interpolation/upscaling has no role in an essay release.
        result += [support / 'tools' / name for name in (
            'rife-ncnn-vulkan', 'rife-ncnn-vulkan-20221029-macos', 'realsr-ncnn-vulkan',
            'realsr-ncnn-vulkan-20220728-macos')]
        profile = support / 'BrowserProfile'
        cache_names = ('Cache', 'Code Cache', 'GPUCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'Media Cache')
        for directory in [profile, profile / 'Default', *profile.glob('Profile *')]:
            result += [directory / name for name in cache_names]
        result += [profile / 'GraphiteDawnCache', profile / 'ShaderCache', profile / 'GrShaderCache']
    # Never traverse symlinked cache roots or remove a target twice.
    unique = list(dict.fromkeys(p for p in result if p.exists() and not p.is_symlink()))
    return [p for p in unique if not any(parent in unique for parent in p.parents)]


def size(path):
    if path.is_symlink():
        return 0
    if path.is_file():
        return path.stat().st_size
    return sum(size(child) for child in path.iterdir())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--runtime', action='store_true', help='Close the app and its browser before removing runtime caches')
    args = parser.parse_args()
    entries = []
    planned = targets(args.runtime)
    skipped = []
    if args.runtime and args.apply:
        processes = subprocess.check_output(['/bin/ps', '-axo', 'args='], text=True)
        profile = Path.home() / 'Library/Application Support/Shortcast/BrowserProfile'
        if any('--user-data-dir' in line and str(profile) in line for line in processes.splitlines()):
            skipped = [p for p in planned if profile in p.parents]
            planned = [p for p in planned if p not in skipped]
    for path in planned:
        count = size(path)
        if args.apply:
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
        entries.append({'path': str(path), 'bytes': count})
    print(json.dumps({'applied': args.apply, 'total_bytes': sum(x['bytes'] for x in entries), 'targets': entries, 'skipped_active_browser_caches': [str(p) for p in skipped]}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
