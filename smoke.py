#!/usr/bin/env python3
"""Exercise Kite's real multi-session daemon in an isolated private workspace."""
import json
import os
from pathlib import Path
import re
import select
import signal
import socket
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent
BIN = ROOT / 'build/kite-session'
HEADER = struct.Struct('!4sBBHII')


def encode(kind, stream=0, payload=b''):
    assert len(payload) <= 65536
    return HEADER.pack(b'KITE', 2, kind, 0, len(payload), stream) + payload


class Connection:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(8)
        self.socket.connect(str(path))
        self.next_id = 1
        self.notifications = []

    def exact(self, count):
        data = bytearray()
        while len(data) < count:
            part = self.socket.recv(count - len(data))
            if not part:
                raise AssertionError('Daemon closed the connection unexpectedly')
            data.extend(part)
        return bytes(data)

    def frame(self):
        magic, version, kind, reserved, length, stream = HEADER.unpack(self.exact(16))
        limit = 1048576 if kind in (2, 3) else 65536
        assert magic == b'KITE' and version == 2 and reserved == 0 and length <= limit
        return kind, stream, self.exact(length)

    def request(self, op, _allow_failure=False, **fields):
        ident = self.next_id
        self.next_id += 1
        self.socket.sendall(encode(1, payload=json.dumps(dict(id=ident, op=op, **fields)).encode()))
        while True:
            kind, _, payload = self.frame()
            if kind == 3:
                continue
            assert kind == 2, (kind, payload)
            result = json.loads(payload)
            if result['id'] == 0:
                self.notifications.append(result)
            if result['id'] != ident:
                continue
            if _allow_failure:
                return result
            assert result['ok'], result.get('error')
            return result.get('workspace')

    def close(self):
        self.socket.close()


class PaneConnection(Connection):
    def __init__(self, path, pane, rows=24, cols=80):
        super().__init__(path)
        self.pane = pane
        self.snapshot = bytearray()
        self.socket.sendall(encode(4, pane, struct.pack('!HHHH', rows, cols, 0, 0)))
        started = ended = False
        while True:
            kind, stream, payload = self.frame()
            assert stream == pane
            if kind == 11:
                assert not started
                started = True
            elif kind == 7:
                self.snapshot.extend(payload)
                assert len(self.snapshot) <= 16 * 1024 * 1024
            elif kind == 12:
                ended = True
            elif kind == 9:
                assert started and ended, 'READY preceded restored terminal state'
                self.socket.sendall(encode(9, pane))
                break
            elif kind == 10:
                raise AssertionError(payload.decode(errors='replace'))
            elif kind == 8:
                assert started and ended
                break
            else:
                raise AssertionError((kind, payload[:100]))

    def command(self, command, expected=None):
        self.socket.sendall(encode(5, self.pane, command.encode() + b'\n'))
        if expected is None:
            return b''
        output = bytearray()
        while expected not in output:
            kind, _, payload = self.frame()
            if kind == 7:
                output.extend(payload)
                assert len(output) < 4 * 1024 * 1024
            elif kind in (8, 10):
                raise AssertionError((kind, payload, output[-1000:]))
        return bytes(output)


def session(workspace, ident):
    return next(item for item in workspace['sessions'] if item['id'] == ident)


def pane(workspace, ident):
    return next(item for group in workspace['sessions'] for item in group['panes'] if item['id'] == ident)


def eventually(predicate, message, timeout=5):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if predicate():
            return
        time.sleep(0.04)
    raise AssertionError(message)


def gone(pid):
    try:
        os.kill(pid, 0)
        return False
    except ProcessLookupError:
        return True


