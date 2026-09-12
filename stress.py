#!/usr/bin/env python3
"""Prove malformed output, checkpoint errors, and large workspaces cannot kill or hide sessions."""
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time

import smoke

ROOT = Path(__file__).resolve().parent


def main():
    result = {}
    daemon = None
    connections = []
    with tempfile.TemporaryDirectory(prefix='kite-stress-', dir="/tmp") as directory:
        root = Path(directory).resolve()
        path = root / 'run/session-v2.sock'
        try:
            daemon = smoke.start(path)
            time.sleep(0.1)
            control = smoke.Connection(path); connections.append(control)
            settings = control.request('watch')['settings']; settings['shell'] = '/bin/sh'
            control.request('setSettings', settings=settings)
            state = control.request('createSession', cwd=str(root))
            session = state['sessions'][0]['id']
            pane = state['sessions'][0]['panes'][0]['id']
            pid = state['sessions'][0]['panes'][0]['pid']
            terminal = smoke.PaneConnection(path, pane); connections.append(terminal)
            emitter = root / 'emit.py'
            emitter.write_text("import os, time\n"
                "os.write(1, b'\\x1b]2;' + b'x' * 70000 + b'\\x07')\n"
                "os.write(1, b'\\x1b]2;invalid\\xff\\x07\\x1b]7;file:///bad%ZZ\\x07')\n"
                "os.write(1, b'\\x1b]52;c;')\n"
                "for _ in range(512): os.write(1, b'A' * 4096); time.sleep(0.0005)\n"
                "os.write(1, b'\\x07')\n"
                "os.write(1, b'\\x1b]2;' + b'q' * 4096 + b'\\x07')\n"
                "os.write(1, b'\\x1b[21t' * 2000)\n")
            terminal.command(f"'{sys.executable}' '{emitter}'; printf '\\123TILL_ALIVE:%s\\n' $$", f'STILL_ALIVE:{pid}\r\n'.encode())
            state = control.request('list')
            assert smoke.pane(state, pane)['state'] == 'running' and smoke.pane(state, pane)['pid'] == pid
            terminal.close(); connections.remove(terminal)
            smoke.eventually(lambda: not smoke.pane(control.request('list'), pane)['attached'], 'Output fixture did not detach')
            terminal = smoke.PaneConnection(path, pane); connections.append(terminal)
            assert b'STILL_ALIVE' in terminal.snapshot, 'Malformed output prevented later reconstruction'
            result['malformed_metadata_and_query_flood_survive'] = True

            # Metadata-only disk failure must remain visible on the same healthy connection.
            os.chmod(path.parent, 0o500)
            terminal.command("printf '\\033]2;Checkpoint warning\\007'; printf '\\127ARN_TRIGGER\\n'", b'WARN_TRIGGER\r\n')
            def warning_received():
                control.request('list')
                return any(not item['ok'] and item.get('error') for item in control.notifications)
            smoke.eventually(warning_received, 'Checkpoint failure was not delivered')
            rejected = control.request('renameSession', _allow_failure=True, session=session, title='Must not commit')
            assert not rejected['ok'] and rejected.get('error')
            assert control.request('list')['sessions'][0]['id'] == session
            os.chmod(path.parent, 0o700)
            control.request('renameSession', session=session, title='Recovered workspace')
            def recovery_received():
                control.request('list')
                return any(item['ok'] and not item.get('error') for item in control.notifications)
            smoke.eventually(recovery_received, 'Successful checkpoint did not clear durability warning')
            result['checkpoint_failure_and_recovery_same_connection'] = True

            # Leave the renderer connected but stop reading. It must be detached, not block PTY progress.
            marker = root / 'slow-reader-finished'
            terminal.command(f"(sleep 0.3; dd if=/dev/zero bs=65536 count=64 2>/dev/null; touch '{marker}') & printf '\\123LOW_GO\\n'", b'SLOW_GO\r\n')
            smoke.eventually(marker.exists, 'Slow renderer blocked child output', timeout=10)
            smoke.eventually(lambda: not smoke.pane(control.request('list'), pane)['attached'], 'Slow renderer stayed attached with unbounded output')
            terminal.close(); connections.remove(terminal)
            result['slow_renderer_does_not_block_process'] = True

            deep = root
            for index in range(7):
                deep /= f'{index}' + 'd' * 99
                deep.mkdir()
            for _ in range(63):
                state = control.request('createSession', cwd=str(deep))
            state = control.request('list')
            encoded_size = len(json.dumps(state, separators=(',', ':')).encode())
            assert len(state['sessions']) == 64 and encoded_size > 65536 and encoded_size < 1048576
            result['large_workspace_bytes'] = encoded_size
            result['large_workspace_sessions'] = 64

            # Real daemon crash: no recorded exit status may be fabricated as success.
            original_pids = [p['pid'] for s in state['sessions'] for p in s['panes'] if p.get('pid')]
            daemon.kill(); daemon.wait(timeout=5)
            for connection in connections: connection.close()
            connections.clear()
            smoke.eventually(lambda: all(smoke.gone(item) for item in original_pids), 'Daemon death did not release test PTYs', timeout=10)
            daemon = smoke.start(path)
            time.sleep(0.1)
            control = smoke.Connection(path); connections.append(control)
            restored = control.request('watch')
            lost = smoke.pane(restored, pane)
            assert lost['state'] == 'exited' and lost['exitCode'] == 255 and lost.get('exitMessage')
            terminal = smoke.PaneConnection(path, pane); connections.append(terminal)
            kind, stream, payload = terminal.frame()
            assert kind == 8 and stream == pane and struct.unpack('!i', payload)[0] == 255
            result['crash_lost_status_is_not_success'] = True
            control.request('shutdown'); daemon.wait(timeout=10)
            print(json.dumps(result, indent=2))
            (ROOT / 'build/stress-result.json').write_text(json.dumps(result, indent=2) + '\n')
        finally:
            if path.parent.exists(): os.chmod(path.parent, 0o700)
            for connection in connections: connection.close()
            if daemon is not None and daemon.poll() is None:
                daemon.terminate()
                try: daemon.wait(timeout=10)
                except subprocess.TimeoutExpired: daemon.kill(); daemon.wait()


if __name__ == '__main__':
    main()
