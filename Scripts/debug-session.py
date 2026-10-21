#!/usr/bin/env python3
"""Local, timestamped Mac/iPhone/optional relay evidence. No pairing secrets."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import threading

ROOT = Path(__file__).resolve().parents[1]
PREDICATE = 'subsystem == "com.renyicao.mice" AND process == "Mice"'


def run(command):
    return subprocess.run(command, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, timeout=30)


def devices():
    result = run(['xcrun', 'devicectl', 'list', 'devices', '--json-output', '-'])
    if result.returncode:
        raise RuntimeError(result.stdout)
    # Human progress may precede the JSON on some Xcode versions.
    data = json.loads(result.stdout[result.stdout.index('{'):])
    return [d for d in data['result']['devices']
            if d.get('hardwareProperties', {}).get('reality') == 'physical']


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec='milliseconds')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['doctor', 'capture', 'console', 'crashes'])
    parser.add_argument('--device', help='Physical device identifier or UDID')
    parser.add_argument('--relay-ssh', help='Existing SSH alias; uses sudo -n journalctl')
    parser.add_argument('--seconds', type=int, default=120)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.seconds < 1:
        parser.error('--seconds must be positive')
    physical = devices()
    connected = [d for d in physical
                 if d.get('connectionProperties', {}).get('tunnelState') == 'connected']
    selected = next((d for d in physical if args.device in
                     (d.get('identifier'), d.get('hardwareProperties', {}).get('udid'))), None) if args.device else None
    if args.device and selected is None:
        parser.error('Unknown physical device. Run doctor first.')
    if selected is None and len(connected) == 1:
        selected = connected[0]
    if selected is None and len(connected) > 1:
        parser.error('Multiple physical devices. Select one with --device.')
    available = selected is not None and selected in connected
    summary = {
        'utc': now(), 'xcode': run(['xcodebuild', '-version']).stdout.strip(),
        'physicalDevices': [{'identifier': d['identifier'],
                             'model': d.get('hardwareProperties', {}).get('marketingName'),
                             'connection': d.get('connectionProperties', {}).get('tunnelState')}
                            for d in physical],
        'idevicesyslog': shutil.which('idevicesyslog'),
        'selectedDevice': selected['identifier'] if selected else None,
    }
    debug_ready = False
    if args.mode == 'doctor' and available:
        details = run(['xcrun', 'devicectl', 'device', 'info', 'details',
                       '--device', selected['identifier'], '--json-output', '-'])
        try:
            info = json.loads(details.stdout[details.stdout.index('{'):])['result']
            state = info.get('deviceProperties', {})
            debug_ready = state.get('ddiServicesAvailable', False)
            summary['developerMode'] = state.get('developerModeStatus')
            summary['debugServicesAvailable'] = debug_ready
        except (ValueError, KeyError):
            summary['debugServicesAvailable'] = False
        if not debug_ready:
            summary['nextStep'] = 'Unlock the physical phone; retry doctor. Follow any Xcode device preparation prompt.'
    print(json.dumps(summary, indent=2))
    if args.mode == 'doctor':
        return 0 if available and debug_ready else 2
    if args.mode in ('console', 'crashes') and not available:
        parser.error('No connected physical iPhone. Connect USB, unlock, and trust this Mac.')
    os.umask(0o077)
    output = (args.output or ROOT / 'build' / 'debug-sessions' /
              dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')).resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / 'environment.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(f'Evidence: {output}', flush=True)
    if args.mode == 'crashes':
        return subprocess.call(['xcrun', 'devicectl', 'device', 'copy', 'from',
                                '--device', selected['identifier'], '--domain-type', 'systemCrashLogs',
                                '--source', '.', '--destination', str(output / 'crashes')])
    if args.mode == 'console':
        # Explicit mode: relaunches the app. Capture mode never restarts it.
        with (output / 'iphone-console.log').open('w') as log:
            return subprocess.call(['xcrun', 'devicectl', 'device', 'process', 'launch',
                                    '--device', selected['identifier'], '--terminate-existing',
                                    '--console', 'com.renyicao.mice.remote'], stdout=log, stderr=subprocess.STDOUT)
    (output / 'host-history.log').write_text(run([
        '/usr/bin/log', 'show', '--last', '10m', '--info', '--debug', '--style', 'compact',
        '--predicate', PREDICATE]).stdout)
    commands = {'host': ['/usr/bin/log', 'stream', '--level', 'debug', '--style', 'compact',
                         '--predicate', PREDICATE]}
    if available and shutil.which('idevicesyslog'):
        commands['iphone'] = ['idevicesyslog', '-u', selected['hardwareProperties']['udid'],
                              '--no-colors', '--exit', '-p', 'MiceRemote']
    else:
        print('PARTIAL: iPhone log unavailable. USB/trust and libimobiledevice are required.', flush=True)
    if args.relay_ssh:
        if args.relay_ssh.startswith('-'):
            parser.error('Invalid SSH alias')
        commands['relay'] = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', args.relay_ssh,
                              'sudo -n journalctl -u nimlet-relay --since "10 min ago" -f --no-pager -o short-iso']
    stop = threading.Event()
    processes = []
    threads = []
    ended_before_stop = set()
    timeline = (output / 'timeline.log').open('w', buffering=1)
    lock = threading.Lock()

    def collect(name, proc):
        with (output / f'{name}.log').open('w', buffering=1) as log:
            for line in proc.stdout:
                entry = f'{now()} [{name}] {line.rstrip()}\n'
                log.write(entry)
                with lock:
                    timeline.write(entry)
            if not stop.is_set():
                ended_before_stop.add(name)
            with lock:
                timeline.write(f'{now()} [{name}] collector exited={proc.wait()}\n')

    signal.signal(signal.SIGINT, lambda *_: stop.set())
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    try:
        for name, command in commands.items():
            proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, start_new_session=True)
            processes.append(proc)
            thread = threading.Thread(target=collect, args=(name, proc))
            threads.append(thread)
            thread.start()
        stop.wait(args.seconds)
        stop.set()
    finally:
        for proc in processes:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
        for proc in processes:
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
        for thread in threads:
            thread.join()
        timeline.close()
    statuses = dict(zip(commands, [p.returncode for p in processes]))
    (output / 'collectors.json').write_text(json.dumps(statuses, indent=2) + '\n')
    print(f'Collectors: {statuses}')
    # A missing phone or a failed collector cannot count as a full capture.
    return 0 if 'iphone' in commands and not ended_before_stop else 2


if __name__ == '__main__':
    sys.exit(main())