def start(path):
    process = subprocess.Popen([str(BIN), 'serve', str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    eventually(lambda: path.exists() or process.poll() is not None, 'Daemon did not create socket')
    if process.poll() is not None:
        raise AssertionError(process.stderr.read().decode())
    return process


def main():
    connections = []
    daemon = None
    results = {}
    with tempfile.TemporaryDirectory(prefix='kite-mvp-', dir="/tmp") as tmp:
        root = Path(tmp).resolve()
        path = root / 'runtime/session-v2.sock'
        (root / 'project').mkdir()
        (root / 'project/subdir').mkdir()
        try:
            daemon = start(path)
            assert path.stat().st_mode & 0o777 == 0o600
            assert path.parent.stat().st_mode & 0o777 == 0o700
            # An accepted connection's deadline starts after any long idle wait.
            time.sleep(3.2)
            control = Connection(path)
            connections.append(control)
            workspace = control.request('watch')
            assert workspace['schema'] == 2 and not workspace['sessions']
            settings = workspace['settings']
            settings.update(shell='/bin/sh', fontFamily='Menlo', fontSize=15, theme='dark')
            workspace = control.request('setSettings', settings=settings)
            workspace = control.request('createSession', cwd=str(root / 'project'))
            alpha = workspace['sessions'][0]['id']
            first = workspace['sessions'][0]['panes'][0]['id']
            workspace = control.request('renameSession', session=alpha, title='Alpha project')
            workspace = control.request('createSession', cwd=str(root))
            beta = next(s['id'] for s in workspace['sessions'] if s['id'] != alpha)
            beta_pane = session(workspace, beta)['panes'][0]['id']
            workspace = control.request('reorderSession', session=beta, index=0)
            assert workspace['sessions'][0]['id'] == beta
            control.request('selectSession', session=alpha)
            terminal = PaneConnection(path, first)
            connections.append(terminal)
            output = terminal.command("export KITE_SURVIVAL=kept; printf '\\120ID:%s\\n' $$", b'PID:')
            match = re.search(rb'PID:(\d+)', output)
            while not match:
                kind, _, part = terminal.frame()
                if kind == 7: output += part
                match = re.search(rb'PID:(\d+)', output)
            first_pid = int(match.group(1))
            terminal.command("printf '\\120RIMARY_MARKER\\n'", b'PRIMARY_MARKER\r\n')
            terminal.command("cd subdir; printf '\\033]2;Alpha title\\007'; printf '\\103WD_READY\\n'", b'CWD_READY\r\n')
            eventually(lambda: pane(control.request('list'), first)['cwd'] == str(root / 'project/subdir'), 'Working directory metadata did not update')
            eventually(lambda: pane(control.request('list'), first)['title'] == 'Alpha title', 'OSC title metadata did not update')
            workspace = control.request('createPane', session=alpha, pane=first, axis='vertical')
            layout = session(workspace, alpha)['layout']
            split_id = layout['id']
            second = next(p['id'] for p in session(workspace, alpha)['panes'] if p['id'] != first)
            control.request('resizeSplit', session=alpha, split=split_id, ratio=0.37)
            alternate = PaneConnection(path, second)
            connections.append(alternate)
            alternate.command("printf '\\120RIMARY_TWO\\n'", b'PRIMARY_TWO\r\n')
            alternate.command("printf '\\033[?1049h\\033[2J\\033[H\\033[31m\\101LT_MARKER\\033[0m'", b'ALT_MARKER')
            alternate.close(); connections.remove(alternate)
            eventually(lambda: not pane(control.request('list'), second)['attached'], 'Pane stayed attached after socket loss')
            alternate = PaneConnection(path, second)
            connections.append(alternate)
            assert b'ALT_MARKER' in alternate.snapshot, 'Alternate screen was not restored'
            assert b'PRIMARY_TWO' in alternate.snapshot, 'Inactive primary screen was not restored'
            results['normal_and_alternate_snapshot'] = True
            alternate.command("printf '\\033[?1049l\\122ETURNED\\n'", b'RETURNED')
            # A second renderer must never steal an active pane's input/resize authority.
            other = Connection(path)
            other.socket.sendall(encode(4, first, struct.pack('!HHHH', 24, 80, 0, 0)))
            kind, _, _ = other.frame()
            assert kind == 10, 'Competing renderer was not rejected'
            other.close()
            results['second_controller_rejected'] = True
            terminal.close(); connections.remove(terminal)
            eventually(lambda: not pane(control.request('list'), first)['attached'], 'First pane did not detach')
            begin = time.perf_counter()
            terminal = PaneConnection(path, first, rows=37, cols=109)
            connections.append(terminal)
            assert b'PRIMARY_MARKER' in terminal.snapshot
            terminal.command("printf '\\122ESTORE:%s:%s\\n' $$ $KITE_SURVIVAL", f'RESTORE:{first_pid}:kept\r\n'.encode())
            results['snapshot_reconnect_and_command_ms'] = round((time.perf_counter() - begin) * 1000, 3)
            terminal.command('stty size', b'37 109\r\n')
            results['shell_identity_and_resize'] = True
            # While no renderer is attached the canonical terminal must answer device queries.
            reply_file = root / 'query-reply'
            done_file = root / 'query-done'
            terminal.command(f"(sleep 0.4; stty -icanon -echo min 0 time 10; printf '\\033[6n'; dd bs=1 count=32 2>/dev/null | od -An -tu1 > '{reply_file}'; stty sane; touch '{done_file}')")
            terminal.close(); connections.remove(terminal)
            eventually(done_file.exists, 'Detached terminal query stalled', timeout=6)
            assert reply_file.read_text().strip().split()[0] == '27', reply_file.read_text()
            results['detached_query_reply'] = True
            terminal = PaneConnection(path, first)
            connections.append(terminal)
            marker = root / 'drained'
            terminal.command(f"(sleep 0.3; dd if=/dev/zero bs=65536 count=32 2>/dev/null; touch '{marker}') & printf '\\107O\\n'", b'GO\r\n')
            terminal.close(); connections.remove(terminal)
            eventually(marker.exists, 'Unattached PTY output blocked', timeout=8)
            results['detached_output_bytes'] = 2 * 1024 * 1024
            workspace = control.request('movePane', session=alpha, pane=second)
            moved = next(s for s in workspace['sessions'] if any(p['id'] == second for p in s['panes']))
            assert moved['id'] != alpha and session(workspace, alpha)['layout'] == {'pane': first}
            results['pane_move_preserves_identity'] = True
            # Test ordinary background process cleanup, not merely daemon/socket disappearance.
            beta_terminal = PaneConnection(path, beta_pane)
            connections.append(beta_terminal)
            output = beta_terminal.command("sleep 60 & printf '\\112OB:%s\\n' $!", b'JOB:')
            match = re.search(rb'JOB:(\d+)', output)
            while not match:
                kind, _, part = beta_terminal.frame()
                if kind == 7: output += part
                match = re.search(rb'JOB:(\d+)', output)
            background_pid = int(match.group(1))
            control.request('closeSession', session=beta)
            eventually(lambda: gone(background_pid), 'Closing session left an ordinary background job alive')
            beta_terminal.close(); connections.remove(beta_terminal)
            results['background_job_cleanup'] = True
            # Recreate a split and check its metadata survives daemon restart without fake live PIDs.
            workspace = control.request('createPane', session=alpha, pane=first, axis='horizontal')
            final_layout = session(workspace, alpha)['layout']
            control.request('resizeSplit', session=alpha, split=final_layout['id'], ratio=0.42)
            old_pid = pane(workspace, first)['pid']
            workspace = control.request('restartPane', pane=first)
            assert pane(workspace, first)['pid'] != old_pid
            eventually(lambda: gone(old_pid), 'Restart left the previous shell alive')
            final = control.request('list')
            old_epoch = final['epoch']
            assert session(final, alpha)['title'] == 'Alpha project'
            control.request('shutdown')
            daemon.wait(timeout=10)
            for conn in connections: conn.close()
            connections.clear()
            daemon = start(path)
            control = Connection(path); connections.append(control)
            restored = control.request('list')
            assert restored['epoch'] != old_epoch
            assert [s['id'] for s in restored['sessions']] == [s['id'] for s in final['sessions']]
            assert session(restored, alpha)['layout']['ratio'] == 0.42
            assert restored['settings'] == settings
            assert all(p['state'] == 'exited' and not p['attached'] for s in restored['sessions'] for p in s['panes'])
            results['workspace_metadata_restart'] = True
            control.request('restartPane', pane=first)
            restored_terminal = PaneConnection(path, first); connections.append(restored_terminal)
            restored_terminal.command("printf '\\122ESTART_OK\\n'", b'RESTART_OK\r\n')
            control.request('shutdown')
            daemon.wait(timeout=10)
            results['explicit_restart_and_shutdown'] = True
            print(json.dumps(results, indent=2))
            (ROOT / 'build/mvp-smoke-result.json').write_text(json.dumps(results, indent=2) + '\n')
        finally:
            for conn in connections:
                conn.close()
            if daemon is not None and daemon.poll() is None:
                daemon.terminate()
                try:
                    daemon.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    daemon.kill(); daemon.wait()
            if daemon is not None and daemon.returncode not in (None, 0):
                print(daemon.stderr.read().decode(errors='replace'))


if __name__ == '__main__':
    main()
