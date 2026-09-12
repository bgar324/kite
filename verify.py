#!/usr/bin/env python3
"""Build Kite and run its state, lifecycle, stress, latency, and native UI checks."""
import argparse
from pathlib import Path
import subprocess
import sys

import build

ROOT = Path(__file__).resolve().parent


def run(*args, timeout=300):
    print('+ ' + ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=ROOT, check=True, timeout=timeout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-build', action='store_true')
    args = parser.parse_args()
    if not args.skip_build:
        run(sys.executable, 'build.py', 'app', timeout=3600)
    run('xcrun', 'swiftc', *build.SHARED, 'Tests/ModelWire.swift', '-o', 'build/model-wire-check')
    run('build/model-wire-check')
    library = next((ROOT / f'vendor/ghostty-{build.GHOSTTY_VERSION}/macos/GhosttyKit.xcframework').glob('macos-*/libghostty-fat.a'))
    command = ['xcrun', 'clang', '-Wall', '-Wextra', '-Werror', 'Tests/TerminalState.c', str(library), '-lc++']
    for framework in build.FRAMEWORKS:
        command.extend(['-framework', framework])
    run(*command, '-o', 'build/terminal-state-check')
    run('build/terminal-state-check')
    run(sys.executable, 'smoke.py')
    run(sys.executable, 'stress.py')
    run(sys.executable, 'benchmark.py')
    run(sys.executable, 'verify-native.py', '--skip-build')
    print('All Kite verification checks passed.', flush=True)


if __name__ == '__main__':
    main()
