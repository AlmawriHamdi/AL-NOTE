#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Serve local Flutter parity build + instrumented actual WASM cleanup tests.

Run inside al-note-dev. Uses only Python stdlib, local assets and generated PDFs.
The output directory retains result JSON and Chrome logs for review.
"""
import argparse
import functools
import http.server
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading


def fixture(crop):
    marks = '1 0 0 rg 20 30 10 20 re f\n0 0 1 rg 70 60 20 10 re f\n'
    objects = ['<< /Type /Catalog /Pages 2 0 R >>',
               '<< /Type /Pages /Count 1 /Kids [3 0 R] >>',
               f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] '
               f'/CropBox [{crop}] /Resources <<>> /Contents 4 0 R >>',
               f'<< /Length {len(marks)} >>\nstream\n{marks}endstream']
    data = b'%PDF-1.7\n'
    offsets = []
    for i, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data += f'{i} 0 obj\n{obj}\nendobj\n'.encode()
    xref = len(data)
    data += b'xref\n0 5\n0000000000 65535 f \n'
    data += ''.join(f'{offset:010} 00000 n \n' for offset in offsets).encode()
    return data + f'trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, help='Flutter build of pdfrx_web_parity_main.dart')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--chrome', default='google-chrome')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='al-note-pdf-browser-') as temporary:
        root = Path(temporary)
        for name in ['pdfium.wasm', 'pdfium_worker.js', 'pdfium_client.js']:
            shutil.copyfile(repo / 'third_party/pdfrx-2.4.8/assets' / name, root / name)
        for name in ['web_cleanup_worker.js', 'web_cleanup.html', 'web_parity_bridge.js']:
            shutil.copyfile(repo / 'test/fixtures/phase8' / name, root / name)
        (root / 'valid.pdf').write_bytes(fixture('10 20 110 90'))
        (root / 'disjoint.pdf').write_bytes(fixture('300 300 400 400'))
        if args.app:
            # Serve build in place; modify only a temporary index copy.
            (root / 'app').symlink_to(args.app.resolve(), target_is_directory=True)
        events = {key: threading.Event() for key in ['cleanup', 'parity']}
        results = {}

        class Handler(http.server.SimpleHTTPRequestHandler):
            def do_POST(self):
                key = self.path.removeprefix('/result/')
                if key not in events:
                    self.send_error(404)
                    return
                data = self.rfile.read(int(self.headers['Content-Length']))
                results[key] = json.loads(data)
                (args.output / f'{key}.json').write_bytes(data)
                self.send_response(200)
                self.end_headers()
                events[key].set()

            def do_GET(self):
                if self.path == '/app/':
                    data = (args.app / 'index.html').read_text().replace(
                        '<base href="/">', '<base href="/app/">').replace(
                        '</head>', '<script src="/web_parity_bridge.js"></script></head>')
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/html')
                    self.end_headers()
                    self.wfile.write(data.encode())
                elif self.headers.get('Range') and self.path.endswith('.pdf'):
                    data = (root / self.path.lstrip('/')).read_bytes()
                    start, end = self.headers['Range'].removeprefix('bytes=').split('-')
                    start = int(start)
                    end = min(int(end), len(data) - 1)
                    self.send_response(206)
                    self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
                    self.send_header('Content-Length', str(end - start + 1))
                    self.send_header('Accept-Ranges', 'bytes')
                    self.end_headers()
                    self.wfile.write(data[start:end + 1])
                else:
                    super().do_GET()

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(
            ('127.0.0.1', 0), functools.partial(Handler, directory=str(root)))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            for key, path in [('cleanup', 'web_cleanup.html')] + ([('parity', 'app/')] if args.app else []):
                with (args.output / f'{key}-chrome.log').open('w') as log:
                    command = [args.chrome, '--headless', '--no-sandbox', '--disable-dev-shm-usage',
                               '--no-first-run', f'--user-data-dir={root / (key + "-profile")}',
                               f'http://127.0.0.1:{server.server_port}/{path}']
                    browser = subprocess.Popen(command, stdout=log, stderr=log)
                    try:
                        if not events[key].wait(55):
                            raise RuntimeError(f'{key}: timeout; see Chrome log')
                    finally:
                        browser.terminate()
                        browser.wait(timeout=10)
                print(key, json.dumps({k: v for k, v in results[key].items() if k not in ['rows', 'cases']}))
                if not results[key].get('pass'):
                    raise RuntimeError(f'{key}: failed; see {args.output / (key + ".json")}')
        finally:
            server.shutdown()


if __name__ == '__main__':
    main()
