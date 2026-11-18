"""Run SDK contract checks against local fixtures, never production."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

ROOT = Path(__file__).resolve().parents[2]
KEY = 'td_live_fixture_only'


class Fixture(BaseHTTPRequestHandler):
    calls = []

    def log_message(self, *args):
        pass

    def do_GET(self): self.respond()
    def do_POST(self): self.respond()
    def do_DELETE(self): self.respond()
    def do_PATCH(self): self.respond()

    def respond(self):
        self.calls.append((self.command, self.path))
        raw = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        path = urlsplit(self.path).path
        status = 200
        content_type = 'application/json; charset=utf-8'
        payload = {'id': 'fixture', 'status': 'succeeded', 'result_id': 'transcript', 'future_field': 42,
                   'words': [{'start_ms': 123, 'end_ms': 456}],
                   'request': {'method': self.command, 'path': path, 'query': parse_qs(urlsplit(self.path).query),
                               'body': json.loads(raw) if raw else None,
                               'idempotency_key': self.headers.get('Idempotency-Key'),
                               'authorized': self.headers.get('Authorization') == 'Bearer ' + KEY}}
        if path == '/v1/redirect':
            self.send_response(302)
            self.send_header('Location', '/v1/credential-leak')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if path == '/v1/rate-limit':
            status = 429
            payload = {'error': {'code': 'RATE_LIMITED', 'message': KEY, 'retryable': True, 'retry_after_seconds': 4}, 'request_id': 'fixture-request'}
        elif path in ('/v1/budget', '/v1/conflict', '/v1/jobs/not-owned'):
            status, code = {'/v1/budget': (402, 'BUDGET_EXCEEDED'), '/v1/conflict': (409, 'IDEMPOTENCY_CONFLICT'), '/v1/jobs/not-owned': (404, 'NOT_FOUND')}[path]
            payload = {'error': {'code': code, 'message': 'Fixture rejection', 'retryable': False}}
        elif path == '/v1/gateway':
            status, payload = 502, b'<html>gateway failed</html>'
        elif path == '/v1/error-shape':
            status, payload = 500, ['not an error object']
        elif path == '/v1/malformed':
            payload = b'not-json'
        elif path == '/v1/array':
            payload = []
        elif path == '/v1/slow':
            time.sleep(.3)
        elif path.endswith('/export'):
            content_type = 'text/plain; charset=utf-8'
            payload = '1\n00:00:00,000 --> 00:00:01,000\nCafé fixture\n'.encode()
        elif path.startswith('/v1/jobs/'):
            name = path.rsplit('/', 1)[-1]
            payload['status'] = name if name in ('succeeded', 'failed', 'cancelled', 'processing') else 'succeeded'
        if self.command == 'POST':
            status = 202
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        try:
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass
