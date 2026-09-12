#!/usr/bin/env python3
"""Run the real Kite UI against an isolated daemon, including GUI relaunch."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

import build
import smoke

ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-build', action='store_true')
    args = parser.parse_args()
    if not args.skip_build:
        subprocess.run([sys.executable, 'build.py', 'app'], cwd=ROOT, check=True)
    artifacts = ROOT / 'build/native-verification'
    artifacts.mkdir(parents=True, exist_ok=True)
    for old in ['native-exercise.json', 'native-restore.json', 'window.json', 'native-window.png', 'native-workspace.png', 'native-moved.png']:
        (artifacts / old).unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix='kite-ui-', dir="/tmp") as directory:
        temporary = Path(directory).resolve()
        app = temporary / 'KiteCheck.app'
        shutil.copytree(ROOT / 'build/Kite.app', app)
        original = (ROOT / 'Sources/Kite.swift').read_text()
        marker = 'withExtendedLifetime(delegate) { application.run() }'
        if original.count(marker) != 1:
            raise RuntimeError('Native entrypoint changed; update the verification hook')
        instrumented = original.replace(marker, 'withExtendedLifetime(delegate) { delegate.installNativeScenario(); application.run() }')
        instrumented += '\n' + (ROOT / 'Tests/NativeScenario.swift').read_text()
        source = temporary / 'KiteCheck.swift'
        source.write_text(instrumented)
        ghostty = ROOT / f'vendor/ghostty-{build.GHOSTTY_VERSION}'
        library = next((ghostty / 'macos/GhosttyKit.xcframework').glob('macos-*/libghostty-fat.a'))
        sources = [str(ROOT / name) for name in build.UI if name != 'Sources/Kite.swift'] + [str(source)]
        command = ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-name', 'KiteCheck',
                   '-import-objc-header', str(ghostty / 'include/ghostty.h'), '-O', *sources, str(library), '-lc++']
        for framework in build.FRAMEWORKS + ['CoreImage']:
            command.extend(['-framework', framework])
        command.extend(['-o', str(app / 'Contents/MacOS/Kite')])
        subprocess.run(command, check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
        socket_path = temporary / 'runtime/session-v2.sock'
        daemon = smoke.start(socket_path)
        control = None
        gui = None
        try:
            until = time.monotonic() + 5
            while control is None:
                try:
                    control = smoke.Connection(socket_path)
                except OSError:
                    if time.monotonic() > until: raise
                    time.sleep(0.05)
            settings = control.request('watch')['settings']
            settings['shell'] = '/bin/sh'
            control.request('setSettings', settings=settings)
            results = {}
            for phase in ['exercise', 'restore']:
                env = dict(os.environ, KITE_SOCKET=str(socket_path), KITE_TEST_ARTIFACTS=str(artifacts), KITE_TEST_PHASE=phase)
                log_path = artifacts / f'native-{phase}.log'
                with log_path.open('wb') as log:
                    gui = subprocess.Popen([str(app / 'Contents/MacOS/Kite')], env=env, stdout=log, stderr=log)
                    until = time.monotonic() + 110
                    captured = False
                    while gui.poll() is None:
                        if time.monotonic() >= until:
                            raise AssertionError(f'Native {phase} did not finish; see {log_path}')
                        window_file = artifacts / 'window.json'
                        if phase == 'exercise' and window_file.exists() and not captured:
                            window_id = json.loads(window_file.read_text())['id']
                            subprocess.run(['screencapture', '-x', '-l', str(window_id), str(artifacts / 'native-window.png')], capture_output=True, timeout=8)
                            captured = True
                        time.sleep(0.1)
                result_file = artifacts / f'native-{phase}.json'
                if not result_file.exists():
                    raise AssertionError(f'Native {phase} exited {gui.returncode} without evidence; see {log_path}')
                result = json.loads(result_file.read_text())
                if not result.get('ok'):
                    raise AssertionError(result)
                assert gui.returncode == 0, (gui.returncode, result)
                results[phase] = result
            control.request('shutdown')
            daemon.wait(timeout=10)
            print(json.dumps(results, indent=2))
        finally:
            if gui is not None and gui.poll() is None:
                gui.kill(); gui.wait()
            if control is not None: control.close()
            if daemon.poll() is None:
                daemon.terminate()
                try: daemon.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    daemon.kill(); daemon.wait()


if __name__ == '__main__':
    main()
