#!/usr/bin/env python3
"""Measure real relay/daemon PTY latency against a direct raw PTY on this machine."""
import json
import os
from pathlib import Path
import pty
import select
import signal
import statistics
import struct
import subprocess
import tempfile
import termios
import time
import tty
import fcntl

import smoke

ROOT = Path(__file__).resolve().parent


def receive(fd, marker, timeout=5):
    data = bytearray()
    deadline = time.monotonic() + timeout
    while marker not in data:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            raise AssertionError(f'Terminal did not return {marker!r}: {data[-200:]!r}')
        part = os.read(fd, 65536)
        if not part: raise AssertionError('Terminal disconnected')
        data.extend(part)
    return data


def sample(fd, count=100):
    values = []
    for index in range(count + 10):
        value = f'ping{index:05d}x'.encode()
        begin = time.perf_counter_ns()
        os.write(fd, value)
        receive(fd, value)
        elapsed = (time.perf_counter_ns() - begin) / 1e6
        if index >= 10: values.append(elapsed)
    return {'median_ms': statistics.median(values), 'p95_ms': sorted(values)[int(len(values) * 0.95)]}


def main():
    with tempfile.TemporaryDirectory(prefix='kite-benchmark-', dir="/tmp") as directory:
        path = Path(directory).resolve() / 'runtime/session-v2.sock'
        daemon = smoke.start(path)
        processes, descriptors = [], []
        control = None
        try:
            time.sleep(0.1)
            control = smoke.Connection(path)
            state = control.request('watch')
            settings = state['settings']; settings['shell'] = '/bin/sh'
            control.request('setSettings', settings=settings)
            state = control.request('createSession')
            pane = state['sessions'][0]['panes'][0]['id']
            master, slave = pty.openpty(); descriptors.append(master)
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
            relay = subprocess.Popen([str(ROOT / 'build/kite-relay'), 'attach', str(path), str(pane)], stdin=slave, stdout=slave, stderr=slave)
            processes.append(relay); os.close(slave)
            def relay_ready():
                while select.select([master], [], [], 0)[0]:
                    os.read(master, 65536)
                return smoke.pane(control.request('list'), pane)['attached']
            smoke.eventually(relay_ready, 'Relay did not acknowledge restored state')
            os.write(master, b"stty raw -echo; printf '\\122AW_READY'; exec /bin/cat\n")
            receive(master, b'RAW_READY')
            via_daemon = sample(master)
            direct_master, direct_slave = pty.openpty(); descriptors.append(direct_master)
            tty.setraw(direct_slave)
            direct = subprocess.Popen(['/bin/cat'], stdin=direct_slave, stdout=direct_slave, stderr=direct_slave)
            processes.append(direct); os.close(direct_slave)
            direct_result = sample(direct_master)
            relay.terminate(); relay.wait(timeout=5)
            # All detached processes are idle here; report the actual sampled CPU counters.
            before = subprocess.check_output(['ps', '-p', str(daemon.pid), '-o', 'time='], text=True).strip()
            time.sleep(3)
            after = subprocess.check_output(['ps', '-p', str(daemon.pid), '-o', 'time='], text=True).strip()
            result = {'direct_pty': direct_result, 'relay_daemon_pty': via_daemon,
                      'added_median_ms': via_daemon['median_ms'] - direct_result['median_ms'],
                      'daemon_idle_cpu_time_3s': [before, after],
                      'scope': 'Round-trip raw cat bytes through real PTYs, relay, canonical Ghostty parser and socket; excludes GUI rendering and native keyboard dispatch.'}
            print(json.dumps(result, indent=2))
            (ROOT / 'build/benchmark-result.json').write_text(json.dumps(result, indent=2) + '\n')
            control.request('shutdown'); daemon.wait(timeout=10)
        finally:
            if control is not None: control.close()
            for process in processes:
                if process.poll() is None: process.kill()
                process.wait()
            for descriptor in descriptors: os.close(descriptor)
            if daemon.poll() is None:
                daemon.terminate()
                try: daemon.wait(timeout=10)
                except subprocess.TimeoutExpired: daemon.kill(); daemon.wait()


if __name__ == '__main__':
    main()
