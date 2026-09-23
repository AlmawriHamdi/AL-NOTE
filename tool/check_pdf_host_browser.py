#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run production Web host-reading checks with local browser API instrumentation."""
import argparse
import functools
import http.server
import json
import os
import signal
import time
from pathlib import Path
import subprocess
import tempfile
import threading


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    repo = Path(__file__).resolve().parents[1]
    done = threading.Event()
    result = {}

    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/':
                data = (args.app / 'index.html').read_text().replace(
                    '</head>', '<script src="/host-reading.js"></script></head>')
            elif self.path == '/host-reading.js':
                data = (repo / 'test/fixtures/phase8/web_host_reading.js').read_text()
            else:
                return super().do_GET()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html' if self.path == '/' else 'text/javascript')
            self.end_headers()
            self.wfile.write(data.encode())

        def do_POST(self):
            data = self.rfile.read(int(self.headers['Content-Length']))
            result.update(json.loads(data))
            (args.output / 'host-reading.json').write_bytes(data)
            self.send_response(200)
            self.end_headers()
            done.set()

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(
        ('127.0.0.1', 0), functools.partial(Handler, directory=str(args.app.resolve())))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='al-note-host-chrome-') as profile:
            with (args.output / 'chrome.log').open('w') as log:
                browser = subprocess.Popen(['google-chrome', '--headless', '--no-sandbox',
                    '--disable-dev-shm-usage', '--no-first-run', f'--user-data-dir={profile}',
                    f'http://127.0.0.1:{server.server_port}/'], stdout=log, stderr=log, start_new_session=True)
                try:
                    if not done.wait(55):
                        raise RuntimeError('Browser timeout; see Chrome log')
                finally:
                    os.killpg(browser.pid, signal.SIGTERM)
                    browser.wait(timeout=10)
                    try:
                        os.killpg(browser.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    # Reap browser children before removing their profile.
                    time.sleep(0.2)
        print(json.dumps(result))
        assert result.get('pass'), 'Production host-reading regression failed'
    finally:
        server.shutdown()


if __name__ == '__main__':
    main()
