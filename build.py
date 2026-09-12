#!/usr/bin/env python3
"""Build Kite's native application, session daemon, and pane relay."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
GHOSTTY_VERSION = '1.3.1'
GHOSTTY_REV = '332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28'
ZIG_VERSION = '0.15.2'
FRAMEWORKS = ['AppKit', 'Metal', 'MetalKit', 'QuartzCore', 'CoreText', 'CoreGraphics', 'Carbon', 'IOSurface']
SHARED = ['Sources/Workspace.swift', 'Sources/Wire.swift']
UI = SHARED + ['Sources/SessionClient.swift', 'Sources/TerminalView.swift', 'Sources/Kite.swift']


def run(*args, cwd=ROOT, env=None):
    subprocess.run([str(a) for a in args], cwd=cwd, env=env, check=True)


def ghostty_source():
    source = ROOT / f'vendor/ghostty-{GHOSTTY_VERSION}'
    if not source.exists():
        run('git', 'clone', '--depth', '1', '--branch', f'v{GHOSTTY_VERSION}',
            'https://github.com/ghostty-org/ghostty.git', source)
    revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != GHOSTTY_REV:
        raise SystemExit(f'Ghostty revision mismatch: expected {GHOSTTY_REV}, got {revision}')
    return source


def ghostty_library(source, out, zig, sdk_option):
    run('xcrun', '--find', 'metal')
    run('xcrun', '--find', 'metallib')
    env = dict(os.environ)
    active_sdk = Path(subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip())
    compatible = Path('/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk')
    sdk = sdk_option or (compatible if compatible.exists() else active_sdk)
    if not (sdk / 'usr/lib/libSystem.tbd').is_file():
        raise SystemExit(f'Invalid macOS SDK: {sdk}')
    # Scope SDK discovery to the pinned compiler's build runner, not global Xcode.
    tools = out / 'sdk-tools'
    tools.mkdir(exist_ok=True)
    xcrun = tools / 'xcrun'
    xcrun.write_text('#!/bin/sh\n'
        'if [ "$1" = "--sdk" ] && [ "$2" = "macosx" ] && [ "$3" = "--show-sdk-path" ]; then\n'
        '    printf "%s\\n" "$KITE_ZIG_SDK"\n'
        'else\n    exec /usr/bin/xcrun "$@"\nfi\n')
    xcrun.chmod(0o755)
    # Apple libtool can drop unaligned Zig archive members. LLVM ar retains them.
    libtool = tools / 'libtool'
    libtool.write_text(f'#!{sys.executable}\n'
        'import os, subprocess, sys\n'
        'if sys.argv[1:3] != ["-static", "-o"]: raise SystemExit("Unexpected libtool invocation")\n'
        'paths = sys.argv[3:]\n'
        'if any(\'"\' in p or "\\n" in p for p in paths): raise SystemExit("Unsupported archive path")\n'
        'script = \'CREATE "\' + paths[0] + \'"\\n\'\n'
        'script += "".join(\'ADDLIB "\' + p + \'"\\n\' for p in paths[1:])\n'
        'subprocess.run([os.environ["KITE_ZIG"], "ar", "-M"], input=script + "SAVE\\nEND\\n", text=True, check=True)\n')
    libtool.chmod(0o755)
    env.update(PATH=str(tools) + os.pathsep + env['PATH'], KITE_ZIG=zig, KITE_ZIG_SDK=str(sdk.resolve()))
    # The small C bridge delegates parsing and snapshot formatting to Ghostty.
    bridge = (ROOT / 'Sources/kite-terminal.zig').read_bytes()
    destination = source / 'src/kite-terminal.zig'
    if not destination.exists() or destination.read_bytes() != bridge:
        destination.write_bytes(bridge)
    main = source / 'src/main_c.zig'
    entry = '\ncomptime { _ = @import("kite-terminal.zig"); }\n'
    content = main.read_text()
    if entry not in content:
        main.write_text(content + entry)
    print(f'Building Ghostty {GHOSTTY_VERSION} with {sdk}', flush=True)
    run(zig, 'build', '--cache-dir', out / 'ghostty-1.3-cache', '-Doptimize=ReleaseFast',
        '-Demit-macos-app=false', '-Demit-xcframework=true', '-Dxcframework-target=native',
        '-Demit-themes=false', cwd=source, env=env)
    libs = list((source / 'macos/GhosttyKit.xcframework').glob('macos-*/libghostty-fat.a'))
    if len(libs) != 1:
        raise SystemExit(f'Expected one native Ghostty library, found {libs}')
    return libs[0]


def link_swift(sources, output, header, library, objects=(), module='Kite'):
    args = ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-name', module,
            '-import-objc-header', str(header), '-O', *sources, *map(str, objects), str(library), '-lc++']
    for framework in FRAMEWORKS:
        args.extend(['-framework', framework])
    run(*args, '-o', output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', choices=['app', 'daemon', 'check-ui'])
    parser.add_argument('--zig', default=str(ROOT / f'.tools/zig-aarch64-macos-{ZIG_VERSION}/zig'))
    parser.add_argument('--ghostty-sdk', type=Path, help='SDK used by the pinned Zig compiler')
    args = parser.parse_args()
    os.chdir(ROOT)
    out = ROOT / 'build'
    out.mkdir(exist_ok=True)
    source = ghostty_source()
    if args.target == 'check-ui':
        run('xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-import-objc-header',
            source / 'include/ghostty.h', *UI, '-typecheck')
        return
    zig = shutil.which(args.zig)
    if not zig:
        raise SystemExit(f'Install Zig {ZIG_VERSION} or supply --zig /path/to/zig')
    library = ghostty_library(source, out, zig, args.ghostty_sdk)
    cflags = ['xcrun', 'clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror']
    run(*cflags, '-c', 'Sources/PTY.c', '-o', out / 'PTY.o')
    run(*cflags, 'Sources/kite-relay.c', '-o', out / 'kite-relay')
    header = out / 'Daemon-Bridging.h'
    header.write_text(f'#include "{ROOT / "Sources/PTY.h"}"\n#include "{ROOT / "Sources/kite-terminal.h"}"\n')
    link_swift(SHARED + ['Sources/SessionDaemon.swift'], out / 'kite-session', header, library,
               objects=[out / 'PTY.o'], module='KiteSession')
    if args.target == 'daemon':
        print(f'Built {out / "kite-session"} and {out / "kite-relay"}')
        return
    app = out / 'Kite.app/Contents'
    macos = app / 'MacOS'
    resources = app / 'Resources'
    macos.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    for executable in ['kite-session', 'kite-relay']:
        shutil.copy2(out / executable, macos / executable)
    link_swift(UI, macos / 'Kite', source / 'include/ghostty.h', library)
    shared = source / 'zig-out/share'
    if not shared.exists():
        raise SystemExit('Ghostty resources were not generated')
    shutil.copytree(shared, resources, dirs_exist_ok=True)
    with (app / 'Info.plist').open('wb') as stream:
        plistlib.dump({'CFBundleExecutable': 'Kite', 'CFBundleIdentifier': 'local.kite.terminal',
                      'CFBundleName': 'Kite', 'CFBundlePackageType': 'APPL',
                      'CFBundleShortVersionString': '0.2.0', 'CFBundleVersion': '2',
                      'NSHighResolutionCapable': True, 'LSMinimumSystemVersion': '13.0'}, stream)
    for executable in ['kite-session', 'kite-relay']:
        run('codesign', '--force', '--sign', '-', macos / executable)
    run('codesign', '--force', '--sign', '-', out / 'Kite.app')
    print(f'Built {out / "Kite.app"}. Opening the app starts its daemon automatically.')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(f'Build stopped: {error.cmd[0]} exited {error.returncode}. See diagnostic above.') from None
